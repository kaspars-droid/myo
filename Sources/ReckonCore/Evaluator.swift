import Foundation

/// The names a sheet has defined so far. Nothing else about the lines above
/// is remembered, because nothing can refer to them.
struct Context {
	var variables: [String: Quantity] = [:]
	/// The amounts written since the last blank line, which is what `total`
	/// adds up. A definition or a total of its own ends the run, so a subtotal
	/// is never made from figures another subtotal has already claimed.
	var block: [Quantity] = []
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

		case .total:
			guard let first = context.block.first else { throw EvaluationError.emptyBlock }
			var sum = first
			for value in context.block.dropFirst() {
				sum = Quantity(sum.amount + value.amount, try unify(sum, value))
			}
			return sum

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
