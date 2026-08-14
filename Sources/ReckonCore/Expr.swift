import Foundation

/// A reference to something the sheet already worked out.
enum Reference: Equatable {
	case previous       // prev
	case sum            // sum / total of the block above
	case average        // avg / average of the block above
	case line(Int)      // line 3
}

indirect enum Expr: Equatable {
	case number(Decimal)
	case money(Decimal, String)     // 35 EUR
	case variable(String)
	case reference(Reference)
	case percent(Expr)              // 10%
	case percentOf(Expr, Expr)      // 10% of 200
	case unary(String, Expr)
	case binary(String, Expr, Expr)
	case call(String, [Expr])
}

extension Expr {
	/// True when the line is a total rather than another input to one, which
	/// is what lets a later total know where its own inputs begin.
	var isSubtotal: Bool {
		switch self {
		case .reference(.sum), .reference(.average):
			return true
		case .reference:
			return false
		case .number, .money, .variable:
			return false
		case .percent(let inner), .unary(_, let inner):
			return inner.isSubtotal
		case .percentOf(let a, let b), .binary(_, let a, let b):
			return a.isSubtotal || b.isSubtotal
		case .call(_, let arguments):
			return arguments.contains(where: \.isSubtotal)
		}
	}
}

enum EvaluationError: Error, Equatable {
	case unknownName(String)
	case divisionByZero
	case noPreviousValue
	case badArgumentCount(String)
	case notANumber
	case mixedCurrency(String, String)
	case currencyNotAllowed(String)
	case divisionByMoney

	var message: String {
		switch self {
		case .unknownName(let name):     return "I don't know what \(name) is"
		case .divisionByZero:            return "Division by zero"
		case .noPreviousValue:           return "Nothing above to refer to"
		case .badArgumentCount(let fn):  return "Wrong number of arguments for \(fn)"
		case .notANumber:                return "Not a number"
		case .mixedCurrency(let a, let b):
			return "Cannot mix \(a) and \(b) without an exchange rate"
		case .currencyNotAllowed(let operation):
			return "\(operation) does not work on money"
		case .divisionByMoney:
			return "Cannot divide a plain number by an amount of money"
		}
	}
}
