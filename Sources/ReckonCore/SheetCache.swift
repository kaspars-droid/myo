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

		let contents = try manager.contentsOfDirectory(
			at: source, includingPropertiesForKeys: [.contentModificationDateKey],
			options: [.skipsHiddenFiles])

		var copied: [String] = []

		for original in contents where original.pathExtension.lowercased() == Self.fileExtension {
			let name = original.lastPathComponent
			let local = url(for: name)

			if manager.fileExists(atPath: local.path), !isNewer(original, than: local) {
				continue
			}

			// A sheet in a cloud folder may be a placeholder that has never been
			// downloaded. Reading one gives nothing, and a sheet with no text
			// has no first line to be named after — which is how a folder full
			// of named sheets ends up listed as "Untitled".
			Self.materialise(original)

			guard let data = try? Data(contentsOf: original), !data.isEmpty else { continue }
			try data.write(to: local, options: .atomic)

			// The copy carries the original's date rather than today's, so
			// "has it changed since we fetched it" stays answerable even when
			// a cloud folder hands back files with dates set on another
			// machine, or a clock that disagrees with this one.
			if let stamped = try? original.resourceValues(forKeys: [.contentModificationDateKey])
				.contentModificationDate {
				try? manager.setAttributes([.modificationDate: stamped], ofItemAtPath: local.path)
			}

			copied.append(name)
		}

		return copied
	}

	/// Asks for a placeholder to be fetched, and waits briefly for it.
	///
	/// Briefly, because this runs while someone is waiting to see their sheets:
	/// a slow file is better missing from this pass than holding up the rest.
	private static func materialise(_ url: URL) {
		let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
			.ubiquitousItemDownloadingStatus
		guard status != nil, status != .current else { return }

		try? FileManager.default.startDownloadingUbiquitousItem(at: url)

		let deadline = Date().addingTimeInterval(3)
		while Date() < deadline {
			let now = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
				.ubiquitousItemDownloadingStatus
			if now == .current { return }
			Thread.sleep(forTimeInterval: 0.1)
		}
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

	public func remove(_ name: String, source: URL?) {
		try? manager.removeItem(at: url(for: name))
		if let source {
			try? manager.removeItem(at: source.appendingPathComponent(name))
		}
	}

	/// Throws away everything, for when a different folder is chosen.
	public func empty() {
		try? manager.removeItem(at: folder)
	}
}
