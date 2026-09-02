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
					// Before the first sheet lands there is nothing to look at,
					// and a folder in iCloud can take a while to hand one over.
					// An empty screen that long reads as a dead app.
					.overlay {
						if store.current == nil, store.isFetching {
							ProgressView("Fetching sheets…")
								.foregroundStyle(Palette.label)
						}
					}
			}
			.preferredColorScheme(.dark)
			.onAppear {
				store.start()
				store.beginKeepingUp()
			}
			.onChange(of: store.document) { store.scheduleSave() }
			// Leaving the app is the moment an edit is most likely to be lost:
			// the save is on a short timer, and swiping away cancels it.
			.onChange(of: scenePhase) { _, phase in
				if phase == .active {
					store.refresh()
					store.beginKeepingUp()
				} else {
					store.settleNow()
					store.endKeepingUp()
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
				if store.isFetching, store.sheets.isEmpty {
					Text("Fetching sheets…")
				} else if store.sheets.isEmpty {
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
					if store.isFetching {
						Text("Fetching sheets…")
					} else {
						Button("Refresh from Cloud") { store.refresh() }
					}
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

	/// Whether sheets are still coming down. The screen says so, because a
	/// folder that takes a while to arrive otherwise looks like a dead app.
	@Published private(set) var isFetching = false

	private let cache = SheetCache(folder: URL.documentsDirectory.appendingPathComponent("Sheets"))
	private var saveWork: Task<Void, Never>?
	private var renameWork: Task<Void, Never>?
	private var refreshWork: Task<Void, Never>?

	/// Fires when the folder or the open sheet is touched by anything else,
	/// which is how an edit made on the Mac shows up here without asking.
	private let watcher = FolderWatcher()

	/// A cloud folder does not always announce a change: some providers only
	/// go and look when someone reads the folder, and a phone that has been
	/// sitting on one sheet has not read it in a while. So the folder is also
	/// asked, at a distance apart that is cheap to pay while the app is open.
	private var pollWork: Task<Void, Never>?
	private static let pollInterval = Duration.seconds(20)

	/// How many sheets to fetch at once. Enough to hide the latency of any one
	/// of them, not so many that a folder of hundreds opens that many requests
	/// to a provider at the same moment.
	private static let atOnce = 5
	private var contentsOnDisk = ""
	/// The first line the file is named for. A rename follows a change to it,
	/// not a difference from it, so a sheet named by hand keeps that name.
	private var titleOnDisk = ""

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
		let restored = restoreFolder()
		sheets = cache.names()

		// Whatever is already on the phone opens straight away. Waiting for a
		// cloud folder to answer before showing a sheet that is right here
		// would be a spinner in place of the sheet, every launch.
		if let first = sheets.first {
			load(first)
			if restored { refresh() }
			return
		}

		guard restored else { return openFirstSheet() }

		// Nothing here yet and a folder to ask: the first fetch decides. Making
		// a sheet now would be making one the folder is about to contradict.
		Task {
			await fetch()
			if current == nil { openFirstSheet() }
		}
	}

	/// Backed by a file from the start: an unsaved sheet on screen is a sheet
	/// waiting to be lost.
	private func openFirstSheet() {
		let name = cache.unusedName(startingFrom: "Myo Calc")
		_ = try? cache.write(SheetView.sample, to: name, source: folder)
		sheets = cache.names()
		load(name)
	}

	/// The folder is reached again through a bookmark. A plain path would not
	/// do: permission to read someone else's folder does not survive a relaunch.
	private func restoreFolder() -> Bool {
		guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }

		var stale = false
		guard let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
			  resolved.startAccessingSecurityScopedResource()
		else { return false }

		folder = resolved
		return true
	}

	// MARK: - The folder

	func choose(_ picked: URL) {
		settleNow()
		folder?.stopAccessingSecurityScopedResource()

		guard picked.startAccessingSecurityScopedResource() else { return }

		// The list is the folder, so the previous folder's sheets go. Anything
		// made before a folder was chosen goes with them: it was scratch, and
		// keeping it would leave sheets in the list that are nowhere in the
		// folder you just picked.
		cache.empty()
		try? cache.makeFolder()

		folder = picked
		current = nil
		contentsOnDisk = ""
		titleOnDisk = ""
		sheets = []
		// The last folder's sheet must not sit on screen looking like one of
		// this folder's.
		document = SheetDocument(text: "")

		Task {
			// Asking a provider to write down where a folder is can itself take
			// a moment, so it happens here rather than in front of the picker
			// closing.
			await Task.detached(priority: .utility) {
				if let data = try? picked.bookmarkData() {
					UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
				}
			}.value

			// Sheets open as they arrive, so by the time this returns one is
			// usually already on screen.
			await fetch()

			guard sheets.isEmpty else { return }

			// An empty folder still needs somewhere to type.
			let name = cache.unusedName(startingFrom: "Untitled")
			_ = try? cache.write("", to: name, source: picked)
			sheets = cache.names()
			load(name)
		}
	}

	/// Brings down anything the folder has that this phone does not, and
	/// re-reads the open sheet if it changed elsewhere.
	///
	/// The fetching part waits on a cloud provider, which can take seconds, so
	/// it happens away from the main thread: doing it here is what made the
	/// menu's own Refresh look broken, since the screen could not redraw until
	/// every placeholder had been asked for.
	func refresh() {
		guard folder != nil, refreshWork == nil else { return }

		refreshWork = Task {
			defer { refreshWork = nil }
			await fetch()
			guard !Task.isCancelled else { return }
			adopt()
		}
	}

	/// The waiting part, kept off the thread that draws.
	///
	/// Several sheets at once, and each one shown the moment it lands. One at a
	/// time meant a folder of thirty took a minute, every sheet queued behind
	/// the download before it and nothing on screen until the last arrived —
	/// which is indistinguishable from the app having died.
	private func fetch() async {
		guard let folder else { return }

		let cache = self.cache
		isFetching = true
		defer { isFetching = false }

		let waiting = await Task.detached(priority: .utility) { () -> [URL] in
			try? cache.makeFolder()
			return (try? cache.sheets(in: folder)) ?? []
		}.value

		await withTaskGroup(of: Bool.self) { group in
			var next = waiting.makeIterator()

			func fetchOne() {
				guard let sheet = next.next() else { return }
				group.addTask(priority: .utility) { (try? cache.bringDown(sheet)) ?? false }
			}

			for _ in 0..<PhoneStore.atOnce { fetchOne() }

			while let arrived = await group.next() {
				if arrived { self.arrived() }
				fetchOne()
			}
		}
	}

	/// Shows what has come down so far.
	private func arrived() {
		sheets = cache.names()

		// The first sheet to land is the one to open. Waiting for the whole
		// folder before showing any of it is the difference between a second
		// and a minute, on a folder where every sheet is a download.
		if current == nil, let first = sheets.first { load(first) }
	}

	/// Takes on what the last fetch brought down.
	private func adopt() {
		sheets = cache.names()

		guard let current, let text = cache.read(current), text != contentsOnDisk else { return }

		// Only when there is nothing unsaved. A fetch landing mid sentence
		// must not take the sentence away: the local edit is a second or two
		// from being written back, and until then the screen is the only place
		// it exists.
		guard document.fileContents == contentsOnDisk else { return }

		contentsOnDisk = text
		document = SheetDocument(text: text)
		titleOnDisk = document.name
		watch()
	}

	// MARK: - Sheets

	func load(_ name: String) {
		settleNow()

		let text = cache.read(name) ?? ""
		contentsOnDisk = text
		document = SheetDocument(text: text)
		titleOnDisk = document.name
		current = name
		watch()
	}

	func newSheet() {
		settleNow()

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
	/// wait for either timer: switching sheets, or leaving the app.
	func settleNow() {
		saveNow()
		renameNow()
	}

	// MARK: - Keeping up with the folder

	/// Starts noticing changes made anywhere else, and stops when the app is
	/// put away: neither watching nor asking is worth a thing in the
	/// background, and both cost battery there.
	func beginKeepingUp() {
		watch()

		pollWork?.cancel()
		pollWork = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: PhoneStore.pollInterval)
				guard !Task.isCancelled else { return }
				self?.refresh()
			}
		}
	}

	func endKeepingUp() {
		pollWork?.cancel()
		pollWork = nil
		watcher.stop()
	}

	/// The folder answers "a sheet was added or replaced"; the open sheet
	/// answers "this one was edited in place", which never touches the folder.
	private func watch() {
		guard let folder else { return }

		watcher.onChange = { [weak self] in self?.refresh() }
		watcher.watch(folder: folder,
					  file: current.map { folder.appendingPathComponent($0) })
	}

	/// The file is called what the sheet's first line says, once that line has
	/// been changed. `SheetCache.newName` decides; this carries it out.
	func renameNow() {
		renameWork?.cancel()

		guard let name = current,
			  let wanted = SheetCache.newName(for: name,
											  titleWas: titleOnDisk, titleIs: document.name)
		else { return }

		titleOnDisk = document.name

		guard cache.rename(name, to: wanted, source: folder) else { return }

		current = wanted
		sheets = cache.names()
		watch()
	}

	func saveNow() {
		guard let current else { return }

		let contents = document.fileContents
		guard contents != contentsOnDisk else { return }

		_ = try? cache.write(contents, to: current, source: folder)
		contentsOnDisk = contents
		sheets = cache.names()
	}
}
