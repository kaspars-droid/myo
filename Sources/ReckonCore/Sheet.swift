import Foundation

/// Where a name sits in a line, so the editor can colour it.
public struct NameSpan: Equatable, Sendable {
	public enum Role: Equatable, Sendable {
		case defined    // the left of an `=`
		case used       // read further along
	}

	/// UTF-16 offsets, which is what a text view measures in.
	public let range: NSRange
	public let role: Role
	public let name: String

	public init(range: NSRange, role: Role, name: String) {
		self.range = range
		self.role = role
		self.name = name
	}
}

/// One line of a sheet after evaluation.
public struct Line: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		case blank
		case comment            // nothing but a comment
		case prose              // words the calculator has no opinion about
		case assignment(String) // `rate = 0.21`
		case result             // a bare expression
	}

	public let number: Int      // 1 based, matches `line N`
	public let text: String     // the line exactly as typed
	/// The part of the line the math sees, everything before the `#`.
	public let code: String
	/// The `#` and everything after it, if the line has one.
	public let comment: String?
	public let kind: Kind
	public let value: Quantity?
	public let formatted: String?
	public let error: String?
	/// Whether this line is one of the amounts, as opposed to a total of them
	/// or the definition of a name. Only the amounts are added up.
	public let countsTowardTotal: Bool
	/// Where the variable names sit in `text`.
	public let names: [NameSpan]

	public var hasValue: Bool { value != nil }
}

/// A sheet is plain text: one expression per line, prose wherever you like.
/// Evaluation runs top to bottom so a line can use anything defined above it.
public struct Sheet: Sendable {
	public var locale: Locale

	public init(locale: Locale = Locale(identifier: "en_US_POSIX")) {
		self.locale = locale
	}

	public func evaluate(_ source: String) -> [Line] {
		var context = Context()
		var lines: [Line] = []

		for (offset, rawLine) in source.components(separatedBy: .newlines).enumerated() {
			lines.append(evaluate(rawLine, number: offset + 1, context: &context))
		}

		return lines
	}

	/// Convenience for a single expression, mostly for tests and for the
	/// LaunchBar style "one shot" case.
	public func evaluateOne(_ text: String) -> Line {
		var context = Context()
		return evaluate(text, number: 1, context: &context)
	}

	/// Everything in the result column added up, which is what the bar along
	/// the bottom of the app shows.
	///
	/// Totals already written into the sheet are skipped, because adding a
	/// subtotal to the figures it was made from would count them twice. Each
	/// currency gets its own total, since there are no exchange rates.
	public func grandTotal(of lines: [Line]) -> [Quantity] {
		var order: [String?] = []
		var sums: [String?: Decimal] = [:]

		for line in lines {
			guard let value = line.value, line.countsTowardTotal else { continue }
			if sums[value.currency] == nil {
				sums[value.currency] = 0
				order.append(value.currency)
			}
			sums[value.currency]? += value.amount
		}

		return order.map { Quantity(sums[$0] ?? 0, $0) }
	}

	/// Splits a line into the part that is arithmetic and the part that is a
	/// note. `#` wins wherever it appears, so a comment can sit at the end of
	/// a working line.
	public static func split(_ text: String) -> (code: String, comment: String?) {
		var candidates: [String.Index] = []

		if let hash = text.firstIndex(of: "#") {
			candidates.append(hash)
		}
		if let slashes = text.range(of: "//") {
			candidates.append(slashes.lowerBound)
		}

		guard let start = candidates.min() else { return (text, nil) }
		return (String(text[..<start]), String(text[start...]))
	}

	private func evaluate(_ text: String, number: Int, context: inout Context) -> Line {
		let (code, comment) = Sheet.split(text)
		let trimmed = code.trimmingCharacters(in: .whitespaces)

		func record(_ kind: Line.Kind, value: Quantity?, error: String? = nil,
					countsTowardTotal: Bool = false, names: [NameSpan] = []) -> Line {
			return Line(number: number,
						text: text,
						code: code,
						comment: comment,
						kind: kind,
						value: value,
						formatted: value.map { format($0) },
						error: error,
						countsTowardTotal: countsTowardTotal,
						names: names)
		}

		if trimmed.isEmpty {
			// A blank line is where one group of amounts ends and the next
			// begins. A line that is nothing but a note does not break the
			// run: a sheet is annotated as it is written.
			if comment == nil { context.block = [] }
			return record(comment == nil ? .blank : .comment, value: nil)
		}

		// Read numbers the way this sheet writes them, so an answer in the
		// results column can be typed straight back into a line.
		guard let tokens = Lexer.tokenize(trimmed, commaIsDecimal: locale.decimalSeparator == ","),
			  !tokens.isEmpty else {
			return record(.prose, value: nil)
		}

		guard let parsed = Parser.parseLine(tokens: tokens,
											knownVariables: Set(context.variables.keys),
											blockIsOpen: !context.block.isEmpty) else {
			return record(.prose, value: nil)
		}

		let names = Sheet.names(in: code, defined: parsed.name, used: parsed.expr.mentionedNames)

		do {
			let value = try Evaluator(context: context).evaluate(parsed.expr)

			// A definition is not an expense. `rate = 0.21` showing up in the
			// bar along the bottom made the total of any sheet using names
			// meaningless, which is the whole point of the bar.
			if let name = parsed.name {
				context.variables[name] = value
				context.block = []      // naming a figure closes the group above
				return record(.assignment(name), value: value, countsTowardTotal: false,
							  names: names)
			}

			// A subtotal must not go into the bar along the bottom as well as
			// the figures it was made from, and it closes the group it just
			// added up so the next `total` starts fresh.
			if parsed.expr.mentionsTotal {
				context.block = []
				return record(.result, value: value, countsTowardTotal: false, names: names)
			}

			context.block.append(value)
			return record(.result, value: value, countsTowardTotal: true, names: names)
		} catch let error as EvaluationError {
			return record(.prose, value: nil, error: error.message, names: names)
		} catch {
			return record(.prose, value: nil, error: "\(error)", names: names)
		}
	}

	/// How a figure is shown. Two decimals, because `613,33-25%` is 459,9975
	/// and nobody wants to read that down a column.
	///
	/// This is the display only. The arithmetic keeps every digit, so a total
	/// adds the exact figures and is rounded once, at the end, rather than
	/// adding up a column of already rounded ones.
	public func format(_ value: Quantity) -> String {
		let formatter = NumberFormatter()
		formatter.locale = locale
		formatter.numberStyle = .decimal
		formatter.usesGroupingSeparator = true
		formatter.roundingMode = .halfUp
		formatter.maximumFractionDigits = 2
		formatter.minimumFractionDigits = 0

		guard let code = value.currency else {
			return formatter.string(from: value.amount as NSDecimalNumber) ?? "\(value.amount)"
		}

		// A round amount is written round: €35, not €35.00. Cents appear only
		// when there are cents. The sign stays in front of the symbol so that
		// a negative total reads as -€5 rather than €-5.
		formatter.minimumFractionDigits = value.amount.isWholeNumber ? 0 : 2
		formatter.maximumFractionDigits = 2

		let magnitude = abs(value.amount)
		let digits = formatter.string(from: magnitude as NSDecimalNumber) ?? "\(magnitude)"
		let sign = value.amount < 0 ? "-" : ""

		if let symbol = Currency.symbol(for: code) {
			return "\(sign)\(symbol)\(digits)"
		}
		return "\(sign)\(digits) \(code)"
	}
}

// MARK: - Where the names are written

extension Sheet {
	/// Where every name in a sheet is written, measured against the whole
	/// text, which is what an editor colours.
	///
	/// This runs the sheet a second time rather than reading positions off the
	/// first, because the editor recolours on the keystroke, before the view
	/// that evaluated has been handed the new text. A sheet is a screenful of
	/// arithmetic; running it twice costs nothing and keeps the colour from
	/// ever lagging a character behind the caret.
	public func names(in source: String) -> [NameSpan] {
		var context = Context()
		var spans: [NameSpan] = []
		var start = 0

		for (offset, rawLine) in source.components(separatedBy: .newlines).enumerated() {
			let line = evaluate(rawLine, number: offset + 1, context: &context)

			for span in line.names {
				spans.append(NameSpan(range: NSRange(location: start + span.range.location,
													 length: span.range.length),
									  role: span.role,
									  name: span.name))
			}

			start += (rawLine as NSString).length + 1   // past the newline
		}

		return spans
	}

	/// Finds the names in one line by looking for them in what was typed.
	///
	/// The parser knows which names a line reads but not where they sit, and
	/// threading a position through every branch of it to find out would cost
	/// more than it is worth. A name is a run of letters, so looking it up
	/// again in the line is exact as long as only whole words count — which is
	/// also what keeps `tame` out of the middle of `tame_kludaina`.
	static func names(in code: String, defined: String?, used: [String]) -> [NameSpan] {
		let text = code as NSString
		var spans: [NameSpan] = []

		if let defined {
			// The name being defined is the part in front of the `=`.
			let equals = text.range(of: "=").location
			let left = NSRange(location: 0, length: equals == NSNotFound ? text.length : equals)

			if let range = occurrences(of: defined, in: text, within: left).first {
				spans.append(NameSpan(range: range, role: .defined, name: defined))
			}
		}

		// Longest first, so `car repair` claims its words before `car` can.
		for name in Set(used).sorted(by: { $0.count > $1.count }) {
			for range in occurrences(of: name, in: text,
									 within: NSRange(location: 0, length: text.length)) {
				guard !spans.contains(where: { NSIntersectionRange($0.range, range).length > 0 })
				else { continue }
				spans.append(NameSpan(range: range, role: .used, name: name))
			}
		}

		return spans.sorted { $0.range.location < $1.range.location }
	}

	private static func occurrences(of name: String, in text: NSString,
									within bounds: NSRange) -> [NSRange] {
		guard !name.isEmpty else { return [] }

		var found: [NSRange] = []
		var start = bounds.location
		let end = bounds.location + bounds.length

		while start < end {
			let range = text.range(of: name, options: .literal,
								   range: NSRange(location: start, length: end - start))
			guard range.location != NSNotFound else { break }

			if isWholeWord(range, in: text) { found.append(range) }
			start = range.location + max(range.length, 1)
		}

		return found
	}

	/// A match with a letter, digit or underscore against either end is part
	/// of a longer word, not the name.
	private static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
		if range.location > 0, isNameCharacter(text.character(at: range.location - 1)) {
			return false
		}

		let after = range.location + range.length
		return after >= text.length || !isNameCharacter(text.character(at: after))
	}

	private static func isNameCharacter(_ unit: unichar) -> Bool {
		guard let scalar = Unicode.Scalar(unit) else { return false }
		let character = Character(scalar)
		return character.isLetter || character.isNumber || character == "_"
	}
}
