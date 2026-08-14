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
}

/// Turns a single line into tokens. Returns nil when the line contains
/// something the calculator has no meaning for, which is how prose gets told
/// apart from arithmetic.
struct Lexer {
	private let scalars: [Character]
	private var index = 0

	init(_ text: String) {
		scalars = Array(text)
	}

	static func tokenize(_ text: String) -> [Token]? {
		var lexer = Lexer(text)
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

			if character.isNumber || (character == "." && peekIsNumber(at: index + 1)) {
				guard let number = readNumber() else { return nil }
				tokens.append(.number(number))
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
			case ",":
				tokens.append(.comma)
			case "=":
				tokens.append(.equals)
			default:
				return nil  // not arithmetic, so the line is prose
			}
		}

		return tokens
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
			} else if character == "." && !seenSeparator && peekIsNumber(at: index + 1) {
				seenSeparator = true
				text.append(character)
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
			guard character.isLetter || character == "_" || character.isNumber else { break }
			text.append(character)
			index += 1
		}

		return text
	}
}
