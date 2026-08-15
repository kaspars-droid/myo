import Foundation

enum Token: Equatable {
	case number(Decimal)
	case word(String)
	case currency(String)   // a symbol such as € or $, already resolved to a code
	case op(String)
	case percent
	case leftParen
	case rightParen
	case comma
	case equals

	var isNumber: Bool {
		if case .number = self { return true }
		return false
	}
}

/// Turns a single line into tokens. Returns nil when the line contains
/// something the calculator has no meaning for, which is how prose gets told
/// apart from arithmetic.
struct Lexer {
	private let scalars: [Character]
	private var index = 0
	private let commaIsDecimal: Bool

	init(_ text: String, commaIsDecimal: Bool) {
		scalars = Array(text)
		self.commaIsDecimal = commaIsDecimal
	}

	/// Whether `527,4` means five hundred and twenty seven and four tenths.
	///
	/// It does wherever the reader writes numbers that way. The results column
	/// already prints `557,65` in those places, and a sheet that cannot read
	/// back the answer it just wrote is broken.
	///
	/// The cost is that a comma can no longer separate two arguments there, so
	/// `min(1;2)` takes a semicolon instead — the same trade every spreadsheet
	/// makes for the same reason.
	///
	/// A `Sheet` passes the locale it formats results with, so the two always
	/// agree; the default is only for callers that tokenize a line on its own.
	static func tokenize(_ text: String,
						 commaIsDecimal: Bool = Locale.current.decimalSeparator == ",") -> [Token]? {
		var lexer = Lexer(text, commaIsDecimal: commaIsDecimal)
		return lexer.run()
	}

	private mutating func run() -> [Token]? {
		var tokens: [Token] = []

		while index < scalars.count {
			let character = scalars[index]

			if character.isWhitespace {
				index += 1
				continue
			}

			if character.isNumber || (isDecimalPoint(character) && peekIsNumber(at: index + 1)) {
				guard let number = readNumber() else { return nil }
				tokens.append(.number(number))
				continue
			}

			// `14x100`, and `14 x 100`. It only becomes a sign once the line
			// has an amount for it to multiply and a number follows it, so a
			// sheet is still free to open with `x = 5`, and `5 x` is a five
			// with a letter after it.
			if character == "x" || character == "X",
			   endsAnAmount(tokens.last) || tokens.contains(where: \.isNumber),
			   digitFollows(index + 1) {
				tokens.append(.op("*"))
				index += 1
				continue
			}

			if character.isLetter || character == "_" {
				tokens.append(.word(readWord()))
				continue
			}

			if let code = Currency.code(forSymbol: character) {
				tokens.append(.currency(code))
				index += 1
				continue
			}

			index += 1

			switch character {
			case "+", "-", "*", "/", "^":
				tokens.append(.op(String(character)))
			case "\u{00D7}":  // ×
				tokens.append(.op("*"))
			case "\u{00F7}":  // ÷
				tokens.append(.op("/"))
			case "\u{2212}":  // − minus sign
				tokens.append(.op("-"))
			case "%":
				tokens.append(.percent)
			case "(":
				tokens.append(.leftParen)
			case ")":
				tokens.append(.rightParen)
			case ",", ";":
				// A comma this far has digits on only one side, so it is
				// punctuation between items rather than part of a number.
				tokens.append(.comma)
			case "=":
				tokens.append(.equals)
			case ".":
				// A full stop that is not a decimal point is prose: an
				// abbreviation, or the end of a sentence. Rejecting the whole
				// line over it left `38 pašizlīdzin. virtuvē` with no answer.
				tokens.append(.word("."))
			default:
				return nil  // not arithmetic, so the line is prose
			}
		}

		return tokens
	}

	private func isDecimalPoint(_ character: Character) -> Bool {
		character == "." || (commaIsDecimal && character == ",")
	}

	/// Whether a token could be the end of the left hand side of a sum. A word
	/// in between is allowed for by the caller, so `5 boxes x 3` reads the same
	/// as `5 boxes * 3` rather than quietly answering five.
	private func endsAnAmount(_ token: Token?) -> Bool {
		switch token {
		case .number, .rightParen, .percent, .currency:
			return true
		case .word(let word):
			return Currency.isCode(word)   // `14 eur x 3`
		default:
			return false
		}
	}

	/// The next thing along, once any spaces are out of the way, is a digit.
	private func digitFollows(_ start: Int) -> Bool {
		var position = start
		while position < scalars.count, scalars[position] == " " { position += 1 }
		return position < scalars.count && scalars[position].isNumber
	}

	private func peekIsNumber(at position: Int) -> Bool {
		position < scalars.count && scalars[position].isNumber
	}

	private mutating func readNumber() -> Decimal? {
		var text = ""
		var seenSeparator = false

		while index < scalars.count {
			let character = scalars[index]
			if character.isNumber {
				text.append(character)
				index += 1
			} else if isDecimalPoint(character) && !seenSeparator && peekIsNumber(at: index + 1) {
				seenSeparator = true
				text.append(".")
				index += 1
			} else {
				break
			}
		}

		return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
	}

	private mutating func readWord() -> String {
		var text = ""

		while index < scalars.count {
			let character = scalars[index]
			// A digit ends the word rather than joining it. `malt613,33` is a
			// note and an amount written without a space, and reading it as
			// one word left the `,33` to start a number of its own.
			guard character.isLetter || character == "_" else { break }
			text.append(character)
			index += 1
		}

		return text
	}
}
