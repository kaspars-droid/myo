import XCTest
@testable import ReckonCore

final class ArithmeticTests: XCTestCase {
	private let sheet = Sheet()

	private func value(_ text: String) -> String? {
		sheet.evaluateOne(text).formatted
	}

	func testArithmeticAndPrecedence() {
		XCTAssertEqual(value("2+2"), "4")
		XCTAssertEqual(value("2 + 3 * 4"), "14")
		XCTAssertEqual(value("(2 + 3) * 4"), "20")
		XCTAssertEqual(value("10 / 4"), "2.5")
		XCTAssertEqual(value("-5 + 8"), "3")
		XCTAssertEqual(value("2 ^ 10"), "1,024")
		XCTAssertEqual(value("2 ^ 3 ^ 2"), "512")     // right associative
		XCTAssertEqual(value("10 × 3"), "30")          // typographic operators
		XCTAssertEqual(value("10 ÷ 4"), "2.5")
	}

	/// The reason to use decimal rather than binary floating point: money.
	func testDecimalArithmeticIsExact() {
		XCTAssertEqual(value("0.1 + 0.2"), "0.3")
		XCTAssertEqual(value("1.1 * 3"), "3.3")
		XCTAssertEqual(value("4.35 * 100"), "435")
	}

	func testPercentages() {
		XCTAssertEqual(value("10%"), "0.1")
		XCTAssertEqual(value("20% of 300"), "60")
		XCTAssertEqual(value("120 + 10%"), "132")      // percent of the left side
		XCTAssertEqual(value("120 - 10%"), "108")
		XCTAssertEqual(value("200 * 50%"), "100")
	}

	func testFunctions() {
		XCTAssertEqual(value("sqrt(16)"), "4")
		XCTAssertEqual(value("abs(-7)"), "7")
		XCTAssertEqual(value("round(2.6)"), "3")
		XCTAssertEqual(value("floor(2.9)"), "2")
		XCTAssertEqual(value("ceil(2.1)"), "3")
		XCTAssertEqual(value("min(3, 1, 2)"), "1")
		XCTAssertEqual(value("max(3, 1, 2)"), "3")
		XCTAssertEqual(value("pow(2, 8)"), "256")
	}

	func testLargeNumbersAreGrouped() {
		XCTAssertEqual(value("1234567 + 1"), "1,234,568")
	}

	func testDivisionByZeroIsReported() {
		let line = sheet.evaluateOne("5 / 0")
		XCTAssertNil(line.value)
		XCTAssertEqual(line.error, "Division by zero")
	}
}

final class SheetTests: XCTestCase {
	private let sheet = Sheet()

	func testProseIsLeftAlone() {
		let lines = sheet.evaluate("""
		shopping for the trip
		12 + 8
		// a comment
		# also a comment
		""")

		XCTAssertEqual(lines[0].kind, .prose)
		XCTAssertNil(lines[0].value)
		XCTAssertEqual(lines[1].formatted, "20")
		XCTAssertEqual(lines[2].kind, .comment)
		XCTAssertEqual(lines[3].kind, .comment)
	}

	func testVariables() {
		let lines = sheet.evaluate("""
		rate = 0.21
		net = 1000
		net * rate
		""")

		XCTAssertEqual(lines[0].kind, .assignment("rate"))
		XCTAssertEqual(lines[2].formatted, "210")
	}

	func testMultiWordVariables() {
		let lines = sheet.evaluate("""
		car repair = 350
		car repair * 2
		""")

		XCTAssertEqual(lines[0].kind, .assignment("car repair"))
		XCTAssertEqual(lines[1].formatted, "700")
	}


	/// Nothing refers to another line any more. The bar along the bottom adds
	/// the column up, and that was the only one of these worth the rule that
	/// came with it. They are ordinary words now, free to be used as names.
	func testTheOldReferenceWordsAreOrdinaryWords() {
		for word in ["sum", "total", "prev", "avg", "average", "mean"] {
			XCTAssertEqual(sheet.evaluateOne(word).kind, .prose, word)
		}

		let lines = sheet.evaluate("""
		sum = 500
		avg = 12
		sum / 2 + avg
		""")

		XCTAssertEqual(lines[0].kind, .assignment("sum"))
		XCTAssertEqual(lines[2].formatted, "262")
	}





	func testUnknownWordsMakeTheLineProse() {
		let line = sheet.evaluateOne("bananas * 3")
		XCTAssertEqual(line.kind, .prose)
		XCTAssertNil(line.value)
	}

	func testLineNumbersAreStable() {
		let lines = sheet.evaluate("a = 1\n\nb = 2")
		XCTAssertEqual(lines.map(\.number), [1, 2, 3])
		XCTAssertEqual(lines[1].kind, .blank)
	}

	/// Sheets are plain text, which is what makes them portable between the
	/// Mac app, the phone, and anything else that can open a text file.
	func testRoundTripsThroughPlainText() {
		let source = "budget = 1200\nrent = 800\nbudget - rent"
		let lines = sheet.evaluate(source)

		XCTAssertEqual(lines.map(\.text).joined(separator: "\n"), source)
		XCTAssertEqual(lines[2].formatted, "400")
	}

	func testLocaleAffectsFormattingOnly() {
		let latvian = Sheet(locale: Locale(identifier: "lv_LV"))
		let line = latvian.evaluateOne("1234.5 + 1")
		XCTAssertEqual(line.value?.amount, Decimal(string: "1235.5"))
		XCTAssertNotNil(line.formatted)
	}
}

/// A handwritten expense sheet is mostly amounts with a description beside
/// them, and the descriptions are messy. These are the shapes that a real
/// folder of sheets turned out to be full of.
final class DescribedAmountTests: XCTestCase {
	private let sheet = Sheet()
	private let latvian = Sheet(locale: Locale(identifier: "lv_LV"))

	func testCommasSlashesAndSizesBelongToTheDescription() {
		let lines = sheet.evaluate("""
		200 plaster, buckets, cable
		35 fuses/box
		7 mortar 10kg
		46 white paint 10l, roller, sheeting
		""")

		XCTAssertEqual(lines.map(\.formatted), ["200", "35", "7", "46"])
	}

	func testAFullStopInAWordDoesNotThrowTheLineAway() {
		// `38 self-lev. kitchen`: an abbreviation used to take the whole line
		// down with it, because a stray full stop stopped the lexer.
		let lines = sheet.evaluate("38 self lev. kitchen")

		XCTAssertEqual(lines[0].formatted, "38")
	}

	func testAWordBetweenTwoAmountsDoesNotEndTheSum() {
		let lines = sheet.evaluate("""
		302 boards+6 trailer
		5 boxes * 3
		100 rent - 50 refund
		""")

		XCTAssertEqual(lines.map(\.formatted), ["308", "15", "50"])
	}

	func testASlashBetweenWordsIsStillNotDivision() {
		// The rewind: `/` is found by looking past words, then the right hand
		// side turns out to be a word too, so the line keeps its description.
		let lines = sheet.evaluate("""
		35 fuses/box
		66 brake/clutch fluid change
		""")

		XCTAssertEqual(lines.map(\.formatted), ["35", "66"])
	}

	func testAnAmountFollowedByPunctuationStillCounts() {
		let lines = sheet.evaluate("18, lime, corners")

		XCTAssertEqual(lines[0].formatted, "18")
	}

	func testArithmeticHidingBehindADescriptionIsNotSwallowed() {
		// Nothing here parses as a sum, and answering with the first number
		// would drop the rest of the line without saying so.
		let lines = sheet.evaluate("10 boxes, 3 bags")

		XCTAssertEqual(lines[0].formatted, "10")
		XCTAssertEqual(lines[0].text, "10 boxes, 3 bags")
	}

	func testDecimalCommaWhereThatIsHowNumbersAreWritten() {
		let lines = latvian.evaluate("527,4+30,25 osb, plywood, isover")

		XCTAssertEqual(lines[0].formatted, "557,65")
	}

	func testTheAnswerCanBeTypedBackIn() {
		// The results column prints `557,65`, so a line must be able to read
		// it. This is the whole reason the decimal comma is locale bound.
		let printed = latvian.evaluate("527,4 + 30,25")[0].formatted
		let again = latvian.evaluate("\(printed ?? "") + 0")[0].formatted

		XCTAssertEqual(again, printed)
	}

	func testACommaIsStillAnArgumentSeparatorWhereItIsNotADecimal() {
		XCTAssertEqual(sheet.evaluate("min(1, 2)")[0].formatted, "1")
	}

	func testSemicolonSeparatesArgumentsWhereACommaCannot() {
		XCTAssertEqual(latvian.evaluate("min(1; 2)")[0].formatted, "1")
		XCTAssertEqual(sheet.evaluate("min(1; 2)")[0].formatted, "1")
	}

	/// `malt613,33` is a note and an amount run together. Reading it as one
	/// word left the `,33` to start a number of its own, and the line came
	/// out as 0.2475 instead of 460.
	func testAWordEndsWhereTheNumberBegins() {
		XCTAssertEqual(sheet.evaluate("pa strau malt613.33-25%")[0].formatted, "460")
		XCTAssertEqual(sheet.evaluate("7 mortar 10kg")[0].formatted, "7")
		XCTAssertEqual(sheet.evaluate("35eur oil change")[0].formatted, "€35")
	}

	/// A typed `=` with something that is not a name on its left: the left is
	/// the note and the sum is on the right.
	func testTheAnswerCanBeOnTheRightOfATypedEquals() {
		XCTAssertEqual(sheet.evaluate("loco esti 87x14=1220-25%")[0].formatted, "915")
	}

	func testAnAssignmentIsStillAnAssignment() {
		let lines = sheet.evaluate("car repair = 350")

		XCTAssertEqual(lines[0].kind, .assignment("car repair"))
		XCTAssertEqual(lines[0].formatted, "350")
	}

	func testATitleIsStillProse() {
		let lines = sheet.evaluate("flat renovation")

		XCTAssertEqual(lines[0].kind, .prose)
		XCTAssertNil(lines[0].value)
	}
}

/// `x` is how people write a times sign when they are not thinking about it.
final class TimesSignTests: XCTestCase {
	private let sheet = Sheet()
	private let latvian = Sheet(locale: Locale(identifier: "lv_LV"))

	func testXBetweenTwoNumbers() {
		XCTAssertEqual(sheet.evaluate("14x100")[0].formatted, "1,400")
		XCTAssertEqual(sheet.evaluate("14 x 100")[0].formatted, "1,400")
		XCTAssertEqual(sheet.evaluate("3x4")[0].formatted, "12")
		XCTAssertEqual(sheet.evaluate("(2+3) x 4")[0].formatted, "20")
		XCTAssertEqual(sheet.evaluate("14 eur x 3")[0].formatted, "€42")
	}

	/// The line that was reported: it used to answer 14, having quietly
	/// dropped the hundred.
	func testTheWholeLine() {
		XCTAssertEqual(latvian.evaluate("14x100-25,5%")[0].formatted, "1043")
		XCTAssertEqual(sheet.evaluate("14x100-25.5%")[0].formatted, "1,043")
	}

	func testItReadsTheSameAsAStar() {
		XCTAssertEqual(sheet.evaluate("5 boxes x 3")[0].formatted,
					   sheet.evaluate("5 boxes * 3")[0].formatted)
	}

	/// A sheet is still free to call something x. Nothing follows the letter
	/// there, and nothing precedes it, so it is never taken for a sign.
	func testAVariableMayStillBeCalledX() {
		let lines = sheet.evaluate("""
		x = 5
		x * 2
		""")

		XCTAssertEqual(lines[0].kind, .assignment("x"))
		XCTAssertEqual(lines[1].formatted, "10")
	}

	func testALetterWithNoNumberAfterItIsJustALetter() {
		XCTAssertEqual(sheet.evaluate("5 x")[0].formatted, "5")
	}

	/// Nothing precedes the letter here, so it is a word and the line is a
	/// hundred with a label, the same as `abc 100`. Were it read as a sign it
	/// would have no left hand side and the line would be prose.
	func testALeadingXIsAWordNotASign() {
		XCTAssertEqual(sheet.evaluate("x100")[0].formatted, "100")
	}
}

final class CurrencyTests: XCTestCase {
	private let sheet = Sheet()

	private func value(_ text: String) -> String? {
		sheet.evaluateOne(text).formatted
	}

	private func error(_ text: String) -> String? {
		sheet.evaluateOne(text).error
	}

	func testAmountsAreRecognisedInEveryCommonShape() {
		XCTAssertEqual(value("€35"), "€35")
		XCTAssertEqual(value("€ 35"), "€35")
		XCTAssertEqual(value("35€"), "€35")
		XCTAssertEqual(value("35eur"), "€35")
		XCTAssertEqual(value("35 EUR"), "€35")
		XCTAssertEqual(value("$20"), "$20")
		XCTAssertEqual(value("20 usd"), "$20")
		XCTAssertEqual(value("100 CHF"), "100 CHF")   // no symbol, so the code
	}

	func testArithmeticKeepsTheCurrency() {
		XCTAssertEqual(value("€10 + €5"), "€15")
		XCTAssertEqual(value("€10 - €2.50"), "€7.50")
		XCTAssertEqual(value("€10 * 3"), "€30")
		XCTAssertEqual(value("3 * €10"), "€30")
		XCTAssertEqual(value("€30 / 4"), "€7.50")
	}

	/// A plain number next to money takes the currency, which is how anyone
	/// writing a list of prices actually types.
	func testPlainNumbersAdoptTheCurrency() {
		XCTAssertEqual(value("€40 + 2"), "€42")
		XCTAssertEqual(value("2 + €40"), "€42")
	}

	func testPercentagesOnMoney() {
		XCTAssertEqual(value("€120 + 10%"), "€132")
		XCTAssertEqual(value("€120 - 10%"), "€108")
		XCTAssertEqual(value("20% of €300"), "€60")
	}

	/// Same currency divides out to a ratio, which is a plain number again.
	func testDividingMoneyByMoneyGivesARatio() {
		XCTAssertEqual(value("€30 / €10"), "3")
	}

	func testMixingCurrenciesIsRefusedRatherThanGuessed() {
		XCTAssertEqual(error("€10 + $10"), "Cannot mix EUR and USD without an exchange rate")
		XCTAssertEqual(error("€10 * $10"), "Cannot mix EUR and USD without an exchange rate")
		XCTAssertNil(value("€10 + $10"))
	}

	func testOperationsThatMakeNoSenseOnMoney() {
		XCTAssertNotNil(error("sqrt(€16)"))
		XCTAssertNotNil(error("€2 ^ 2"))
		XCTAssertNotNil(error("10 / €2"))
	}

	func testRoundingKeepsTheCurrency() {
		XCTAssertEqual(value("round(€2.60)"), "€3")
		XCTAssertEqual(value("abs(-€7)"), "€7")
		XCTAssertEqual(value("max(€3, €9)"), "€9")
	}

	func testNegativeAmountsPutTheSignFirst() {
		XCTAssertEqual(value("€5 - €12"), "-€7")
	}

	func testTotallingAColumnOfPrices() {
		let sheet = Sheet()
		let lines = sheet.evaluate("""
		35eur
		45eur
		12.50eur
		""")

		XCTAssertEqual(sheet.grandTotal(of: lines).map { sheet.format($0) }, ["€92.50"])
	}

	func testArithmeticRefusesMixedCurrencies() {
		let line = sheet.evaluateOne("35eur + 45usd")

		XCTAssertNil(line.value)
		XCTAssertEqual(line.error, "Cannot mix EUR and USD without an exchange rate")
	}

	func testMoneyVariables() {
		let lines = sheet.evaluate("""
		rent = €800
		rent * 12
		""")

		XCTAssertEqual(lines[1].formatted, "€9,600")
	}

	func testDecimalExactnessHoldsForMoney() {
		let line = sheet.evaluateOne("0.10eur + 0.20eur")

		XCTAssertEqual(line.value, Quantity(Decimal(string: "0.30")!, "EUR"))
	}
}

final class CommentTests: XCTestCase {
	private let sheet = Sheet()

	func testHashHidesTheRestOfTheLineFromTheMath() {
		let line = sheet.evaluateOne("10 + 5 # ignore me, 999")
		XCTAssertEqual(line.formatted, "15")
		XCTAssertEqual(line.code, "10 + 5 ")
		XCTAssertEqual(line.comment, "# ignore me, 999")
	}

	func testAWholeLineComment() {
		let line = sheet.evaluateOne("# just a note")
		XCTAssertEqual(line.kind, .comment)
		XCTAssertNil(line.value)
		XCTAssertEqual(line.comment, "# just a note")
		XCTAssertEqual(line.code, "")
	}

	/// The split has to be lossless or the editor could not draw the line back.
	func testCodeAndCommentReassembleTheOriginal() {
		for text in ["10 + 5 # note", "# note", "no comment here", "  42  #  x  ", "a // b"] {
			let line = sheet.evaluateOne(text)
			XCTAssertEqual(line.code + (line.comment ?? ""), text)
		}
	}

	func testCommentedOutLineIsNotProse() {
		let lines = sheet.evaluate("""
		100
		# 200
		""")

		XCTAssertEqual(lines[1].kind, .comment)
		XCTAssertNil(lines[1].value)

		// The hidden 200 is not counted.
		XCTAssertEqual(sheet.grandTotal(of: lines).map { sheet.format($0) }, ["100"])
	}

	func testDoubleSlashStillComments() {
		let line = sheet.evaluateOne("7 * 6 // the answer")
		XCTAssertEqual(line.formatted, "42")
		XCTAssertEqual(line.comment, "// the answer")
	}

	/// A note on the end of a line does not stop the line counting.
	func testATrailingCommentDoesNotStopTheLineCounting() {
		let lines = sheet.evaluate("""
		10 # first
		20 # second
		""")

		XCTAssertEqual(lines.map(\.formatted), ["10", "20"])
		XCTAssertEqual(sheet.grandTotal(of: lines).map { sheet.format($0) }, ["30"])
	}
}

final class GrandTotalTests: XCTestCase {
	private let sheet = Sheet()

	private func totals(_ source: String) -> [String] {
		let lines = sheet.evaluate(source)
		return sheet.grandTotal(of: lines).map { sheet.format($0) }
	}

	func testTotalsEverythingInTheResultColumn() {
		XCTAssertEqual(totals("""
		10
		20
		12.5
		"""), ["42.5"])
	}

	/// A `sum` already in the sheet must not be added to the numbers it came
	/// from, or the bottom bar would read double.
	func testSubtotalsAreNotCountedTwice() {
		XCTAssertEqual(totals("""
		10
		20
		sum
		"""), ["30"])
	}

	func testCommentsAndProseContributeNothing() {
		XCTAssertEqual(totals("""
		# heading
		10
		shopping list
		20
		// 999
		"""), ["30"])
	}

	func testMoneyTotals() {
		XCTAssertEqual(totals("""
		35eur
		45eur
		12.50eur
		"""), ["€92.50"])
	}

	/// With no exchange rates the honest answer is one total per currency.
	func testEachCurrencyGetsItsOwnTotal() {
		XCTAssertEqual(totals("""
		35eur
		20usd
		15eur
		"""), ["€50", "$20"])
	}

	/// Naming a number is not spending it. A sheet that opens by declaring a
	/// rate and a headcount used to add both into the bar along the bottom,
	/// which made the total of every sheet using names meaningless.
	func testDefinitionsAreNotAmounts() {
		XCTAssertEqual(totals("""
		rent = 800
		food = 200
		"""), [])
	}

	func testALineUsingANameIsStillAnAmount() {
		XCTAssertEqual(totals("""
		rate = 12
		3 * rate    # three hours
		5 * rate    # five hours
		"""), ["96"])
	}



	/// Two decimals is the display. The arithmetic keeps every digit, so the
	/// bar adds the exact figures and rounds once at the end rather than
	/// adding up a column of numbers that have each already been rounded.
	func testTheTotalAddsTheExactFiguresNotTheRoundedOnes() {
		let lines = Sheet().evaluate("""
		0.004
		0.004
		0.004
		""")

		XCTAssertEqual(lines.map(\.formatted), ["0", "0", "0"])
		XCTAssertEqual(totals("""
		0.004
		0.004
		0.004
		"""), ["0.01"])
	}

	func testALongAnswerIsShownToTwoDecimals() {
		XCTAssertEqual(Sheet().evaluate("613.33-25%")[0].formatted, "460")
		XCTAssertEqual(Sheet().evaluate("1850 / 0.79")[0].formatted, "2,341.77")
		XCTAssertEqual(Sheet().evaluate("2.675")[0].formatted, "2.68")
	}

	func testEmptySheetHasNoTotal() {
		XCTAssertEqual(totals("\n# nothing\n"), [])
	}
}

final class StoredAnswerTests: XCTestCase {
	private let marker = SheetDocument.answerMarker

	func testNumisAnswerIsTakenOffTheLine() {
		let document = SheetDocument(text: "35eur oil\(marker)€ 35")

		XCTAssertEqual(document.lines, ["35eur oil"])
		XCTAssertEqual(document.storedAnswers, ["€ 35"])
		XCTAssertEqual(document.text, "35eur oil")
	}

	/// Nothing is rewritten just by opening a sheet.
	func testTheAnswerGoesBackExactlyAsItCame() {
		let source = "35eur oil\(marker)€ 35\n\n12 + 3\(marker)15"
		XCTAssertEqual(SheetDocument(text: source).fileContents, source)
	}

	/// An `=` typed by hand has ordinary spaces around it and is a variable,
	/// not an answer, so it must survive untouched.
	func testAnOrdinaryEqualsIsNotAnAnswer() {
		let document = SheetDocument(text: "rate = 0.21")

		XCTAssertEqual(document.lines, ["rate = 0.21"])
		XCTAssertEqual(document.storedAnswers, [nil])
		XCTAssertEqual(document.fileContents, "rate = 0.21")
	}

	/// A stale answer would be a lie about text that has since changed.
	/// A stale answer would be a lie about text that has since changed.
	func testEditingALineDropsItsOldAnswer() {
		var document = SheetDocument(text: "35eur oil\(marker)€ 35")
		document.setText("40eur oil")

		XCTAssertNil(document.storedAnswers[0])
		XCTAssertEqual(document.fileContents, "40eur oil")
	}

	/// Typing on one line must not strip the answers off all the others, or
	/// one keystroke would rewrite the whole file.
	func testEditingOneLineLeavesTheOtherAnswersAlone() {
		var document = SheetDocument(text: "a\(marker)1\nb\(marker)2\nc\(marker)3")
		document.setText("a\nb changed\nc")

		XCTAssertEqual(document.storedAnswers, ["1", nil, "3"])
		XCTAssertEqual(document.fileContents, "a\(marker)1\nb changed\nc\(marker)3")
	}

	/// Answers follow their line rather than their position, so inserting
	/// above does not shuffle them onto the wrong lines.
	func testAnswersFollowTheirLineWhenLinesMove() {
		var document = SheetDocument(text: "a\(marker)1\nb\(marker)2")
		document.setText("new\na\nb")

		XCTAssertEqual(document.storedAnswers, [nil, "1", "2"])
	}

	func testDeletingALineLeavesTheRestIntact() {
		var document = SheetDocument(text: "a\(marker)1\nb\(marker)2\nc\(marker)3")
		document.setText("a\nc")

		XCTAssertEqual(document.storedAnswers, ["1", "3"])
	}

	/// Re-typing the same text must give back the same file, byte for byte.
	func testSettingTheSameTextChangesNothing() {
		let source = "a\(marker)1\nb\(marker)2"
		var document = SheetDocument(text: source)
		document.setText(document.text)

		XCTAssertEqual(document.fileContents, source)
	}

	/// The calculator works from the line, never from Numi's answer to it.
	func testTheAnswerIsNotFedBackIntoTheMath() {
		// The stored answer is deliberately wrong. The line is worth what it
		// says, not what Numi wrote next to it.
		let document = SheetDocument(text: "10 + 5\(marker)999")
		let lines = Sheet().evaluate(document.text)

		XCTAssertEqual(lines[0].formatted, "15")
	}
}

final class FormattingTests: XCTestCase {
	private let sheet = Sheet()

	private func value(_ text: String) -> String? {
		sheet.evaluateOne(text).formatted
	}

	/// Cents appear only when there are cents.
	func testRoundAmountsAreWrittenRound() {
		XCTAssertEqual(value("35eur"), "€35")
		XCTAssertEqual(value("€10 + €5"), "€15")
		XCTAssertEqual(value("€10 * 3"), "€30")
		XCTAssertEqual(value("100 CHF"), "100 CHF")
	}

	func testFractionsKeepBothPlaces() {
		XCTAssertEqual(value("12.50eur"), "€12.50")
		XCTAssertEqual(value("€30 / 4"), "€7.50")
		XCTAssertEqual(value("€10 / 3"), "€3.33")
	}

	func testNegativeRoundAmounts() {
		XCTAssertEqual(value("€5 - €12"), "-€7")
	}

	func testPlainNumbersAreUnaffected() {
		XCTAssertEqual(value("2+2"), "4")
		XCTAssertEqual(value("10 / 4"), "2.5")
		XCTAssertEqual(value("1234567 + 1"), "1,234,568")
	}

	/// Tabs are how a sheet is lined up by eye, so they must not upset it.
	func testTabsAreJustWhitespace() {
		XCTAssertEqual(value("35eur\toil change"), "€35")
		XCTAssertEqual(value("10\t+\t5"), "15")
		XCTAssertEqual(sheet.evaluateOne("35eur\t\t# paid").comment, "# paid")
	}
}

final class SheetNameTests: XCTestCase {

	private func name(_ text: String) -> String {
		SheetDocument(text: text).name
	}

	func testTheNameIsTheFirstLineThatSaysSomething() {
		XCTAssertEqual(name("volvo remonts\n35eur oil"), "volvo remonts")
		XCTAssertEqual(name("\n\n  \n2023 invoices\n10"), "2023 invoices")
	}

	/// Sheets are usually titled with a heading, so the marker comes off.
	func testCommentMarkersAreNotPartOfTheName() {
		XCTAssertEqual(name("# Q1 invoices\n10"), "Q1 invoices")
		XCTAssertEqual(name("### Q1\n10"), "Q1")
		XCTAssertEqual(name("// notes\n10"), "notes")
	}

	func testAnAnswerNumiLeftIsNotPartOfTheName() {
		XCTAssertEqual(name("35eur oil\(SheetDocument.answerMarker)€ 35"), "35eur oil")
	}

	func testAnEmptySheetIsUntitled() {
		XCTAssertEqual(name(""), "Untitled")
		XCTAssertEqual(name("\n\n   \n"), "Untitled")
		XCTAssertEqual(name("#\n##  "), "Untitled")
	}

	func testLongTitlesAreCutShort() {
		XCTAssertEqual(name(String(repeating: "a", count: 80)).count, 40)
	}
}

final class SheetCacheTests: XCTestCase {
	private var root: URL!
	private var source: URL!
	private var cache: SheetCache!

	override func setUpWithError() throws {
		root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("cache-tests-\(UUID().uuidString)")
		source = root.appendingPathComponent("cloud")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

		cache = SheetCache(folder: root.appendingPathComponent("local"))
		try cache.makeFolder()
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: root)
	}

	private func putInSource(_ name: String, _ text: String, ageInSeconds: TimeInterval = 0) throws {
		let file = source.appendingPathComponent(name)
		try text.write(to: file, atomically: true, encoding: .utf8)

		if ageInSeconds != 0 {
			try FileManager.default.setAttributes(
				[.modificationDate: Date().addingTimeInterval(-ageInSeconds)],
				ofItemAtPath: file.path)
		}
	}

	func testBringsSheetsDownFromTheCloudFolder() throws {
		try putInSource("volvo.myocalc", "35eur oil")
		try putInSource("q1.myocalc", "# Q1")

		let copied = try cache.refresh(from: source)

		XCTAssertEqual(copied.sorted(), ["q1.myocalc", "volvo.myocalc"])
		XCTAssertEqual(cache.names(), ["q1.myocalc", "volvo.myocalc"])
		XCTAssertEqual(cache.read("volvo.myocalc"), "35eur oil")
	}

	/// The sheet wanted next is nearly always the one just put down.
	func testTheLastEditedSheetComesFirst() throws {
		try putInSource("aaa.myocalc", "oldest", ageInSeconds: 3600)
		try putInSource("zzz.myocalc", "newest")
		try putInSource("mmm.myocalc", "middling", ageInSeconds: 600)

		try cache.refresh(from: source)

		XCTAssertEqual(cache.names(), ["zzz.myocalc", "mmm.myocalc", "aaa.myocalc"])
	}

	/// Two sheets written in the same second must not swap places between one
	/// listing and the next.
	func testSheetsOfTheSameAgeAreOrderedByName() throws {
		let stamp = Date().addingTimeInterval(-120)
		for name in ["b.myocalc", "a.myocalc", "c.myocalc"] {
			try putInSource(name, "10")
			try FileManager.default.setAttributes(
				[.modificationDate: stamp],
				ofItemAtPath: source.appendingPathComponent(name).path)
		}

		try cache.refresh(from: source)

		XCTAssertEqual(cache.names(), ["a.myocalc", "b.myocalc", "c.myocalc"])
	}

	/// Only sheets are sheets.
	func testIgnoresEverythingThatIsNotASheet() throws {
		try putInSource("notes.txt", "not a sheet")
		try putInSource("real.myocalc", "10")

		try cache.refresh(from: source)
		XCTAssertEqual(cache.names(), ["real.myocalc"])
	}

	/// A sheet is a `.myocalc` file. The extension is Myo's own rather than
	/// borrowed, so what the app writes is plainly its own document. `.myo`
	/// alone belongs to an accounting package, which is close enough to what
	/// this does to end up on the same machine.
	func testASheetIsAMyoCalcFile() {
		XCTAssertEqual(SheetCache.fileExtension, "myocalc")
	}

	/// Numi's files are not read. Myo used to take its extension, which made
	/// every Numi sheet in a folder look like one of Myo's own; it does not
	/// any more, and a folder holding both shows only Myo's.
	func testDoesNotClaimNumisSheets() throws {
		try putInSource("borrowed.numi", "10")
		try putInSource("mine.myocalc", "20")

		try cache.refresh(from: source)
		XCTAssertEqual(cache.names(), ["mine.myocalc"])
	}

	func testSecondRefreshBringsNothingDownAgain() throws {
		try putInSource("a.myocalc", "10", ageInSeconds: 60)
		try cache.refresh(from: source)

		XCTAssertEqual(try cache.refresh(from: source), [])
	}

	func testABetterCopyInTheCloudWins() throws {
		try putInSource("a.myocalc", "old", ageInSeconds: 60)
		try cache.refresh(from: source)

		try putInSource("a.myocalc", "edited elsewhere")   // now, so newer
		XCTAssertEqual(try cache.refresh(from: source), ["a.myocalc"])
		XCTAssertEqual(cache.read("a.myocalc"), "edited elsewhere")
	}

	/// An edit made here and not yet written back must not be overwritten by
	/// the older copy it came from.
	func testAnUnsentEditIsNotClobbered() throws {
		try putInSource("a.myocalc", "from the cloud", ageInSeconds: 600)
		try cache.refresh(from: source)

		try cache.write("edited on the phone", to: "a.myocalc", source: nil)   // offline

		XCTAssertEqual(try cache.refresh(from: source), [])
		XCTAssertEqual(cache.read("a.myocalc"), "edited on the phone")
	}

	func testWritingGoesToBothCopies() throws {
		try putInSource("a.myocalc", "before")
		try cache.refresh(from: source)

		let reachedSource = try cache.write("after", to: "a.myocalc", source: source)

		XCTAssertTrue(reachedSource)
		XCTAssertEqual(cache.read("a.myocalc"), "after")
		XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("a.myocalc"), encoding: .utf8),
					   "after")
	}

	/// Offline, the sheet still has to be safe on the device.
	func testWritingSurvivesAnUnreachableSource() throws {
		let gone = root.appendingPathComponent("unplugged")
		let reachedSource = try cache.write("kept", to: "a.myocalc", source: gone)

		XCTAssertFalse(reachedSource)
		XCTAssertEqual(cache.read("a.myocalc"), "kept")
	}

	func testFindsAnUnusedName() throws {
		XCTAssertEqual(cache.unusedName(startingFrom: "Untitled"), "Untitled.myocalc")

		try cache.write("", to: "Untitled.myocalc", source: nil)
		XCTAssertEqual(cache.unusedName(startingFrom: "Untitled"), "Untitled 2.myocalc")

		try cache.write("", to: "Untitled 2.myocalc", source: nil)
		XCTAssertEqual(cache.unusedName(startingFrom: "Untitled"), "Untitled 3.myocalc")
	}

	func testRemovingTakesBothCopies() throws {
		try putInSource("a.myocalc", "x")
		try cache.refresh(from: source)

		cache.remove("a.myocalc", source: source)

		XCTAssertEqual(cache.names(), [])
		XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.myocalc").path))
	}

	func testEmptyingForgetsTheFolder() throws {
		try putInSource("a.myocalc", "x")
		try cache.refresh(from: source)

		cache.empty()
		XCTAssertEqual(cache.names(), [])
	}
}

@MainActor
final class FolderWatcherTests: XCTestCase {
	private var root: URL!
	private var watcher: FolderWatcher!
	private var fired = 0

	override func setUpWithError() throws {
		root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("watcher-tests-\(UUID().uuidString)")
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

		fired = 0
		watcher = FolderWatcher()
		watcher.onChange = { [weak self] in self?.fired += 1 }
	}

	override func tearDownWithError() throws {
		watcher.stop()
		try? FileManager.default.removeItem(at: root)
	}

	private func settle(_ seconds: TimeInterval = 1.2) async {
		try? await Task.sleep(for: .seconds(seconds))
	}

	private func write(_ text: String, _ name: String) {
		try? text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
	}

	func testNoticesASheetArrivingInTheFolder() async {
		watcher.watch(folder: root, file: nil)
		await settle(0.4)

		fired = 0
		write("5\n", "arrived.myocalc")
		await settle()

		XCTAssertGreaterThan(fired, 0)
	}

	func testNoticesTheOpenSheetBeingChanged() async {
		write("10\n", "open.myocalc")
		watcher.watch(folder: root, file: root.appendingPathComponent("open.myocalc"))
		await settle(0.4)

		fired = 0
		write("10\n20\n", "open.myocalc")
		await settle()

		XCTAssertGreaterThan(fired, 0)
	}

	/// A cloud client bringing down six sheets should be one reload.
	func testABurstSettlesIntoOneReload() async {
		watcher.watch(folder: root, file: nil)
		await settle(0.4)

		fired = 0
		for index in 0..<6 { write("\(index)", "burst\(index).myocalc") }
		await settle()

		XCTAssertEqual(fired, 1)
	}

	func testStopsWhenTold() async {
		watcher.watch(folder: root, file: nil)
		await settle(0.4)
		watcher.stop()

		fired = 0
		write("1", "after.myocalc")
		await settle()

		XCTAssertEqual(fired, 0)
	}

	/// Re-arming cancels the old sources, and dispatch runs a cancel handler on
	/// its own queue. A handler carrying actor isolation traps there, which
	/// took the whole app down when a folder was chosen.
	func testRearmingRepeatedlyDoesNotTrap() async {
		for _ in 0..<5 {
			watcher.watch(folder: root, file: nil)
			await settle(0.15)
		}

		fired = 0
		write("1", "still-working.myocalc")
		await settle()

		XCTAssertGreaterThan(fired, 0, "watcher stopped working after being re-armed")
	}

	func testWatchingSomethingThatIsNotThereIsHarmless() async {
		watcher.watch(folder: root.appendingPathComponent("missing"), file: nil)
		await settle(0.3)
		watcher.stop()
	}
}

final class SheetFileNameTests: XCTestCase {

	func testKnowsAnAutomaticName() {
		XCTAssertTrue(SheetCache.isAutomatic("Untitled.myocalc"))
		XCTAssertTrue(SheetCache.isAutomatic("Untitled 2.myocalc"))
		XCTAssertTrue(SheetCache.isAutomatic("Untitled 17.myocalc"))

		XCTAssertFalse(SheetCache.isAutomatic("volvo.myocalc"))
		XCTAssertFalse(SheetCache.isAutomatic("Untitled thoughts.myocalc"))
		XCTAssertFalse(SheetCache.isAutomatic("2022_v2.myocalc"))
	}

	func testTurnsATitleIntoAFileName() {
		XCTAssertEqual(SheetCache.fileName(forTitle: "volvo remonts"), "volvo remonts.myocalc")
		XCTAssertEqual(SheetCache.fileName(forTitle: "rēķini 2022"), "rēķini 2022.myocalc")
		XCTAssertEqual(SheetCache.fileName(forTitle: "Q1 invoices"), "Q1 invoices.myocalc")
	}

	/// A first line is prose, and prose contains characters a file system will
	/// not take.
	func testStripsWhatAFileSystemWillNotTake() {
		XCTAssertEqual(SheetCache.fileName(forTitle: "income/outgoings"), "income outgoings.myocalc")
		XCTAssertEqual(SheetCache.fileName(forTitle: "budget: 2024"), "budget 2024.myocalc")
		XCTAssertEqual(SheetCache.fileName(forTitle: "  spaced  "), "spaced.myocalc")
		XCTAssertNil(SheetCache.fileName(forTitle: "..."))
		XCTAssertNil(SheetCache.fileName(forTitle: "   "))
		XCTAssertNil(SheetCache.fileName(forTitle: "Untitled"))
	}

	/// The title is what gets cut, to 60 characters; the extension is then put
	/// back on whole. Working the bound out from the extension rather than
	/// writing the total down means changing the extension cannot quietly
	/// break this.
	func testKeepsFileNamesToASensibleLength() {
		let long = String(repeating: "a", count: 200)
		let made = SheetCache.fileName(forTitle: long)
		XCTAssertNotNil(made)
		XCTAssertLessThanOrEqual(made!.count, 60 + 1 + SheetCache.fileExtension.count)
	}

	func testRenamesInBothPlaces() throws {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("rename-\(UUID().uuidString)")
		let source = root.appendingPathComponent("cloud")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)

		let cache = SheetCache(folder: root.appendingPathComponent("local"))
		try cache.makeFolder()
		_ = try cache.write("volvo remonts\n35eur", to: "Untitled.myocalc", source: source)

		XCTAssertTrue(cache.rename("Untitled.myocalc", to: "volvo remonts.myocalc", source: source))
		XCTAssertEqual(cache.names(), ["volvo remonts.myocalc"])
		XCTAssertTrue(FileManager.default.fileExists(
			atPath: source.appendingPathComponent("volvo remonts.myocalc").path))

		try? FileManager.default.removeItem(at: root)
	}

	/// Renaming onto a sheet that already exists would destroy it.
	func testWillNotRenameOverAnExistingSheet() throws {
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("rename-\(UUID().uuidString)")
		let cache = SheetCache(folder: root)
		try cache.makeFolder()

		_ = try cache.write("one", to: "Untitled.myocalc", source: nil)
		_ = try cache.write("two", to: "taken.myocalc", source: nil)

		XCTAssertFalse(cache.rename("Untitled.myocalc", to: "taken.myocalc", source: nil))
		XCTAssertEqual(cache.read("taken.myocalc"), "two")

		try? FileManager.default.removeItem(at: root)
	}
}
