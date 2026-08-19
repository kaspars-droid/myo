import Foundation

/// Keeps the chosen folder reachable after the app has been quit and opened
/// again.
///
/// Sandboxed, a path is not access. The open panel grants the folder, but that
/// grant dies with the process, so a remembered path comes back next launch
/// pointing at somewhere the app is no longer allowed to read. A
/// security-scoped bookmark is the only thing that carries the grant across,
/// which is why the folder is stored as one rather than as the string it used
/// to be.
///
/// Only the folder is bookmarked. Everything the app touches — listing sheets,
/// reading one, writing it back, renaming it, making a new one — happens
/// inside it, so one grant covers the lot.
@MainActor
final class FolderAccess {
	private static let bookmarkKey = "sheetFolderBookmark"
	/// What the folder used to be stored as, before any of this. Still read,
	/// so a folder chosen by an older build is not silently forgotten.
	private static let legacyPathKey = "sheetFolder"

	/// The folder access was started on, held so it can be balanced by the
	/// matching stop. Nil when the folder came from somewhere that needs no
	/// starting, such as the open panel.
	private var accessed: URL?

	/// The folder from last launch, already opened for access, or nil if there
	/// is none to go back to.
	func restore() -> URL? {
		guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
			// Chosen by a build that stored a path. It will work only where the
			// sandbox already allows it; choosing the folder again replaces it
			// with a bookmark, which always will.
			return UserDefaults.standard.string(forKey: Self.legacyPathKey)
				.map { URL(fileURLWithPath: $0) }
		}

		var stale = false
		guard let folder = try? URL(resolvingBookmarkData: data,
									options: .withSecurityScope,
									relativeTo: nil,
									bookmarkDataIsStale: &stale)
		else { return nil }

		begin(folder)

		// A stale bookmark resolves this once and then stops. Writing a fresh
		// one now is what keeps a folder that has been moved or renamed from
		// being lost on the launch after next.
		if stale { remember(folder) }

		return folder
	}

	/// Takes access to `folder` and remembers it for next time.
	func adopt(_ folder: URL) {
		// The same folder arriving under a different spelling is not a new
		// folder. A bookmark resolves to its own idea of the path, and letting
		// that count as a change would stop the access that is working and
		// start one on a URL carrying no scope at all — losing the folder
		// mid-session, for nothing.
		guard !isAccessed(folder) else { return }

		begin(folder)
		remember(folder)
	}

	private func isAccessed(_ folder: URL) -> Bool {
		accessed?.standardizedFileURL.resolvingSymlinksInPath()
			== folder.standardizedFileURL.resolvingSymlinksInPath()
	}

	/// Starts access, and lets go of whatever was held before.
	private func begin(_ folder: URL) {
		if let accessed, !isAccessed(folder) {
			accessed.stopAccessingSecurityScopedResource()
		}

		// False means there was no scope to start — a URL straight from the
		// open panel is granted outright. Recording nil then keeps the stop
		// from being called on something that was never started.
		accessed = folder.startAccessingSecurityScopedResource() ? folder : nil
	}

	private func remember(_ folder: URL) {
		guard let data = try? folder.bookmarkData(options: .withSecurityScope,
												  includingResourceValuesForKeys: nil,
												  relativeTo: nil)
		else {
			// Nothing to make a bookmark from: opening a sheet from the Finder
			// grants the file, not the folder around it. Deliberately writing
			// nothing, so the folder that is remembered stays one that works.
			return
		}

		UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
		UserDefaults.standard.removeObject(forKey: Self.legacyPathKey)
	}
}
