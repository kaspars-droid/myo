import SwiftUI
import AppKit
import ReckonCore

/// One sheet in the switcher.
struct SheetEntry: Identifiable, Equatable {
	let url: URL
	/// The sheet's first line, which is what it is called.
	let name: String

	var id: URL { url }
}

/// Owns the sheet on screen, the folder it came from, and writing it back.
///
/// The app deliberately does not use `DocumentGroup`: that gives one window per
/// document, and sheets are meant to swap inside a single window. So opening,
/// saving and listing are done here by hand.
///
/// A sheet is a file. Nothing is imported or copied into an app container, so
/// the folder keeps working in Numi and keeps syncing on whatever drive it is.
@MainActor
final class SheetStore: ObservableObject {
	/// One store for the app: the menu bar item and the window are two views
	/// of the same sheet, and AppKit needs to reach it without SwiftUI.
	static let shared = SheetStore()

	@Published var document = SheetDocument(text: "")
	/// The folder the sheets are kept in, chosen once and remembered.
	@Published private(set) var folder: URL?
	/// The sheet on screen.
	@Published private(set) var url: URL?
	@Published private(set) var entries: [SheetEntry] = []

	/// Exactly what was read from disk, so an untouched sheet is never
	/// rewritten and an unchanged one is never written at all.
	private var contentsOnDisk = ""
	private var saveWork: Task<Void, Never>?
	private let watcher = FolderWatcher()

	private static let lastSheetKey = "lastSheet"
	private static let folderKey = "sheetFolder"
	/// Sheets are `.numi` files. Nothing else is listed.
	static let fileExtension = "numi"

	init() {
		watcher.onChange = { [weak self] in self?.reloadFromDisk() }

		NotificationCenter.default.addObserver(
			forName: NSApplication.willTerminateNotification, object: nil, queue: .main
		) { [weak self] _ in
			MainActor.assumeIsolated { self?.saveNow() }
		}
	}

	// MARK: - Opening

	func start() {
		guard url == nil else { return }

		if let saved = UserDefaults.standard.string(forKey: Self.folderKey) {
			folder = URL(fileURLWithPath: saved)
		}
		refreshEntries()

		let remembered = UserDefaults.standard.string(forKey: Self.lastSheetKey)

		if let remembered, FileManager.default.fileExists(atPath: remembered) {
			load(URL(fileURLWithPath: remembered))
		} else if let first = entries.first {
			load(first.url)
		} else {
			document = SheetDocument(text: SheetStore.welcome)
		}
	}

	/// Leaving the sheet you are on: save what is worth saving, throw away
	/// what is not.
	private func leaveCurrentSheet(goingTo target: URL? = nil) {
		if url != target { discardIfEmpty() }
		saveNow()
	}

	/// An empty sheet is scratch, so switching away from one throws it out
	/// rather than leaving a trail of blank files behind.
	///
	/// It goes to the trash rather than being unlinked. The app is guessing
	/// that you are finished with the file, and a guess about someone else's
	/// document should be recoverable.
	private func discardIfEmpty() {
		guard let url,
			  document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  document.storedAnswers.allSatisfy({ $0 == nil }),
			  FileManager.default.fileExists(atPath: url.path)
		else { return }

		var trashed: NSURL?
		guard (try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)) != nil
		else { return }

		self.url = nil
		contentsOnDisk = ""
		UserDefaults.standard.removeObject(forKey: Self.lastSheetKey)
	}

	func load(_ target: URL) {
		leaveCurrentSheet(goingTo: target)

		let text = (try? String(contentsOf: target, encoding: .utf8))
			?? (try? String(contentsOf: target, encoding: .isoLatin1))
			?? ""

		contentsOnDisk = text
		document = SheetDocument(text: text)
		url = target
		UserDefaults.standard.set(target.path, forKey: Self.lastSheetKey)

		// Opening a sheet from somewhere else means you are working there now.
		let parent = target.deletingLastPathComponent()
		if folder != parent { setFolder(parent, openFirst: false) }

		refreshEntries()
		watcher.watch(folder: folder, file: url)
	}

	/// The folder is the library: every sheet in it shows up in the list.
	func chooseFolder() {
		let panel = NSOpenPanel()
		panel.canChooseDirectories = true
		panel.canChooseFiles = false
		panel.allowsMultipleSelection = false
		panel.directoryURL = folder
		panel.prompt = "Use Folder"
		panel.message = "Choose the folder your sheets are kept in"

		// An app with no Dock icon is not frontmost when its panel opens, so a
		// modal run from inside the menu can leave the panel behind every other
		// window — which looks exactly like the app closing. Activating first,
		// and presenting without blocking, keeps it in front.
		NSApp.activate(ignoringOtherApps: true)
		panel.level = .modalPanel

		panel.begin { [weak self] response in
			guard response == .OK, let chosen = panel.url else { return }
			Task { @MainActor in self?.setFolder(chosen, openFirst: true) }
		}
	}

	func setFolder(_ chosen: URL, openFirst: Bool) {
		leaveCurrentSheet()

		folder = chosen
		UserDefaults.standard.set(chosen.path, forKey: Self.folderKey)
		refreshEntries()
		watcher.watch(folder: folder, file: url)

		if openFirst, let first = entries.first, first.url != url {
			load(first.url)
		}
	}

	// MARK: - Saving

	/// Typing should not hit the disk on every keystroke.
	func scheduleSave() {
		saveWork?.cancel()
		saveWork = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(600))
			guard !Task.isCancelled else { return }
			self?.saveNow()
		}
	}

	func saveNow() {
		guard let url else { return }

		let contents = document.fileContents
		guard contents != contentsOnDisk else { return }

		do {
			try contents.write(to: url, atomically: true, encoding: .utf8)
			contentsOnDisk = contents
			refreshEntries()   // the first line, and so the name, may have changed
		} catch {
			NSSound.beep()
		}
	}

	// MARK: - The folder

	/// Re-reads the folder, and the open sheet, from disk.
	///
	/// A menu bar app sits there for days, so "opening" it means opening the
	/// panel. Anything could have changed the folder in between — the phone,
	/// another Mac, Numi itself — and the sheet on screen would still be the
	/// one read on Tuesday.
	func reloadFromDisk() {
		// Our own unsaved edit goes back first, so re-reading cannot lose it.
		saveNow()
		refreshEntries()
		watcher.watch(folder: folder, file: url)

		guard let url,
			  let text = try? String(contentsOf: url, encoding: .utf8),
			  text != contentsOnDisk
		else { return }

		contentsOnDisk = text
		document = SheetDocument(text: text)
	}

	func refreshEntries() {
		guard let folder else {
			entries = []
			return
		}

		let contents = (try? FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
		)) ?? []

		entries = contents
			.filter { $0.pathExtension.lowercased() == Self.fileExtension }
			.map { file in
				// A sheet is called by its first line, not its file name.
				let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
				let stem = file.deletingPathExtension().lastPathComponent

				// An empty sheet has no first line to be named by, so it falls
				// back to its file name. Saying so stops it reading as a
				// different sheet that appeared from nowhere.
				let named = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
					? stem
					: SheetDocument(text: text).name

				return SheetEntry(url: file, name: named)
			}
			// Ordered by file name, not by the name shown. Sorting on the
			// shown name would shuffle the list as you typed the first line.
			.sorted {
				$0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent)
					== .orderedAscending
			}
	}

	/// A new sheet is a new file beside the current one, opened in this same
	/// window. With nowhere to put it, the open panel asks where.
	func newSheet() {
		// Before picking a name: if the sheet being left is blank it goes now,
		// so its name is free again and blanks cannot pile up.
		leaveCurrentSheet()

		guard let folder else {
			chooseFolder()
			return
		}

		var candidate = folder.appendingPathComponent("Untitled.numi")
		var counter = 2
		while FileManager.default.fileExists(atPath: candidate.path) {
			candidate = folder.appendingPathComponent("Untitled \(counter).numi")
			counter += 1
		}

		do {
			try Data().write(to: candidate, options: .withoutOverwriting)
			load(candidate)
		} catch {
			NSSound.beep()
		}
	}

	static let welcome = """
	# Myo

	rate = 0.21
	net = 1200
	net * rate      # the VAT

	35eur           # oil
	45eur           # filter
	12.50eur
	sum
	"""
}
