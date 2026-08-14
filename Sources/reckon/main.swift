import Foundation
import ReckonCore

// reckon "2+2"          evaluate one expression
// reckon file.numi      evaluate a sheet
// cat sheet | reckon    evaluate a sheet from stdin
//
// --stats prints a summary instead of the sheet, which is handy for checking
// how much of an existing document this engine understands.

var arguments = Array(CommandLine.arguments.dropFirst())
let wantsStats = arguments.contains("--stats")
let wantsRoundTrip = arguments.contains("--roundtrip")
let wantsCompare = arguments.contains("--compare")
let wantsName = arguments.contains("--name")
arguments.removeAll { $0 == "--stats" || $0 == "--roundtrip" || $0 == "--compare" || $0 == "--name" }

let sheet = Sheet(locale: Locale(identifier: "en_US_POSIX"))

let source: String
if let first = arguments.first, FileManager.default.fileExists(atPath: first) {
	source = (try? String(contentsOfFile: first, encoding: .utf8)) ?? ""
} else if !arguments.isEmpty {
	source = arguments.joined(separator: " ")
} else {
	var input = ""
	while let line = readLine(strippingNewline: false) { input += line }
	source = input
}

// Saving must never alter a byte that was not typed, so this checks that a
// file survives being read into a document and written back out.
if wantsRoundTrip {
	let rebuilt = SheetDocument(text: source).fileContents
	print(rebuilt == source ? "identical" : "CHANGED")
	exit(rebuilt == source ? 0 : 1)
}

// Numi's own answers are in the file, so they can be used to check this
// engine against a real implementation.
if wantsCompare {
	let document = SheetDocument(text: source)
	let evaluated = sheet.evaluate(document.text)
	var agreed = 0, differed = 0, missing = 0, unreadable = 0

	// Compare the value, not the spacing: Numi writes "€ 35" where this
	// writes "€35.00", and those are the same number.
	func mineNumber(_ text: String) -> Double? {
		Double(text.filter { $0.isNumber || $0 == "-" || $0 == "." })
	}

	// Numi writes this machine's locale: comma for the decimal, space for
	// the thousands.
	func numiNumber(_ text: String) -> Double? {
		let kept = text.filter { $0.isNumber || $0 == "-" || $0 == "," }
		return Double(kept.replacingOccurrences(of: ",", with: "."))
	}

	for (index, answer) in document.storedAnswers.enumerated() {
		guard let answer else { continue }

		guard let ours = evaluated.indices.contains(index) ? evaluated[index].formatted : nil else {
			missing += 1
			continue
		}
		guard let mine = mineNumber(ours), let theirs = numiNumber(answer) else {
			unreadable += 1
			continue
		}

		if abs(mine - theirs) <= 0.01 {
			agreed += 1
		} else {
			differed += 1
			// Letters masked: the numbers are the point, the words are not.
			let masked = String(evaluated[index].text.map { $0.isLetter ? "a" : $0 })
			print("  differs: \(masked)  | mine \(ours)  numi \(answer.trimmingCharacters(in: .whitespaces))")
		}
	}

	print("answers \(agreed + differed + missing + unreadable)  agreed \(agreed)  differed \(differed)  noResult \(missing)  unreadable \(unreadable)")
	exit(0)
}

// What this sheet is called in the list: its first line.
if wantsName {
	print(SheetDocument(text: source).name)
	exit(0)
}

let lines = sheet.evaluate(source)

if wantsStats {
	let evaluated = lines.filter(\.hasValue).count
	let prose = lines.filter { $0.kind == .prose }.count
	let blank = lines.filter { $0.kind == .blank }.count
	let comments = lines.filter { $0.kind == .comment }.count
	let errors = lines.filter { $0.error != nil }.count
	print("lines \(lines.count)  evaluated \(evaluated)  prose \(prose)  comment \(comments)  blank \(blank)  errors \(errors)")
} else {
	for line in lines {
		if let formatted = line.formatted {
			print("\(line.text.trimmingCharacters(in: .whitespaces))\t= \(formatted)")
		} else if let error = line.error {
			print("\(line.text.trimmingCharacters(in: .whitespaces))\t! \(error)")
		} else if !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
			print(line.text)
		}
	}

	let totals = sheet.grandTotal(of: lines)
	if !totals.isEmpty {
		print("\t\u{2500}\u{2500}\u{2500}")
		print("total\t= " + totals.map { sheet.format($0) }.joined(separator: "  "))
	}
}
