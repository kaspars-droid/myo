import Foundation

/// A local copy of a folder of sheets.
///
/// Sheets usually live in a cloud folder — Google Drive, Dropbox, iCloud — and
/// on a phone those are fetched on demand: opening one can be slow, and offline
/// it may not arrive at all. So the app keeps its own copy. Sheets open from
/// the copy, and edits are written to both it and the original.
///
/// Nothing clever happens on conflict: whoever wrote last wins. That is worth
/// knowing before trusting it with a sheet edited in two places at once.
public struct SheetCache: Sendable {
	public let folder: URL

	private var manager: FileManager { .default }

	/// Myo's own, rather than borrowed from the app whose format this once
	/// followed. A folder can hold both, and only these are Myo's sheets.
	///
	/// `myo` alone belongs to an accounting package, which is near enough to
	/// what this does to end up on the same machine, so the app's full name
	/// is used instead.
	public static let fileExtension = "myocalc"

	public init(folder: URL) {
		self.folder = folder
	}

	/// What a sheet is called on disk, e.g. `volvo.myo`.
	public func url(for name: String) -> URL {
		folder.appendingPathComponent(name)
	}

	public func makeFolder() throws {
		try manager.createDirectory(at: folder, withIntermediateDirectories: true)
	}

	// MARK: - Reading

	public func names() -> [String] {
		let contents = (try? manager.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])) ?? []

		let sheets = contents.filter { $0.pathExtension.lowercased() == Self.fileExtension }
		return SheetOrder.lastEditedFirst(sheets).map(\.lastPathComponent)
	}

	public func read(_ name: String) -> String? {
		try? String(contentsOf: url(for: name), encoding: .utf8)
	}

	// MARK: - Copying down

	/// Copies every sheet that is new, or newer, in the source folder.
	///
	/// A sheet edited here and not yet written back is left alone: the local
	/// copy is the newer one, and overwriting it would throw away the edit.
	/// Returns the names it brought down.
	@discardableResult
	public func refresh(from source: URL) throws -> [String] {
		try makeFolder()

		return try sheets(in: source).filter { try bringDown($0) }
			.map(\.lastPathComponent)
	}

	/// The sheets the source folder holds, in the order it listed them.
	///
	/// Asked for separately from fetching them because the two take wildly
	/// different amounts of time: a folder answers about itself quickly, and
	/// then each sheet in it may be a download. Knowing the names first is
	/// what lets the sheets be fetched several at a time, and shown as they
	/// land rather than all at the end.
	public func sheets(in source: URL) throws -> [URL] {
		try listing(of: source).filter {
			$0.pathExtension.lowercased() == Self.fileExtension
		}
	}

	/// Copies one sheet in, if the source has a newer version than this phone.
	/// Returns whether it copied anything.
	@discardableResult
	public func bringDown(_ original: URL) throws -> Bool {
		try bringDown(original, as: original.lastPathComponent)
	}

	/// The same, for a sheet that cannot be called here what it is called
	/// there.
	///
	/// Two reasons it might not be. A sheet picked on its own out of a cloud
	/// folder can share a name with one already here, and one quietly
	/// replacing the other is a loss. And a sheet kept as plain `.txt` — which
	/// the engine reads just as happily — has to end in `.myocalc` to be
	/// listed at all.
	@discardableResult
	public func bringDown(_ original: URL, as name: String) throws -> Bool {
		let local = url(for: name)

		if manager.fileExists(atPath: local.path), !isNewer(original, than: local) {
			return false
		}

		guard let data = Self.fetch(original) else { return false }

		// Nothing is worth replacing a sheet that has text in it. A file
		// that reads as empty is usually a placeholder that did not come
		// down rather than a sheet someone emptied, and the two are not
		// worth telling apart when one of the answers loses work. A sheet
		// this phone has never seen is a different case: empty is all
		// there is to fetch, and a new sheet should still appear.
		if data.isEmpty, manager.fileExists(atPath: local.path) { return false }

		try data.write(to: local, options: .atomic)

		// The copy carries the original's date rather than today's, so
		// "has it changed since we fetched it" stays answerable even when
		// a cloud folder hands back files with dates set on another
		// machine, or a clock that disagrees with this one.
		if let stamped = try? original.resourceValues(forKeys: [.contentModificationDateKey])
			.contentModificationDate {
			try? manager.setAttributes([.modificationDate: stamped], ofItemAtPath: local.path)
		}

		return true
	}

	/// What the source folder holds, asked for in a way a cloud folder answers
	/// truthfully.
	///
	/// A folder belonging to a file provider — iCloud Drive, Google Drive,
	/// Dropbox — is a local shadow of something else, and listing it plainly
	/// reports the shadow: a sheet added on another device may not be in it
	/// yet. A coordinated read is the ask that makes the provider go and look
	/// first, so a sheet written elsewhere a moment ago is in the answer.
	private func listing(of source: URL) throws -> [URL] {
		var found: [URL]?
		var failure: NSError?

		NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &failure) { url in
			found = try? manager.contentsOfDirectory(
				at: url, includingPropertiesForKeys: [.contentModificationDateKey],
				options: [.skipsHiddenFiles])
		}

		// Coordination can be refused — most often by the provider being busy
		// with the same folder — and a stale listing beats no listing at all.
		if let found { return found }
		return try manager.contentsOfDirectory(
			at: source, includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])
	}

	/// Reads a sheet out of the source folder, fetching it first if it is only
	/// a placeholder there.
	///
	/// The old version of this asked iCloud whether the file needed
	/// downloading, and gave up when the answer was nothing at all. Only
	/// iCloud answers that question: every other provider returns nil, which
	/// was read as "already here" — so a Google Drive or Dropbox sheet was
	/// never fetched, read as no bytes, and quietly skipped.
	///
	/// A coordinated read is the ask that every provider understands. It
	/// blocks until the file is really there, so this must not run on the
	/// thread drawing the screen.
	private static func fetch(_ url: URL) -> Data? {
		// iCloud still wants telling separately, and starting the download
		// before coordinating means the wait below is usually already over.
		if let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
			.ubiquitousItemDownloadingStatus, status != .current {
			try? FileManager.default.startDownloadingUbiquitousItem(at: url)
		}

		var data: Data?
		var failure: NSError?

		NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &failure) { url in
			data = try? Data(contentsOf: url)
		}

		return failure == nil ? data : nil
	}

	private func isNewer(_ one: URL, than other: URL) -> Bool {
		func modified(_ url: URL) -> Date {
			(try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
				?? .distantPast
		}
		// A second of slack: copying does not preserve timestamps exactly.
		return modified(one).timeIntervalSince(modified(other)) > 1
	}

	// MARK: - Writing

	/// Writes to the local copy, then back to where the sheet came from.
	///
	/// The local write is the one that must not fail; the write back can, when
	/// the phone is offline, and the sheet is still safe on the device.
	@discardableResult
	public func write(_ text: String, to name: String, source: URL?) throws -> Bool {
		try makeFolder()
		try Data(text.utf8).write(to: url(for: name), options: .atomic)

		guard let source else { return false }
		return Self.writeBack(text, to: source.appendingPathComponent(name))
	}

	/// Writes to a file kept somewhere else — a cloud provider's own copy.
	///
	/// That provider is another process watching for changes so it can upload
	/// them. A coordinated write is how it is told; an uncoordinated one can be
	/// missed, or can collide with a download landing at the same moment.
	@discardableResult
	public static func writeBack(_ text: String, to destination: URL) -> Bool {
		var failure: NSError?
		var wrote = false

		NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
									   error: &failure) { url in
			wrote = (try? Data(text.utf8).write(to: url, options: .atomic)) != nil
		}

		return wrote && failure == nil
	}

	/// The auto-given names, the ones worth replacing once a sheet says what
	/// it is: `Untitled.myocalc`, `Untitled 2.myocalc`, and so on.
	public static func isAutomatic(_ fileName: String) -> Bool {
		let stem = (fileName as NSString).deletingPathExtension
		guard stem == "Untitled" || stem.hasPrefix("Untitled ") else { return false }
		guard stem != "Untitled" else { return true }

		let suffix = stem.dropFirst("Untitled ".count)
		return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
	}

	/// Turns a sheet's first line into something a file system will accept.
	///
	/// Returns nil when there is nothing usable left, which is the signal to
	/// keep whatever the file is already called rather than invent something.
	public static func fileName(forTitle title: String) -> String? {
		let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)

		let cleaned = title
			.components(separatedBy: forbidden).joined(separator: " ")
			.replacingOccurrences(of: "  ", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.prefix(60)
			.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

		guard !cleaned.isEmpty, cleaned != "Untitled" else { return nil }
		return "\(cleaned).\(Self.fileExtension)"
	}

	/// What to rename a sheet's file to, now that its first line has changed.
	///
	/// Returns nil to leave the name alone: when the line has not changed,
	/// when nothing usable is left of it, or when it asks for the name the
	/// file already has.
	///
	/// Only a change renames, never a mere difference. A sheet called
	/// `2020.myocalc` whose first line reads `#rēķini 2020` keeps the name it
	/// was given until someone edits that line, because a file its owner
	/// named is theirs to have named.
	public static func newName(for current: String,
							   titleWas: String, titleIs: String) -> String? {
		guard titleIs != titleWas,
			  let wanted = fileName(forTitle: titleIs),
			  wanted != current
		else { return nil }

		return wanted
	}

	/// Renames a sheet, in the cache and wherever it came from.
	@discardableResult
	public func rename(_ name: String, to newName: String, source: URL?) -> Bool {
		guard name != newName else { return false }

		let manager = FileManager.default
		guard !manager.fileExists(atPath: url(for: newName).path) else { return false }
		guard (try? manager.moveItem(at: url(for: name), to: url(for: newName))) != nil else {
			return false
		}

		if let source {
			let from = source.appendingPathComponent(name)
			let to = source.appendingPathComponent(newName)
			if manager.fileExists(atPath: from.path), !manager.fileExists(atPath: to.path) {
				try? manager.moveItem(at: from, to: to)
			}
		}

		return true
	}

	/// A name no sheet in the folder is using yet.
	public func unusedName(startingFrom stem: String) -> String {
		var candidate = "\(stem).\(Self.fileExtension)"
		var counter = 2

		while manager.fileExists(atPath: url(for: candidate).path) {
			candidate = "\(stem) \(counter).\(Self.fileExtension)"
			counter += 1
		}

		return candidate
	}

	/// The same question asked of a folder that is not the cache: what can this
	/// sheet be called in there without landing on top of one already in it.
	///
	/// A sheet moving into a folder it did not come from is the case for this.
	/// Two sheets called `Untitled` is a nuisance; one quietly replacing the
	/// other is a loss.
	public static func unusedName(like name: String, in folder: URL) -> String {
		let manager = FileManager.default
		let stem = (name as NSString).deletingPathExtension
		let extended = (name as NSString).pathExtension

		var candidate = name
		var counter = 2

		while manager.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
			candidate = "\(stem) \(counter).\(extended)"
			counter += 1
		}

		return candidate
	}

	public func remove(_ name: String, source: URL?) {
		try? manager.removeItem(at: url(for: name))
		if let source {
			try? manager.removeItem(at: source.appendingPathComponent(name))
		}
	}

	/// Throws away everything, for when a different folder is chosen.
	///
	/// Except the sheets named, which are kept. A sheet linked to a file of
	/// its own is not this folder's copy of anything, so changing folders is
	/// not a reason to lose it.
	public func empty(keeping kept: Set<String> = []) {
		guard !kept.isEmpty else {
			try? manager.removeItem(at: folder)
			return
		}

		for name in names() where !kept.contains(name) {
			try? manager.removeItem(at: url(for: name))
		}
	}
}
