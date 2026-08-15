import Foundation

/// A reference to something the sheet already worked out.
indirect enum Expr: Equatable {
	case number(Decimal)
	case money(Decimal, String)     // 35 EUR
	case variable(String)
	case percent(Expr)              // 10%
	case percentOf(Expr, Expr)      // 10% of 200
	case unary(String, Expr)
	case binary(String, Expr, Expr)
	case call(String, [Expr])
}

enum EvaluationError: Error, Equatable {
	case unknownName(String)
	case divisionByZero
	case badArgumentCount(String)
	case notANumber
	case mixedCurrency(String, String)
	case currencyNotAllowed(String)
	case divisionByMoney

	var message: String {
		switch self {
		case .unknownName(let name):     return "I don't know what \(name) is"
		case .divisionByZero:            return "Division by zero"
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
