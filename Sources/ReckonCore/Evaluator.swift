import Foundation

/// What the lines above the current one produced, which is what `prev`, `sum`,
/// `total`, `avg` and `line N` read from.
struct Context {
	var variables: [String: Quantity] = [:]
	/// One entry per line so far; nil where the line produced no value.
	var lineValues: [Quantity?] = []
	/// Which of those lines were amounts, rather than totals or definitions.
	var lineCountsTowardTotal: [Bool] = []
	/// Blank lines, the only thing that divides one tally from the next.
	var lineIsSeparator: [Bool] = []

	var previous: Quantity? {
		lineValues.last(where: { $0 != nil }) ?? nil
	}

	/// The figures immediately above, back to the last blank line. Several
	/// tallies can share one sheet, divided by blank lines.
	///
	/// A comment or a line of prose is stepped over rather than treated as a
	/// divider, so annotating a column does not cut the column in half.
	///
	/// Anything that is not one of the amounts does close the block: a running
	/// total, or a name being defined. Without that, a second `sum` further
	/// down would add the first one's total to its own inputs and quietly
	/// count them twice.
	var block: [Quantity] {
		var values: [Quantity] = []

		for offset in lineValues.indices.reversed() {
			if lineIsSeparator.indices.contains(offset) && lineIsSeparator[offset] { break }
			if lineCountsTowardTotal.indices.contains(offset),
			   !lineCountsTowardTotal[offset],
			   lineValues[offset] != nil { break }
			guard let value = lineValues[offset] else { continue }
			values.append(value)
		}

		return values.reversed()
	}
}

enum Functions {
	static let names: Set<String> = [
		"sqrt", "abs", "round", "floor", "ceil", "min", "max", "pow", "log", "ln"
	]

	/// Functions that keep whatever currency they were handed, as opposed to
	/// ones that only make sense on a plain number.
	static let currencyPreserving: Set<String> = ["abs", "round", "floor", "ceil", "min", "max"]
}

struct Evaluator {
	let context: Context

	func evaluate(_ expr: Expr) throws -> Quantity {
		switch expr {
		case .number(let value):
			return Quantity(value)

		case .money(let value, let code):
			return Quantity(value, code)

		case .variable(let name):
			guard let value = context.variables[name] else { throw EvaluationError.unknownName(name) }
			return value

		case .reference(let reference):
			return try evaluate(reference)

		case .percent(let inner):
			let value = try plain(evaluate(inner), "A percentage")
			return Quantity(value / 100)

		case .percentOf(let part, let whole):
			let fraction = try plain(evaluate(part), "A percentage") / 100
			let total = try evaluate(whole)
			return Quantity(total.amount * fraction, total.currency)

		case .unary(let symbol, let operand):
			let value = try evaluate(operand)
			return symbol == "-" ? Quantity(-value.amount, value.currency) : value

		case .binary(let symbol, let left, let right):
			return try evaluate(binary: symbol, left, right)

		case .call(let name, let arguments):
			return try evaluate(call: name, arguments)
		}
	}

	// MARK: - Currency rules

	/// Two amounts can be added when they agree on currency. A plain number
	/// takes on the currency of the other side, so `€40 + 2` is €42.
	private func unify(_ left: Quantity, _ right: Quantity) throws -> String? {
		switch (left.currency, right.currency) {
		case (nil, nil):            return nil
		case (let code?, nil):      return code
		case (nil, let code?):      return code
		case (let a?, let b?):
			guard a == b else { throw EvaluationError.mixedCurrency(a, b) }
			return a
		}
	}

	private func plain(_ value: Quantity, _ what: String) throws -> Decimal {
		guard value.currency != nil else { return value.amount }
		throw EvaluationError.currencyNotAllowed(what)
	}

	private func evaluate(binary symbol: String, _ left: Expr, _ right: Expr) throws -> Quantity {
		let leftValue = try evaluate(left)

		// `120 + 10%` means 10% *of 120*, which is what anyone writing a
		// receipt means. Same for minus. Elsewhere a percent is just a fraction.
		if case .percent(let inner) = right, symbol == "+" || symbol == "-" {
			let fraction = try plain(evaluate(inner), "A percentage") / 100
			let delta = leftValue.amount * fraction
			let amount = symbol == "+" ? leftValue.amount + delta : leftValue.amount - delta
			return Quantity(amount, leftValue.currency)
		}

		let rightValue = try evaluate(right)

		switch symbol {
		case "+":
			return Quantity(leftValue.amount + rightValue.amount, try unify(leftValue, rightValue))

		case "-":
			return Quantity(leftValue.amount - rightValue.amount, try unify(leftValue, rightValue))

		case "*":
			// Money times money has no meaning, but money times a count does.
			if let a = leftValue.currency, let b = rightValue.currency {
				throw EvaluationError.mixedCurrency(a, b)
			}
			return Quantity(leftValue.amount * rightValue.amount,
							leftValue.currency ?? rightValue.currency)

		case "/":
			guard rightValue.amount != 0 else { throw EvaluationError.divisionByZero }

			// Same currency divides out to a plain ratio.
			if let a = leftValue.currency, let b = rightValue.currency {
				guard a == b else { throw EvaluationError.mixedCurrency(a, b) }
				return Quantity(leftValue.amount / rightValue.amount)
			}
			if leftValue.isPlain, rightValue.currency != nil {
				throw EvaluationError.divisionByMoney
			}
			return Quantity(leftValue.amount / rightValue.amount, leftValue.currency)

		case "^":
			let base = try plain(leftValue, "A power")
			let exponent = try plain(rightValue, "A power")
			return Quantity(power(base, exponent))

		default:
			throw EvaluationError.notANumber
		}
	}

	private func evaluate(_ reference: Reference) throws -> Quantity {
		switch reference {
		case .previous:
			guard let value = context.previous else { throw EvaluationError.noPreviousValue }
			return value

		case .average:
			let block = context.block
			let sum = try total(of: block)
			return Quantity(sum.amount / Decimal(block.count), sum.currency)

		case .line(let number):
			let position = number - 1
			guard position >= 0, position < context.lineValues.count,
				  let value = context.lineValues[position] else {
				throw EvaluationError.noPreviousValue
			}
			return value
		}
	}

	private func total(of block: [Quantity]) throws -> Quantity {
		guard !block.isEmpty else { throw EvaluationError.noPreviousValue }

		var running = block[0]
		for value in block.dropFirst() {
			running = Quantity(running.amount + value.amount, try unify(running, value))
		}
		return running
	}

	// MARK: - Functions

	private func evaluate(call name: String, _ arguments: [Expr]) throws -> Quantity {
		let values = try arguments.map { try evaluate($0) }

		func requireOne() throws -> Quantity {
			guard values.count == 1 else { throw EvaluationError.badArgumentCount(name) }
			return values[0]
		}

		if Functions.currencyPreserving.contains(name) {
			switch name {
			case "abs":
				let value = try requireOne()
				return Quantity(Swift.abs(value.amount), value.currency)
			case "round", "floor", "ceil":
				let value = try requireOne()
				let mode: NSDecimalNumber.RoundingMode = name == "round" ? .plain : (name == "floor" ? .down : .up)
				return Quantity(value.amount.rounded(scale: 0, mode: mode), value.currency)
			default:  // min, max
				guard !values.isEmpty else { throw EvaluationError.badArgumentCount(name) }
				var currency: String? = values[0].currency
				for value in values.dropFirst() {
					currency = try unify(Quantity(0, currency), value)
				}
				let amounts = values.map(\.amount)
				return Quantity(name == "min" ? amounts.min()! : amounts.max()!, currency)
			}
		}

		switch name {
		case "sqrt":  return Quantity(Decimal(Foundation.sqrt(try plain(requireOne(), "sqrt").doubleValue)))
		case "ln":    return Quantity(Decimal(Foundation.log(try plain(requireOne(), "ln").doubleValue)))
		case "log":   return Quantity(Decimal(Foundation.log10(try plain(requireOne(), "log").doubleValue)))
		case "pow":
			guard values.count == 2 else { throw EvaluationError.badArgumentCount(name) }
			return Quantity(power(try plain(values[0], "pow"), try plain(values[1], "pow")))
		default:
			throw EvaluationError.unknownName(name)
		}
	}

	/// Stays in decimal for whole exponents, which is the common case and the
	/// one where binary floating point would show its seams.
	private func power(_ base: Decimal, _ exponent: Decimal) -> Decimal {
		if exponent.isWholeNumber, let whole = Int(exactly: exponent.doubleValue.rounded()) {
			if whole >= 0 {
				return pow(base, whole)
			}
			let positive = pow(base, -whole)
			return positive == 0 ? 0 : 1 / positive
		}

		return Decimal(Foundation.pow(base.doubleValue, exponent.doubleValue))
	}
}

extension Decimal {
	var doubleValue: Double { (self as NSDecimalNumber).doubleValue }
	var intValue: Int { (self as NSDecimalNumber).intValue }

	var isWholeNumber: Bool {
		var value = self
		var rounded = Decimal()
		NSDecimalRound(&rounded, &value, 0, .plain)
		return rounded == self
	}

	func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode) -> Decimal {
		var value = self
		var result = Decimal()
		NSDecimalRound(&result, &value, scale, mode)
		return result
	}
}
