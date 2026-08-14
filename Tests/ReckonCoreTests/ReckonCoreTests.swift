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

	func testSumAndAverageOfTheBlockAbove() {
		let lines = sheet.evaluate("""
		10
		20
		30
		sum
		""")
		XCTAssertEqual(lines[3].formatted, "60")

		let averaged = sheet.evaluate("""
		10
		20
		30
		avg
		""")
		XCTAssertEqual(averaged[3].formatted, "20")
	}

	func testPreviousAndLineReferences() {
		let lines = sheet.evaluate("""
		10
		20
		prev * 2
		line 1 + 5
		""")

		XCTAssertEqual(lines[2].formatted, "40")
		XCTAssertEqual(lines[3].formatted, "15")
	}

	/// A subtotal closes its block, so totalling again below does not fold the
	/// earlier total back in and count those numbers twice.
	func testSubtotalsDoNotDoubleCount() {
		let lines = sheet.evaluate("""
		10
		20
		sum
		5
		6
		sum
		""")

		XCTAssertEqual(lines[2].formatted, "30")
		XCTAssertEqual(lines[5].formatted, "11")
	}

	/// The same applies when the subtotal is carried into another expression,
	/// such as adding tax to it.
	func testDerivedSubtotalAlsoClosesTheBlock() {
		let lines = sheet.evaluate("""
		100
		200
		sum * 1.21
		7
		sum
		""")

		XCTAssertEqual(lines[2].formatted, "363")
		XCTAssertEqual(lines[4].formatted, "7")
	}

	/// A blank line ends a block, so one sheet can hold several tallies.
	func testBlankLineSeparatesTotals() {
		let lines = sheet.evaluate("""
		10
		20
		sum

		5
		6
		sum
		""")

		XCTAssertEqual(lines[2].formatted, "30")
		XCTAssertEqual(lines[6].formatted, "11")
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
		let lines = sheet.evaluate("""
		35eur
		45eur
		12.50eur
		sum
		""")

		XCTAssertEqual(lines[3].formatted, "€92.50")
	}

	func testTotallingRefusesMixedCurrencies() {
		let lines = sheet.evaluate("""
		35eur
		45usd
		sum
		""")

		XCTAssertNil(lines[2].value)
		XCTAssertEqual(lines[2].error, "Cannot mix EUR and USD without an exchange rate")
	}

	func testMoneyVariables() {
		let lines = sheet.evaluate("""
		rent = €800
		rent * 12
		""")

		XCTAssertEqual(lines[1].formatted, "€9,600")
	}

	func testDecimalExactnessHoldsForMoney() {
		let lines = sheet.evaluate("""
		0.10eur
		0.20eur
		sum
		""")

		XCTAssertEqual(lines[2].value, Quantity(Decimal(string: "0.30")!, "EUR"))
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
		sum
		""")

		XCTAssertEqual(lines[1].kind, .comment)
		XCTAssertEqual(lines[2].formatted, "100")   // the hidden 200 is not counted
	}

	func testDoubleSlashStillComments() {
		let line = sheet.evaluateOne("7 * 6 // the answer")
		XCTAssertEqual(line.formatted, "42")
		XCTAssertEqual(line.comment, "// the answer")
	}

	func testCommentDoesNotBreakABlock() {
		let lines = sheet.evaluate("""
		10 # first
		20 # second
		sum
		""")

		XCTAssertEqual(lines[2].formatted, "30")
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

	func testAssignmentsCountToo() {
		XCTAssertEqual(totals("""
		rent = 800
		food = 200
		"""), ["1,000"])
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
		let document = SheetDocument(text: "10\(marker)10\n20\(marker)20\nsum")
		let lines = Sheet().evaluate(document.text)

		XCTAssertEqual(lines[2].formatted, "30")
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
