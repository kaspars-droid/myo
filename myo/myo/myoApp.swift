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
					// Two importers, on two different views on purpose: one
					// view carrying both is one view with two sheets to
					// present, and the second one does not open.
					//
					// Any file, rather than the two kinds actually wanted. A
					// provider decides what type it reports for an item, and
					// Dropbox does not report a .myocalc file as this app's
					// type — it has never heard of the format, and says so in
					// the only way it can, which is to call the file data and
					// nothing more. Asked for the honest types, the picker
					// greys out every sheet in Dropbox: the very files it was
					// opened to find.
					//
					// So anything may be picked, and what arrives is checked
					// instead — see `addSheets`. The test moved from before the
					// pick to after the fetch, which is the one place a
					// provider cannot be wrong about what a file holds.
					.fileImporter(isPresented: $store.isAddingSheets,
								  allowedContentTypes: [.data],
								  allowsMultipleSelection: true) { result in
						if case .success(let picked) = result { store.addSheets(picked) }
					}
					.alert("Not a sheet", isPresented: Binding(
						get: { store.trouble != nil },
						set: { if !$0 { store.trouble = nil } }
					)) {
						Button("OK", role: .cancel) {}
					} message: {
						Text(store.trouble ?? "")
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
			// A sheet tapped in the Files app, or in Google Drive's or
			// Dropbox's own app, opens here — and is kept, so it is still
			// listed tomorrow without being found again.
			.onOpenURL { store.addSheets([$0]) }
		}
	}

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		// Toolbar items sit on a shared capsule of glass by default, which
		// round two plain icons reads as a button they are not.
		//
		// That capsule is iOS 26's. Before it there is nothing behind the icons
		// to hide, so the plain item is already what asking for it would give —
		// which is the whole of what this app needed iOS 26 for.
		if #available(iOS 26.0, *) {
			ToolbarItem(placement: .topBarTrailing) { newSheetButton }
				.sharedBackgroundVisibility(.hidden)
			ToolbarItem(placement: .topBarTrailing) { sheetMenu }
				.sharedBackgroundVisibility(.hidden)
		} else {
			ToolbarItem(placement: .topBarTrailing) { newSheetButton }
			ToolbarItem(placement: .topBarTrailing) { sheetMenu }
		}
	}

	private var newSheetButton: some View {
		Button { store.newSheet() } label: { Image(systemName: "plus") }
			.accessibilityLabel("New sheet")
	}

	private var sheetMenu: some View {
		SheetMenuButton(store: store)
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
	@Published var isAddingSheets = false

	/// The one thing worth interrupting someone to say: what they picked was
	/// not a sheet. Everything else the app does either works or is waited on.
	@Published var trouble: String?
	@Published private(set) var sheets: [String] = []
	@Published private(set) var current: String?
	@Published private(set) var folder: URL?

	/// Whether sheets are still coming down. The screen says so, because a
	/// folder that takes a while to arrive otherwise looks like a dead app.
	@Published private(set) var isFetching = false

	/// Where sheets go when nowhere else has been chosen.
	///
	/// The app's own Documents folder, which the Files app shows under On My
	/// iPhone. It is treated as a source folder like any other, so a sheet
	/// with no home elsewhere is still a plain file its owner can open, copy
	/// and back up — and choosing a real folder later moves it there.
	private nonisolated static let homeFolder = URL.documentsDirectory

	/// The local copies, kept where nobody has to look at them.
	///
	/// These used to live in Documents, and so appeared in the Files app: a
	/// Dropbox sheet showed up twice, once where it lives and once as this
	/// app's copy of it. A copy exists so that a sheet opens instantly and
	/// works offline. Nobody should have to think about it, and nobody can
	/// avoid thinking about a second sheet with the same name.
	private let cache = SheetCache(
		folder: URL.applicationSupportDirectory.appendingPathComponent("Sheets"))
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

	/// The sheets that came from a file of their own rather than from the
	/// folder, by the name they are kept under here.
	///
	/// Google Drive, Dropbox and Box do not let a folder be picked at all:
	/// their File Provider extensions do not offer it, so the picker shows
	/// them greyed out and there is nothing this app can do about that. Files
	/// they will hand over. So sheets can be added one at a time instead —
	/// kept, fetched and written back exactly as a folder's are.
	///
	/// What is lost is discovery. The permission covers the file, not the
	/// folder it sits in, so a sheet added over there tomorrow does not turn
	/// up here on its own; it has to be added the same way.
	private var linked: [String: URL] = [:]

	// Read from a detached task, where the actor this class lives on is not
	// the one asking. A constant string has nothing to protect.
	private nonisolated static let bookmarkKey = "folderBookmark"
	private nonisolated static let linkKey = "linkedSheets"

	/// Whether a sheet is one single file picked out of a cloud folder, rather
	/// than one of a folder's.
	func isLinked(_ name: String) -> Bool { linked[name] != nil }

	/// Whether the sheets come from somewhere the person picked, as opposed to
	/// the app's own folder they land in when nobody has picked anything.
	var hasChosenFolder: Bool {
		folder != nil && folder != Self.homeFolder
	}

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
		// Both, always: `||` would skip the second the moment the first said
		// yes, and a phone can perfectly well have a folder and linked sheets.
		let hasFolder = restoreFolder()
		_ = restoreLinks()
		emptyTheOldCache(hadChosenFolder: hasFolder)

		// There is always a folder now. Without one picked it is the app's
		// own, which is a real folder in the Files app rather than a private
		// hole sheets disappear into.
		if folder == nil { folder = Self.homeFolder }

		sheets = cache.names()

		// Whatever is already on the phone opens straight away. Waiting for a
		// cloud folder to answer before showing a sheet that is right here
		// would be a spinner in place of the sheet, every launch.
		if let first = sheets.first {
			load(first)
			refresh()
			return
		}

		// Nothing here yet: the first fetch decides. Making a sheet now would
		// be making one the folder is about to contradict.
		Task {
			await fetch()
			if current == nil { openFirstSheet() }
		}
	}

	/// Clears out where the copies used to be kept.
	///
	/// They were in Documents, which the Files app shows, so every sheet from
	/// a cloud folder appeared there a second time. A copy is dropped: the
	/// sheet it copies is still wherever it lives, and the fetch will bring it
	/// back down. A sheet that is nobody's copy is moved up into Documents
	/// proper, where it stays visible and stays the only one there is.
	private func emptyTheOldCache(hadChosenFolder: Bool) {
		let old = SheetCache(folder: Self.homeFolder.appendingPathComponent("Sheets"))
		guard FileManager.default.fileExists(atPath: old.folder.path) else { return }

		for name in old.names() where !hadChosenFolder && linked[name] == nil {
			guard let text = old.read(name) else { continue }
			let wanted = SheetCache.unusedName(like: name, in: Self.homeFolder)
			_ = SheetCache.writeBack(text, to: Self.homeFolder.appendingPathComponent(wanted))
		}

		try? FileManager.default.removeItem(at: old.folder)
	}

	/// Backed by a file from the start: an unsaved sheet on screen is a sheet
	/// waiting to be lost.
	private func openFirstSheet() {
		let name = cache.unusedName(startingFrom: "Myo Calc")
		_ = try? cache.write(SheetView.sample, to: name, source: folder)
		sheets = cache.names()
		load(name)
	}

	/// Moves the sheets that have no home into the folder being given one.
	///
	/// The local copy is kept and keeps its name, so nothing has to be fetched
	/// straight back down. A sheet whose name is already taken up there is
	/// renamed on both sides rather than written over the top of one somebody
	/// else's device put there.
	/// Returns the names it managed to write, under which they were kept here
	/// before the move — which is what the app's own folder still calls them.
	@discardableResult
	private func rehome(into picked: URL) -> [String] {
		var moved: [String] = []

		for name in cache.names() {
			guard let text = cache.read(name) else { continue }

			let wanted = SheetCache.unusedName(like: name, in: picked)
			if wanted != name, !cache.rename(name, to: wanted, source: nil) { continue }

			if SheetCache.writeBack(text, to: picked.appendingPathComponent(wanted)) {
				moved.append(name)
			}
		}

		return moved
	}

	/// The sheets just moved into a folder of their own choosing are not left
	/// behind in the app's as well. One sheet, in the place asked for.
	///
	/// Only the ones that arrived. A sheet that failed to write into the new
	/// folder still exists in exactly one place, and this is it.
	private func emptyHomeFolder(of moved: [String]) {
		let home = SheetCache(folder: Self.homeFolder)
		for name in moved { home.remove(name, source: nil) }
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

	/// The linked sheets are reached again the same way the folder is, and for
	/// the same reason: permission to read someone else's file does not
	/// survive a relaunch.
	///
	/// One that will not resolve — the provider signed out, the file moved or
	/// deleted — is dropped from the list but left on the phone, where it is
	/// still a sheet that can be read and edited. The bookmark is kept rather
	/// than pruned, because "not right now" and "never again" look the same
	/// from here, and the next launch may well get it back.
	private func restoreLinks() -> Bool {
		guard let stored = UserDefaults.standard.dictionary(forKey: Self.linkKey) as? [String: Data]
		else { return false }

		for (name, data) in stored {
			var stale = false
			guard let resolved = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
				  resolved.startAccessingSecurityScopedResource()
			else { continue }

			linked[name] = resolved
		}

		return !linked.isEmpty
	}

	private func rememberLinks() {
		let links = linked

		Task.detached(priority: .utility) {
			var stored: [String: Data] = [:]
			for (name, url) in links {
				if let data = try? url.bookmarkData() { stored[name] = data }
			}
			UserDefaults.standard.set(stored, forKey: PhoneStore.linkKey)
		}
	}

	// MARK: - Sheets of their own

	/// Takes on sheets picked one at a time, for the cloud folders that cannot
	/// be picked whole, and for a sheet handed over by another app.
	func addSheets(_ picked: [URL]) {
		var arriving: [(name: String, source: URL)] = []
		var toOpen: String?

		for original in picked {
			// One already here is opened rather than fetched a second time
			// under a second name.
			if let known = nameOfLink(to: original) {
				toOpen = toOpen ?? known
				continue
			}

			guard original.startAccessingSecurityScopedResource() else { continue }

			let name = SheetCache.unusedName(like: sheetName(of: original), in: cache.folder)
			linked[name] = original
			arriving.append((name: name, source: original))
			toOpen = toOpen ?? name
		}

		guard let toOpen else { return }
		if !arriving.isEmpty { rememberLinks() }

		Task {
			isFetching = true
			await fetchAll(arriving)
			isFetching = false

			sheets = cache.names()

			// A sheet that did not come down is not a sheet here yet, and must
			// not be opened: an empty screen in front of a file that failed to
			// fetch is an empty file a save later.
			var dropped = arriving.filter { !sheets.contains($0.name) }

			// The picker filters by the type a provider claims, which is a
			// claim and not a fact. A sheet is text; anything that will not
			// read as text is dropped and said so, rather than sitting in the
			// list as a sheet full of nothing.
			let refused = arriving.filter { sheets.contains($0.name) && cache.read($0.name) == nil }
			for sheet in refused { cache.remove(sheet.name, source: nil) }
			dropped += refused

			for sheet in dropped { linked[sheet.name] = nil }
			if !dropped.isEmpty {
				rememberLinks()
				sheets = cache.names()
			}
			if let first = refused.first {
				trouble = "\(first.source.lastPathComponent) is not a text file."
			}

			guard sheets.contains(toOpen) else { return }
			load(toOpen)
		}
	}

	private func nameOfLink(to original: URL) -> String? {
		linked.first { $0.value.standardizedFileURL == original.standardizedFileURL }?.key
	}

	/// What a picked file is called once it is one of this app's sheets.
	///
	/// Only `.myocalc` files are listed, so a sheet kept as plain text would
	/// otherwise be picked and then never appear. It is copied under a name
	/// that will show up; the original keeps the name it has, and is written
	/// back to as it is.
	private func sheetName(of original: URL) -> String {
		let name = original.lastPathComponent
		guard name.lowercased().hasSuffix(".\(SheetCache.fileExtension)") else {
			return "\((name as NSString).deletingPathExtension).\(SheetCache.fileExtension)"
		}
		return name
	}

	/// Where a sheet is written back to: its own file if it has one, otherwise
	/// its place in the chosen folder.
	private func home(of name: String) -> URL? {
		linked[name] ?? folder?.appendingPathComponent(name)
	}

	// MARK: - The folder

	func choose(_ picked: URL) {
		settleNow()
		folder?.stopAccessingSecurityScopedResource()

		guard picked.startAccessingSecurityScopedResource() else { return }

		// The list is the folder, so the previous folder's copies go: they are
		// that folder's sheets, and keeping them would list sheets that are
		// nowhere in the one just picked.
		//
		// Sheets written before any folder was chosen are not copies of
		// anything. They are the only version there is, and they used to be
		// deleted here along with the rest — a week of use thrown away by
		// choosing a folder, silently, with nothing anywhere to get it back
		// from. Those move into the folder being chosen instead.
		if !hasChosenFolder {
			emptyHomeFolder(of: rehome(into: picked))
		} else {
			// The linked ones stay. They are not this folder's copies of
			// anything — they are single files somewhere else, and the file is
			// still there whichever folder is chosen here.
			cache.empty(keeping: Set(linked.keys))
		}
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
	/// it happens away from the main thread. Done on the main thread the screen
	/// cannot redraw until every placeholder has been asked for, which is a
	/// frozen app for as long as the folder takes to answer.
	func refresh() {
		guard folder != nil || !linked.isEmpty, refreshWork == nil else { return }

		refreshWork = Task {
			defer { refreshWork = nil }
			await fetch()
			guard !Task.isCancelled else { return }
			adopt()
		}
	}

	/// The waiting part, kept off the thread that draws.
	///
	/// Both kinds of sheet: the chosen folder's, and the ones added on their
	/// own because their provider would not hand over a folder.
	private func fetch() async {
		isFetching = true
		defer { isFetching = false }

		await fetchAll(await fromFolder())
		await fetchAll(fromLinks())
	}

	/// What the chosen folder holds, asked for away from the main thread as
	/// well: a folder belonging to a cloud provider can take seconds just to
	/// say what is in it.
	private func fromFolder() async -> [(name: String, source: URL)] {
		guard let folder else { return [] }

		let cache = self.cache
		// A linked sheet is written back to its own file, so the folder's
		// copy of that name is not brought down over the top of it.
		let taken = Set(linked.keys)

		return await Task.detached(priority: .utility) { () -> [(name: String, source: URL)] in
			try? cache.makeFolder()
			return ((try? cache.sheets(in: folder)) ?? [])
				.map { (name: $0.lastPathComponent, source: $0) }
				.filter { !taken.contains($0.name) }
		}.value
	}

	private func fromLinks() -> [(name: String, source: URL)] {
		linked.map { (name: $0.key, source: $0.value) }
	}

	/// Fetches a list of sheets, several at once, showing each the moment it
	/// lands.
	///
	/// One at a time meant a folder of thirty took a minute, every sheet queued
	/// behind the download before it and nothing on screen until the last
	/// arrived — which is indistinguishable from the app having died.
	private func fetchAll(_ waiting: [(name: String, source: URL)]) async {
		let cache = self.cache

		await withTaskGroup(of: Bool.self) { group in
			var next = waiting.makeIterator()

			func fetchOne() {
				guard let sheet = next.next() else { return }
				group.addTask(priority: .utility) {
					(try? cache.bringDown(sheet.source, as: sheet.name)) ?? false
				}
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
		discardEmpty(before: name)
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

	/// Throws away the sheet being left, if there is nothing left in it.
	///
	/// Deleting every character and moving on is a delete in every sense but
	/// the one the file system knows about. Without this the folder fills up
	/// with empty sheets called Untitled that nobody meant to keep, and the
	/// list gets longer every time somebody starts something and thinks better
	/// of it.
	///
	/// Never a linked one. That file lives in somebody's Dropbox or Drive,
	/// where this app deletes nothing: emptying it is an edit like any other,
	/// and it is written back as one. An empty sheet there stays an empty
	/// sheet, which is what its owner asked for by emptying it.
	///
	/// Discarding happens before the save rather than after, so an empty sheet
	/// is not written out a last time on its way to being deleted.
	private func discardEmpty(before next: String) {
		guard let name = current, name != next, linked[name] == nil else { return }
		guard document.fileContents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
		else { return }

		cache.remove(name, source: folder)

		// Cleared first, so the save that follows has no file to write to.
		current = nil
		contentsOnDisk = ""
		titleOnDisk = ""
		sheets = cache.names()
	}

	/// Deletes a sheet — or lets go of one, which is not the same thing.
	///
	/// A sheet from the chosen folder, or from the app's own, is deleted there
	/// too. That is where it lives, and a delete that leaves the file behind
	/// to be fetched again tomorrow is not a delete.
	///
	/// A linked sheet is the other case. It lives in somebody's Dropbox or
	/// Google Drive, put there on purpose, and all this app was ever given was
	/// sight of that one file. Letting go of it here is what was asked for.
	/// Reaching into their cloud to destroy the original is not, and the two
	/// are one swipe apart.
	func remove(_ name: String) {
		let wasLinked = linked[name] != nil

		if wasLinked {
			linked[name] = nil
			rememberLinks()
		}

		cache.remove(name, source: wasLinked ? nil : folder)
		sheets = cache.names()

		guard current == name else { return }

		// The sheet on screen has just been deleted out from under it. Nothing
		// is saved back: `current` goes first, so the save that follows the
		// screen clearing has no file to write to.
		current = nil
		contentsOnDisk = ""
		titleOnDisk = ""
		document = SheetDocument(text: "")

		if let first = sheets.first { load(first) } else { newSheet() }
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
		let file = current.flatMap { home(of: $0) }
		guard folder != nil || file != nil else { return }

		watcher.onChange = { [weak self] in self?.refresh() }
		watcher.watch(folder: folder, file: file)
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

		// A linked sheet keeps the file name it was picked under. That name
		// belongs to a file somewhere else, chosen by hand, and renaming it
		// would mean writing in the folder it sits in — which is the one thing
		// picking a file rather than a folder does not give permission to do.
		guard linked[name] == nil else { return }

		guard cache.rename(name, to: wanted, source: folder) else { return }

		current = wanted
		sheets = cache.names()
		watch()
	}

	func saveNow() {
		guard let current else { return }

		let contents = document.fileContents
		guard contents != contentsOnDisk else { return }

		_ = try? cache.write(contents, to: current, source: nil)
		if let home = home(of: current) { _ = SheetCache.writeBack(contents, to: home) }
		contentsOnDisk = contents
		sheets = cache.names()
	}
}
