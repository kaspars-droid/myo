import Foundation

/// Recursive descent over one line's tokens.
///
/// Every failure mode returns nil rather than throwing: a line that does not
/// parse is not an error, it is prose, and a sheet is mostly prose.
struct Parser {
	private let tokens: [Token]
	private var index = 0
	private let knownVariables: Set<String>

	init(tokens: [Token], knownVariables: Set<String>) {
		self.tokens = tokens
		self.knownVariables = knownVariables
	}

	/// Parses a whole line, which is either `name = expression` or just an
	/// expression. Returns the assigned name, if any, alongside the tree.
	static func parseLine(tokens: [Token], knownVariables: Set<String>) -> (name: String?, expr: Expr)? {
		// `rate = 0.21`
		if let split = tokens.firstIndex(of: .equals),
		   let name = variableName(from: Array(tokens[..<split])) {
			let right = Array(tokens[(split + 1)...])
			var parser = Parser(tokens: right, knownVariables: knownVariables)

			if !right.isEmpty, let expr = parser.parseExpression(), parser.isAtEnd {
				return (name, expr)
			}
		}

		// Otherwise the line is an amount, possibly with something written
		// beside it: `35eur oil change`.
		var parser = Parser(tokens: tokens, knownVariables: knownVariables)
		if let expr = parser.parseExpression(), parser.trailingIsALabel {
			return (nil, expr)
		}

		// The label can come first instead: `oil change 35eur`. Only whole
		// words are stepped over, so a line that opens with something the
		// calculator half understands is left alone rather than salvaged.
		let leadingWords = tokens.prefix { if case .word = $0 { return true } else { return false } }
		guard !leadingWords.isEmpty, leadingWords.count < tokens.count else { return nil }

		var afterLabel = Parser(tokens: Array(tokens[leadingWords.count...]),
								knownVariables: knownVariables)
		guard let expr = afterLabel.parseExpression(), afterLabel.trailingIsALabel else { return nil }
		return (nil, expr)
	}

	/// What is left over once the arithmetic has been read.
	///
	/// Plain words are a label for the figure, so `35eur oil change` is still
	/// €35. Anything with more arithmetic in it is not a label, and the line
	/// goes back to being prose rather than quietly dropping half of itself.
	///
	/// A trailing `= …` is ignored: that is a result Numi wrote into the file,
	/// and this line already has one of its own.
	private var trailingIsALabel: Bool {
		guard index < tokens.count else { return true }

		let rest = tokens[index...]
		let label = rest.prefix { $0 != .equals }

		return label.allSatisfy { token in
			if case .word = token { return true }
			return false
		}
	}

	/// A variable name is one or more plain words: `rate`, `car repair`.
	private static func variableName(from tokens: [Token]) -> String? {
		guard !tokens.isEmpty else { return nil }

		var words: [String] = []
		for token in tokens {
			guard case .word(let word) = token else { return nil }
			words.append(word)
		}

		let name = words.joined(separator: " ")
		return Reserved.all.contains(name.lowercased()) ? nil : name
	}

	private var isAtEnd: Bool { index >= tokens.count }

	private func peek() -> Token? { index < tokens.count ? tokens[index] : nil }

	private mutating func advance() -> Token? {
		guard index < tokens.count else { return nil }
		defer { index += 1 }
		return tokens[index]
	}

	private mutating func match(op symbols: Set<String>) -> String? {
		guard case .op(let symbol)? = peek(), symbols.contains(symbol) else { return nil }
		index += 1
		return symbol
	}

	// expression := term (('+' | '-') term)*
	mutating func parseExpression() -> Expr? {
		guard var left = parseTerm() else { return nil }

		while let symbol = match(op: ["+", "-"]) {
			guard let right = parseTerm() else { return nil }
			left = .binary(symbol, left, right)
		}

		return left
	}

	// term := power (('*' | '/') power)*
	private mutating func parseTerm() -> Expr? {
		guard var left = parsePower() else { return nil }

		while let symbol = match(op: ["*", "/"]) {
			guard let right = parsePower() else { return nil }
			left = .binary(symbol, left, right)
		}

		return left
	}

	// power := unary ('^' power)?      right associative
	private mutating func parsePower() -> Expr? {
		guard let base = parseUnary() else { return nil }

		if match(op: ["^"]) != nil {
			guard let exponent = parsePower() else { return nil }
			return .binary("^", base, exponent)
		}

		return base
	}

	// unary := ('-' | '+')? postfix
	private mutating func parseUnary() -> Expr? {
		if let symbol = match(op: ["-", "+"]) {
			guard let operand = parseUnary() else { return nil }
			return symbol == "-" ? .unary("-", operand) : operand
		}

		return parsePostfix()
	}

	// postfix := primary '%'? ('of' expression)?
	private mutating func parsePostfix() -> Expr? {
		guard let value = parsePrimary() else { return nil }

		guard case .percent? = peek() else { return value }
		index += 1

		// `10% of 200`
		if case .word(let word)? = peek(), word.lowercased() == "of" {
			index += 1
			guard let whole = parseTerm() else { return nil }
			return .percentOf(value, whole)
		}

		return .percent(value)
	}

	private mutating func parsePrimary() -> Expr? {
		switch advance() {
		case .number(let value):
			// `35 EUR`, `35eur`, `35€`
			if case .currency(let code)? = peek() {
				index += 1
				return .money(value, code)
			}
			if case .word(let word)? = peek(), Currency.isCode(word) {
				index += 1
				return .money(value, Currency.normalize(word))
			}
			return .number(value)

		case .currency(let code):
			// `€35`, and `€ 35` since whitespace is not a token
			guard case .number(let value)? = peek() else { return nil }
			index += 1
			return .money(value, code)

		case .leftParen:
			guard let inner = parseExpression(), case .rightParen? = peek() else { return nil }
			index += 1
			return inner

		case .word(let word):
			return parseWord(word)

		default:
			return nil
		}
	}

	private mutating func parseWord(_ word: String) -> Expr? {
		let lowercased = word.lowercased()

		// function call
		if case .leftParen? = peek(), Functions.names.contains(lowercased) {
			index += 1
			var arguments: [Expr] = []

			if case .rightParen? = peek() {
				index += 1
				return .call(lowercased, arguments)
			}

			while true {
				guard let argument = parseExpression() else { return nil }
				arguments.append(argument)

				if case .comma? = peek() {
					index += 1
					continue
				}
				break
			}

			guard case .rightParen? = peek() else { return nil }
			index += 1
			return .call(lowercased, arguments)
		}

		switch lowercased {
		case "prev", "previous", "ans":
			return .reference(.previous)
		case "sum", "total":
			return .reference(.sum)
		case "avg", "average", "mean":
			return .reference(.average)
		case "line":
			// `line 3`
			if case .number(let number)? = peek() {
				index += 1
				return .reference(.line(number.intValue))
			}
			return nil
		default:
			break
		}

		// Longest run of words that names a variable, so `car repair * 2` works.
		var candidate = word
		var length = 1
		var best: String? = knownVariables.contains(candidate) ? candidate : nil
		var bestLength = 1

		while case .word(let next)? = tokenAt(index + length - 1) {
			candidate += " " + next
			length += 1
			if knownVariables.contains(candidate) {
				best = candidate
				bestLength = length
			}
		}

		if let name = best {
			index += bestLength - 1
			return .variable(name)
		}

		return nil  // an unknown bare word means this line is prose
	}

	private func tokenAt(_ position: Int) -> Token? {
		position < tokens.count ? tokens[position] : nil
	}
}

enum Reserved {
	static let all: Set<String> = [
		"prev", "previous", "ans", "sum", "total", "avg", "average", "mean", "line", "of"
	]
}
