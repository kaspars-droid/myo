import SwiftUI
import AppKit
import ReckonCore

/// What a sheet was called when it was last read, and when it was last
/// written. Kept at file scope so that looking at the folder, which happens
/// off the main thread, is not reaching into a type that belongs to it.
private struct Named: Sendable {
	var modified: Date
	var name: String
}

/// Everything one look at the folder found, gathered up so it can be carried
/// back from the thread that did the waiting.
private struct Look: Sendable {
	var entries: [SheetEntry]
	var names: [URL: Named]
	var openText: String?
}

/// One sheet in the switcher.
struct SheetEntry: Identifiable, Equatable, Sendable {
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
	/// The first line the file is named for. A rename follows a change to it,
	/// not a difference from it, so a sheet named by hand keeps that name.
	private var titleOnDisk = ""
	private var saveWork: Task<Void, Never>?
	private var renameWork: Task<Void, Never>?
	private var lookWork: Task<Void, Never>?

	/// What each sheet was called when it was last read, and when it was last
	/// written.
	///
	/// A sheet is named by its first line, so the list cannot be built without
	/// opening every file in the folder. That is nothing on a local disk and a
	/// great deal on a sleeping one: these sheets are usually in iCloud Drive,
	/// and the first read after the machine wakes waits on a provider that has
	/// to reconnect before it will answer. Remembered here, a sheet nothing
	/// has touched is never opened again.
	private var names: [URL: Named] = [:]
	private let watcher = FolderWatcher()
	private let access = FolderAccess()

	private static let lastSheetKey = "lastSheet"
	/// Sheets are `.myocalc` files. Nothing else is listed. The engine already
	/// says which extension that is, and two answers to one question is one
	/// too many.
	nonisolated static var fileExtension: String { SheetCache.fileExtension }

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

		// Before the remembered sheet is looked for, because sandboxed the
		// folder is what makes the sheet inside it readable at all.
		folder = access.restore()

		// Whatever was open last time opens straight away, without waiting to
		// hear what else the folder has in it.
		let remembered = UserDefaults.standard.string(forKey: Self.lastSheetKey)
		if let remembered, FileManager.default.fileExists(atPath: remembered) {
			load(URL(fileURLWithPath: remembered))
			return
		}

		if folder == nil, let held = heldText() {
			// Typed before a folder was chosen, and still homeless. It stays a
			// sheet with no file behind it, so choosing a folder still moves it
			// into that folder rather than leaving a copy in here.
			document = SheetDocument(text: held)
		} else {
			document = SheetDocument(text: SheetStore.welcome)
		}

		// The folder is asked afterwards, and its first sheet opens over the
		// welcome when it answers. That is what used to happen anyway; it just
		// happened before there was anything on screen.
		lookWork?.cancel()
		lookWork = Task { [weak self] in
			await self?.lookAgain()
			guard let self, self.url == nil, let first = self.entries.first else { return }
			self.load(first.url)
		}
	}

	// MARK: - The sheet with nowhere to go yet

	/// Where a sheet lives while there is no folder to put it in.
	///
	/// The app otherwise never writes a sheet anywhere you did not pick, and
	/// that is worth keeping true — so this holds one sheet, only until a
	/// folder is chosen, and gives it up the moment there is one. Without it,
	/// typing on the welcome screen and quitting loses the lot, because before
	/// a folder there is nowhere for `saveNow` to write.
	private var holding: URL {
		URL.documentsDirectory.appendingPathComponent("Unsaved.\(Self.fileExtension)")
	}

	private func heldText() -> String? {
		guard let text = try? String(contentsOf: holding, encoding: .utf8),
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return nil }

		return text
	}

	/// Keeps what has been typed while there is still nowhere to put it.
	private func saveHolding() {
		let contents = document.fileContents

		guard !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  contents != SheetStore.welcome
		else { return dropHolding() }

		try? FileManager.default.createDirectory(
			at: holding.deletingLastPathComponent(), withIntermediateDirectories: true)
		try? contents.write(to: holding, atomically: true, encoding: .utf8)
	}

	private func dropHolding() {
		try? FileManager.default.removeItem(at: holding)
	}

	/// Leaving the sheet you are on: save what is worth saving, throw away
	/// what is not.
	private func leaveCurrentSheet(goingTo target: URL? = nil) {
		if url != target { discardIfEmpty() }
		settleNow()
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

	/// Deletes a sheet, by putting it in the trash.
	///
	/// The same reasoning as `discardIfEmpty`, and with more force: that one is
	/// a guess about a file nobody said to delete, this one is a document
	/// someone picked out of a list and may have picked by mistake. The Finder
	/// has a place for exactly this, and it is one keystroke to undo.
	func remove(_ target: URL) {
		var trashed: NSURL?
		guard (try? FileManager.default.trashItem(at: target, resultingItemURL: &trashed)) != nil
		else { return }

		names[target] = nil

		guard url == target else { return refreshEntries() }

		// The sheet on screen has just gone. Cleared before anything else, so
		// the save that follows has no file left to write it back to.
		url = nil
		contentsOnDisk = ""
		titleOnDisk = ""
		document = SheetDocument(text: "")
		UserDefaults.standard.removeObject(forKey: Self.lastSheetKey)

		// Which sheet to open instead is a question about the folder, so it
		// waits for the folder to answer rather than holding the app still.
		lookWork?.cancel()
		lookWork = Task { [weak self] in
			await self?.lookAgain()
			guard let self, self.url == nil else { return }

			if let first = self.entries.first { self.load(first.url) } else { self.newSheet() }
		}
	}

	func load(_ target: URL) {
		leaveCurrentSheet(goingTo: target)

		// Opening a sheet from somewhere else means you are working there now.
		// This happens before the sheet is loaded: changing folder discards an
		// empty sheet, and doing that halfway through a load would throw away
		// the very sheet being opened.
		//
		// Compared by standardised path, because appending and then removing a
		// path component leaves a trailing slash — so the same folder compares
		// unequal to itself, and a new sheet was discarded the moment it was
		// made.
		let parent = target.deletingLastPathComponent()
		if folder?.standardizedFileURL.path != parent.standardizedFileURL.path {
			setFolder(parent, openFirst: false)
		}

		let text = (try? String(contentsOf: target, encoding: .utf8))
			?? (try? String(contentsOf: target, encoding: .isoLatin1))
			?? ""

		contentsOnDisk = text
		document = SheetDocument(text: text)
		titleOnDisk = document.name
		url = target
		UserDefaults.standard.set(target.path, forKey: Self.lastSheetKey)

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
		// Before anything is written into the folder: sandboxed, adopting it is
		// what makes it writable at all.
		access.adopt(chosen)

		let rehomed = rehome(into: chosen)
		// Whatever was being held has a folder now, or was never worth holding.
		dropHolding()
		// A different folder's names say nothing about this one.
		names.removeAll()
		watcher.watch(folder: folder, file: url)

		if let rehomed {
			refreshEntries()
			load(rehomed)
			return
		}

		lookWork?.cancel()
		lookWork = Task { [weak self] in
			await self?.lookAgain()
			guard let self, openFirst, let first = self.entries.first, first.url != self.url
			else { return }

			self.load(first.url)
		}
	}

	/// Writes the sheet that has no file behind it into the folder just chosen,
	/// and answers with where it went.
	///
	/// Until a folder is chosen there is nowhere to save, so a sheet typed
	/// before then exists only on screen. It used to be dropped the moment a
	/// folder arrived, when the folder's own first sheet opened over the top of
	/// it. Whatever was typed goes into the folder instead.
	private func rehome(into chosen: URL) -> URL? {
		guard url == nil else { return nil }

		let text = document.fileContents
		guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
			  text != SheetStore.welcome
		else { return nil }

		let stem = SheetCache.fileName(forTitle: document.name) ?? "Untitled"
		let name = SheetCache.unusedName(like: "\(stem).\(Self.fileExtension)", in: chosen)
		let destination = chosen.appendingPathComponent(name)

		guard SheetCache.writeBack(text, to: destination) else { return nil }
		return destination
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

		scheduleRename()
	}

	/// Renaming waits much longer than saving, and for a plain reason: a file
	/// named from a first line still being typed is named `r`, then `rē`, then
	/// `rēķ`. Saving early costs nothing and protects the text; naming early
	/// puts a wrong name on a real file, so it waits until the typing stops.
	private func scheduleRename() {
		renameWork?.cancel()
		renameWork = Task { [weak self] in
			try? await Task.sleep(for: .seconds(3))
			guard !Task.isCancelled else { return }
			self?.renameNow()
		}
	}

	/// Save and name the sheet at once, for the moments there is no time to
	/// wait for either timer: switching sheets, or quitting.
	func settleNow() {
		saveNow()
		renameNow()
	}

	/// The file is called what the sheet's first line says, once that line has
	/// been changed. `SheetCache.newName` decides; this carries it out.
	func renameNow() {
		renameWork?.cancel()

		guard let current = url,
			  let wanted = SheetCache.newName(for: current.lastPathComponent,
											  titleWas: titleOnDisk, titleIs: document.name)
		else { return }

		titleOnDisk = document.name

		let target = current.deletingLastPathComponent().appendingPathComponent(wanted)
		guard !FileManager.default.fileExists(atPath: target.path),
			  (try? FileManager.default.moveItem(at: current, to: target)) != nil
		else { return }

		url = target
		UserDefaults.standard.set(target.path, forKey: Self.lastSheetKey)
		watcher.watch(folder: folder, file: target)
		refreshEntries()
	}

	func saveNow() {
		guard let url else { return saveHolding() }

		let contents = document.fileContents
		guard contents != contentsOnDisk else { return }

		do {
			try contents.write(to: url, atomically: true, encoding: .utf8)
			contentsOnDisk = contents
			refreshEntries()   // the first line, and so the name shown, may have changed
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
		// It writes only when there is something to write, so opening the panel
		// on a sheet nobody has touched does not go near the disk here.
		saveNow()
		refreshEntries()
		watcher.watch(folder: folder, file: url)
	}

	/// Re-reads the folder, without making anyone wait for it.
	///
	/// It used to be read on the spot, which meant the panel could not be drawn
	/// until every sheet in an iCloud folder had been opened. Awake that is a
	/// few milliseconds and nobody ever saw it; after the machine has slept,
	/// the provider has to reconnect before it answers a single question, and
	/// the app sat there with nothing on screen looking like it had died.
	func refreshEntries() {
		lookWork?.cancel()
		lookWork = Task { [weak self] in await self?.lookAgain() }
	}

	/// The waiting part, kept off the thread that draws.
	private func lookAgain() async {
		let folder = self.folder
		let open = self.url
		let known = self.names

		let found = await Task.detached(priority: .utility) {
			SheetStore.look(in: folder, at: open, naming: known)
		}.value

		guard !Task.isCancelled else { return }

		names = found.names
		entries = found.entries
		adopt(found.openText, read: open)
	}

	/// Takes on what the folder handed back for the sheet on screen.
	private func adopt(_ text: String?, read: URL?) {
		guard let text, let url, url == read, text != contentsOnDisk else { return }

		// Only when there is nothing unsaved. Reading the folder takes long
		// enough now for a sentence to be typed while it happens, and the
		// answer arriving must not take that sentence away.
		guard document.fileContents == contentsOnDisk else { return }

		contentsOnDisk = text
		document = SheetDocument(text: text)
		// Someone else's edit to the first line is not this app's cue to
		// rename their file.
		titleOnDisk = document.name
	}

	/// Everything that has to touch the disk, in one place, so that one place
	/// can be somewhere other than the main thread.
	private nonisolated static func look(in folder: URL?, at open: URL?,
										 naming known: [URL: Named]) -> Look {
		let openText = open.flatMap { try? String(contentsOf: $0, encoding: .utf8) }

		guard let folder else { return Look(entries: [], names: [:], openText: openText) }

		let contents = (try? FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles]
		)) ?? []

		let sheets = contents.filter { $0.pathExtension.lowercased() == Self.fileExtension }

		var entries: [SheetEntry] = []
		var names: [URL: Named] = [:]

		// Ordered before the names are worked out, so the list is not
		// reshuffled by what happens to be on a sheet's first line.
		for file in SheetOrder.lastEditedFirst(sheets) {
			let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
				.contentModificationDate) ?? .distantPast

			// A sheet nothing has written to since it was last read keeps the
			// name it was given then. Asking the date is one question; opening
			// the file is a download.
			if let remembered = known[file], remembered.modified == modified {
				entries.append(SheetEntry(url: file, name: remembered.name))
				names[file] = remembered
				continue
			}

			// A sheet is called by its first line, not its file name.
			let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
			let stem = file.deletingPathExtension().lastPathComponent

			// An empty sheet has no first line to be named by, so it falls
			// back to its file name. Saying so stops it reading as a
			// different sheet that appeared from nowhere.
			let named = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
				? stem
				: SheetDocument(text: text).name

			entries.append(SheetEntry(url: file, name: named))
			names[file] = Named(modified: modified, name: named)
		}

		return Look(entries: entries, names: names, openText: openText)
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

		var candidate = folder.appendingPathComponent("Untitled.\(Self.fileExtension)")
		var counter = 2
		while FileManager.default.fileExists(atPath: candidate.path) {
			candidate = folder.appendingPathComponent(
				"Untitled \(counter).\(Self.fileExtension)")
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
