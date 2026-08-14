import Foundation

/// A number that may carry a currency. Plain arithmetic keeps `currency` nil.
public struct Quantity: Equatable, Sendable {
	public var amount: Decimal
	public var currency: String?

	public init(_ amount: Decimal, _ currency: String? = nil) {
		self.amount = amount
		self.currency = currency
	}

	public var isPlain: Bool { currency == nil }
}

public enum Currency {
	/// Symbols that can stand in front of or behind an amount.
	static let symbolToCode: [Character: String] = [
		"€": "EUR", "$": "USD", "£": "GBP", "¥": "JPY", "₹": "INR",
		"₽": "RUB", "₴": "UAH", "₺": "TRY", "₩": "KRW", "₪": "ILS",
		"₫": "VND", "₦": "NGN", "₱": "PHP", "₸": "KZT", "฿": "THB"
	]

	/// ISO codes accepted as a word next to an amount, as in `35 eur`.
	static let codes: Set<String> = [
		"EUR", "USD", "GBP", "JPY", "CHF", "CAD", "AUD", "NZD",
		"SEK", "NOK", "DKK", "ISK", "PLN", "CZK", "HUF", "RON",
		"BGN", "HRK", "RSD", "RUB", "UAH", "TRY", "GEL", "MDL",
		"CNY", "INR", "BRL", "MXN", "ZAR", "KRW", "SGD", "HKD",
		"ILS", "AED", "SAR", "THB", "PHP", "IDR", "MYR", "VND",
		"KZT", "NGN", "EGP", "CLP", "ARS", "COP", "PEN"
	]

	static func code(forSymbol character: Character) -> String? {
		symbolToCode[character]
	}

	/// True when a bare word next to a number names a currency.
	static func isCode(_ word: String) -> Bool {
		codes.contains(word.uppercased())
	}

	static func normalize(_ word: String) -> String {
		word.uppercased()
	}

	static func symbol(for code: String) -> String? {
		symbolToCode.first { $0.value == code }.map { String($0.key) }
	}
}
