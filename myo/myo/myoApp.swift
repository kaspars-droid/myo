import SwiftUI
import Combine
import UniformTypeIdentifiers
import ReckonCore
import ReckonUI

@main
struct MyoApp: App {
	@StateObject private var store = PhoneStore()
	@Environment(\.scenePhase) private var scenePhase

	var body: some Scene {
		WindowGroup {
			NavigationStack {
				SheetView(document: $store.document)
					.navigationTitle(store.title)
					.navigationBarTitleDisplayMode(.inline)
					.toolbar { toolbar }
			}
			.preferredColorScheme(.dark)
			.onAppear { store.start() }
			.onChange(of: store.document) { store.scheduleSave() }
			// Leaving the app is the moment an edit is most likely to be lost:
			// the save is on a short timer, and swiping away cancels it.
			.onChange(of: scenePhase) { _, phase in
				if phase == .active {
					store.refresh()
				} else {
					store.saveNow()
				}
			}
			.fileImporter(isPresented: $store.isChoosingFolder,
						  allowedContentTypes: [.folder]) { result in
				if case .success(let folder) = result { store.choose(folder) }
			}
		}
	}

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		// Toolbar items sit on a shared capsule of glass by default, which
		// round two plain icons reads as a button they are not.
		ToolbarItem(placement: .topBarTrailing) {
			Button { store.newSheet() } label: { Image(systemName: "plus") }
				.accessibilityLabel("New sheet")
		}
		.sharedBackgroundVisibility(.hidden)

		ToolbarItem(placement: .topBarTrailing) {
			Menu {
				if store.sheets.isEmpty {
					Text(store.folder == nil ? "No folder chosen yet" : "No sheets in this folder")
				} else {
					ForEach(store.sheets, id: \.self) { name in
						Button {
							store.load(name)
						} label: {
							if name == store.current {
								Label(store.displayName(of: name), systemImage: "checkmark")
							} else {
								Text(store.displayName(of: name))
							}
						}
					}
				}

				Divider()
				Button("Choose Folder…") { store.isChoosingFolder = true }
				if store.folder != nil {
					Button("Refresh from Cloud") { store.refresh() }
				}
			} label: {
				Image(systemName: "line.3.horizontal")
			}
			.accessibilityLabel("Switch sheet")
		}
		.sharedBackgroundVisibility(.hidden)
	}
}

/// The sheet on screen, the folder it came from, and the local copy in between.
///
/// The chosen folder is usually somewhere in the Files app — iCloud Drive, or
/// On My iPhone — where sheets may be fetched on demand and may not arrive at
/// all when offline. So `SheetCache` keeps a copy on the phone: sheets open
/// from it, and edits are written to both.
@MainActor
final class PhoneStore: ObservableObject {
	@Published var document = SheetDocument(text: "")
	@Published var isChoosingFolder = false
	@Published private(set) var sheets: [String] = []
	@Published private(set) var current: String?
	@Published private(set) var folder: URL?

	private let cache = SheetCache(folder: URL.documentsDirectory.appendingPathComponent("Sheets"))
	private var saveWork: Task<Void, Never>?
	private var contentsOnDisk = ""

	private static let bookmarkKey = "folderBookmark"

	var title: String {
		guard let current else { return "Myo Calc" }
		return displayName(of: current)
	}

	func displayName(of name: String) -> String {
		guard let text = cache.read(name),
			  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
			return (name as NSString).deletingPathExtension
		}
		return SheetDocument(text: text).name
	}

	// MARK: - Starting up

	func start() {
		guard current == nil else { return }

		try? cache.makeFolder()
		restoreFolder()
		sheets = cache.names()

		if let first = sheets.first {
			load(first)
		} else {
			// Backed by a file from the start: an unsaved sheet on screen is
			// a sheet waiting to be lost.
			let name = cache.unusedName(startingFrom: "Myo Calc")
			_ = try? cache.write(SheetView.sample, to: name, source: folder)
			sheets = cache.names()
			load(name)
		}
	}

	/// The folder is reached again through a bookmark. A plain path would not
	/// do: permission to read someone else's folder does not survive a relaunch.
	private func restoreFolder() {
		guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return }

		var stale = false
		guard let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
			  resolved.startAccessingSecurityScopedResource()
		else { return }

		folder = resolved
		refresh()
	}

	// MARK: - The folder

	func choose(_ picked: URL) {
		saveNow()
		folder?.stopAccessingSecurityScopedResource()

		guard picked.startAccessingSecurityScopedResource() else { return }

		if let data = try? picked.bookmarkData() {
			UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
		}

		// The list is the folder, so the previous folder's sheets go. Anything
		// made before a folder was chosen goes with them: it was scratch, and
		// keeping it would leave sheets in the list that are nowhere in the
		// folder you just picked.
		cache.empty()
		try? cache.makeFolder()

		folder = picked
		current = nil
		contentsOnDisk = ""
		refresh()

		if let first = sheets.first {
			load(first)
		} else {
			// An empty folder still needs somewhere to type.
			let name = cache.unusedName(startingFrom: "Untitled")
			_ = try? cache.write("", to: name, source: picked)
			sheets = cache.names()
			load(name)
		}
	}

	/// Brings down anything the folder has that this phone does not, and
	/// re-reads the open sheet if it changed elsewhere.
	func refresh() {
		guard let folder else { return }

		_ = try? cache.refresh(from: folder)
		sheets = cache.names()

		if let current, let text = cache.read(current), text != contentsOnDisk {
			contentsOnDisk = text
			document = SheetDocument(text: text)
		}
	}

	// MARK: - Sheets

	func load(_ name: String) {
		saveNow()

		let text = cache.read(name) ?? ""
		contentsOnDisk = text
		document = SheetDocument(text: text)
		current = name
	}

	func newSheet() {
		saveNow()

		let name = cache.unusedName(startingFrom: "Untitled")
		_ = try? cache.write("", to: name, source: folder)
		sheets = cache.names()
		load(name)
	}

	// MARK: - Saving

	func scheduleSave() {
		saveWork?.cancel()
		saveWork = Task { [weak self] in
			try? await Task.sleep(for: .milliseconds(600))
			guard !Task.isCancelled else { return }
			self?.saveNow()
		}
	}

	/// A new sheet is called Untitled until it says what it is. Only the name
	/// this app invented is replaced; a sheet you named yourself keeps it.
	private func renameIfStillUntitled() {
		guard let name = current, SheetCache.isAutomatic(name),
			  let wanted = SheetCache.fileName(forTitle: document.name),
			  cache.rename(name, to: wanted, source: folder)
		else { return }

		current = wanted
	}

	func saveNow() {
		guard let current else { return }

		let contents = document.fileContents
		guard contents != contentsOnDisk else { return }

		_ = try? cache.write(contents, to: current, source: folder)
		contentsOnDisk = contents
		renameIfStillUntitled()
		sheets = cache.names()
	}
}
