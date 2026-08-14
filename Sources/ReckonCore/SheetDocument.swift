import Foundation

/// The editable text of a sheet, as a list of lines.
///
/// Editing is the text view's job, so this holds no caret rules. What it does
/// hold is the one thing a text view knows nothing about:
///
/// Numi writes its answers into the file, joined to the line with a `=` padded
/// by non-breaking spaces. Those answers are held to one side: they are not
/// part of the line being edited, they belong in the result column, and they
/// are written back untouched so that opening a sheet here does not rewrite it.
public struct SheetDocument: Equatable, Sendable {
	/// `\u{00A0}=\u{00A0}`, which is what Numi puts between a line and its
	/// answer. An ordinary `=` typed by hand is a variable, not an answer, so
	/// the padding is what tells them apart.
	public static let answerMarker = "\u{00A0}=\u{00A0}"

	/// The lines as typed, without any answer Numi appended.
	public private(set) var lines: [String]
	/// The answer Numi left on each line, kept verbatim.
	public private(set) var storedAnswers: [String?]

	public init(text: String = "") {
		let parts = text.components(separatedBy: .newlines)
		let rows = (parts.isEmpty ? [""] : parts).map(SheetDocument.split)

		lines = rows.map(\.line)
		storedAnswers = rows.map(\.answer)
	}

	static func split(_ text: String) -> (line: String, answer: String?) {
		guard let marker = text.range(of: answerMarker) else { return (text, nil) }
		return (String(text[..<marker.lowerBound]), String(text[marker.upperBound...]))
	}

	/// What the calculator reads and the editor shows.
	public var text: String { lines.joined(separator: "\n") }

	/// What goes back to disk, answers and all.
	public var fileContents: String {
		zip(lines, storedAnswers)
			.map { line, answer in
				answer.map { line + SheetDocument.answerMarker + $0 } ?? line
			}
			.joined(separator: "\n")
	}

	public var indices: Range<Int> { lines.indices }

	/// What to call this sheet in a list: the first line that says anything,
	/// with any comment marker taken off the front. A sheet titled
	/// `# Q1 invoices` is called "Q1 invoices".
	public var name: String {
		for line in lines {
			var text = line.trimmingCharacters(in: .whitespaces)

			if text.hasPrefix("//") { text.removeFirst(2) }
			while text.hasPrefix("#") { text.removeFirst() }

			text = text.trimmingCharacters(in: .whitespaces)
			if !text.isEmpty { return String(text.prefix(40)) }
		}

		return "Untitled"
	}

	public subscript(index: Int) -> String {
		lines.indices.contains(index) ? lines[index] : ""
	}

	/// Replaces the whole text, which is what a text view hands back.
	///
	/// The answers Numi left are re-attached to whatever lines still read the
	/// same. Without that, typing one character would strip the answers off
	/// every other line in the file and rewrite the lot.
	public mutating func setText(_ newText: String) {
		var spare: [String: [String]] = [:]
		for (line, answer) in zip(lines, storedAnswers) {
			guard let answer else { continue }
			spare[line, default: []].append(answer)
		}

		let parts = newText.components(separatedBy: .newlines)
		let rows = (parts.isEmpty ? [""] : parts).map(SheetDocument.split)

		lines = rows.map(\.line)
		storedAnswers = rows.map { row in
			// An answer already on the line wins; otherwise take back the one
			// this line had before, if the line is unchanged.
			if let answer = row.answer { return answer }
			guard var queue = spare[row.line], !queue.isEmpty else { return nil }
			let answer = queue.removeFirst()
			spare[row.line] = queue
			return answer
		}
	}
}
