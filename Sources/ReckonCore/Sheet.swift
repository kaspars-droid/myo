import Foundation

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
	/// A total, which is excluded from other totals so nothing counts twice.
	public let isSubtotal: Bool

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
			guard let value = line.value, !line.isSubtotal else { continue }
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
					isSubtotal: Bool = false) -> Line {
			context.lineValues.append(value)
			context.lineIsSubtotal.append(isSubtotal)
			context.lineIsSeparator.append(kind == .blank)
			return Line(number: number,
						text: text,
						code: code,
						comment: comment,
						kind: kind,
						value: value,
						formatted: value.map { format($0) },
						error: error,
						isSubtotal: isSubtotal)
		}

		if trimmed.isEmpty {
			return record(comment == nil ? .blank : .comment, value: nil)
		}

		// Read numbers the way this sheet writes them, so an answer in the
		// results column can be typed straight back into a line.
		guard let tokens = Lexer.tokenize(trimmed, commaIsDecimal: locale.decimalSeparator == ","),
			  !tokens.isEmpty else {
			return record(.prose, value: nil)
		}

		guard let parsed = Parser.parseLine(tokens: tokens,
											knownVariables: Set(context.variables.keys)) else {
			return record(.prose, value: nil)
		}

		do {
			let value = try Evaluator(context: context).evaluate(parsed.expr)

			if let name = parsed.name {
				context.variables[name] = value
				return record(.assignment(name), value: value, isSubtotal: parsed.expr.isSubtotal)
			}

			return record(.result, value: value, isSubtotal: parsed.expr.isSubtotal)
		} catch let error as EvaluationError {
			return record(.prose, value: nil, error: error.message)
		} catch {
			return record(.prose, value: nil, error: "\(error)")
		}
	}

	public func format(_ value: Quantity) -> String {
		let formatter = NumberFormatter()
		formatter.locale = locale
		formatter.numberStyle = .decimal
		formatter.usesGroupingSeparator = true
		formatter.maximumFractionDigits = 10
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
