import Foundation

/// What order the list of sheets comes in.
public enum SheetOrder {
	/// Most recently edited first.
	///
	/// The sheet wanted next is nearly always the one just put down, and a
	/// folder that has been used for a while sorts alphabetically into
	/// something nobody can find anything in.
	///
	/// The name breaks ties, so two sheets written in the same second do not
	/// swap places between one listing and the next. A file whose date cannot
	/// be read goes to the bottom rather than the top: an unreadable date is
	/// not evidence of recent work.
	public static func lastEditedFirst(_ urls: [URL]) -> [URL] {
		urls
			.map { url in
				let edited = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
					.contentModificationDate) ?? .distantPast
				return (url: url, edited: edited)
			}
			.sorted { one, other in
				if one.edited != other.edited { return one.edited > other.edited }
				return one.url.lastPathComponent
					.localizedStandardCompare(other.url.lastPathComponent) == .orderedAscending
			}
			.map(\.url)
	}
}
