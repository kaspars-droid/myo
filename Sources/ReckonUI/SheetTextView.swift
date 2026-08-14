import SwiftUI
import ReckonCore

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformView = NSView
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
typealias PlatformView = UIView
#endif

// MARK: - Styling

enum LineStyle {
	static var font: PlatformFont {
		.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)
	}

	/// Air between the lines. A sheet is a list to read down, not a paragraph.
	static let lineSpacing: CGFloat = 7

	static var lineHeight: CGFloat {
#if os(macOS)
		font.boundingRectForFont.height + lineSpacing
#else
		font.lineHeight + lineSpacing
#endif
	}

	static var paragraph: NSParagraphStyle {
		let style = NSMutableParagraphStyle()
		style.lineSpacing = lineSpacing
		return style
	}

	/// Results are the same size as the sheet, a little heavier.
	static var resultFont: PlatformFont {
		.monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .medium)
	}

	/// How wide a result column has to be to hold these values.
	///
	/// The column is only as wide as its widest number, so a sheet of small
	/// figures does not reserve room for a five figure sum it will never have.
	static func columnWidth(for values: [String?]) -> CGFloat {
		let widest = values.compactMap { $0 }
			.map { NSAttributedString(string: $0, attributes: [.font: resultFont]).size().width }
			.max() ?? 0

		return min(max(ceil(widest) + 2, 44), 240)
	}

	static var typing: [NSAttributedString.Key: Any] {
		[.font: font, .foregroundColor: PlatformColor.sheetText, .paragraphStyle: paragraph]
	}

	/// Colours every comment in the sheet, so a note reads differently from
	/// the arithmetic beside it.
	static func attributed(_ text: String) -> NSAttributedString {
		let result = NSMutableAttributedString(string: text, attributes: typing)

		var start = 0
		for line in text.components(separatedBy: "\n") {
			let length = (line as NSString).length

			let (code, comment) = Sheet.split(line)
			if comment != nil {
				let offset = (code as NSString).length
				result.addAttribute(.foregroundColor,
									value: PlatformColor.commentColour,
									range: NSRange(location: start + offset, length: length - offset))
			}

			start += length + 1   // past the newline
		}

		return result
	}
}

extension PlatformColor {
	/// Between orange and yellow.
	static var commentColour: PlatformColor {
#if os(macOS)
		NSColor(srgbRed: 0.95, green: 0.71, blue: 0.13, alpha: 1)
#else
		UIColor(red: 0.95, green: 0.71, blue: 0.13, alpha: 1)
#endif
	}

	/// Blue, pulled towards cyan.
	static var resultColour: PlatformColor {
#if os(macOS)
		NSColor(srgbRed: 0.09, green: 0.66, blue: 0.85, alpha: 1)
#else
		UIColor(red: 0.09, green: 0.66, blue: 0.85, alpha: 1)
#endif
	}

	static var sheetText: PlatformColor {
#if os(macOS)
		.labelColor
#else
		.label
#endif
	}
}

/// Works out where each logical line sits, from the same layout the text view
/// is drawn with, so a result can never be level with the wrong line.
enum LineGeometry {
	static func tops(of string: String, manager: NSLayoutManager,
					 container: NSTextContainer) -> [CGFloat] {
		manager.ensureLayout(for: container)

		let text = string as NSString
		var tops: [CGFloat] = []
		var location = 0

		for line in string.components(separatedBy: "\n") {
			let length = (line as NSString).length
			let rect: CGRect

			if length > 0 {
				let glyphs = manager.glyphRange(
					forCharacterRange: NSRange(location: location, length: length),
					actualCharacterRange: nil)
				rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
			} else if location >= text.length {
				rect = manager.extraLineFragmentRect     // the trailing empty line
			} else {
				let glyph = manager.glyphIndexForCharacter(at: location)
				rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
			}

			tops.append(rect.minY)
			location += length + 1
		}

		return tops
	}
}

// MARK: - macOS

#if os(macOS)
/// The sheet, and its results, as one AppKit view.
///
/// One text view rather than a field per line, because a sheet is one piece of
/// text: selection has to run across lines and select all has to mean the
/// sheet. The results are drawn beside it here rather than being positioned by
/// SwiftUI, because handing measured line positions back to SwiftUI to lay out
/// makes it measure again, and the column shakes.
struct SheetTextView: NSViewRepresentable {
	@Binding var text: String
	/// One per logical line, already formatted, nil where a line has no value.
	var results: [String?]
	var columnWidth: CGFloat

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> SheetEditorView {
		let view = SheetEditorView()
		view.columnWidth = columnWidth
		view.textView.delegate = context.coordinator
		view.textView.textStorage?.setAttributedString(LineStyle.attributed(text))
		return view
	}

	func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SheetEditorView,
					  context: Context) -> CGSize? {
		guard let width = proposal.width, width > 0, width < .infinity else { return nil }
		return CGSize(width: width, height: view.height(forWidth: width))
	}

	func updateNSView(_ view: SheetEditorView, context: Context) {
		context.coordinator.parent = self
		view.columnWidth = columnWidth

		if view.textView.string != text {
			let selected = view.textView.selectedRange()
			view.textView.textStorage?.setAttributedString(LineStyle.attributed(text))
			view.textView.setSelectedRange(
				NSRange(location: min(selected.location, (text as NSString).length), length: 0))
		}

		if view.results.results != results {
			view.results.results = results
			view.results.needsDisplay = true
		}
	}

	final class Coordinator: NSObject, NSTextViewDelegate {
		var parent: SheetTextView

		init(_ parent: SheetTextView) { self.parent = parent }

		func textDidChange(_ notification: Notification) {
			guard let view = notification.object as? NSTextView else { return }

			// Typing loses the colouring, so it goes straight back on with the
			// selection where it was.
			let selected = view.selectedRange()
			view.textStorage?.setAttributedString(LineStyle.attributed(view.string))
			view.setSelectedRange(selected)

			parent.text = view.string
			(view.superview as? SheetEditorView)?.results.needsDisplay = true
		}
	}
}

/// The text on the left, the results on the right, sharing one layout.
final class SheetEditorView: NSView {
	let textView = NSTextView()
	let results = ResultsView()

	var columnWidth: CGFloat = 132 { didSet { needsLayout = true } }
	private let gap: CGFloat = 12

	override init(frame: NSRect) {
		super.init(frame: frame)

		textView.isRichText = false
		textView.allowsUndo = true
		textView.drawsBackground = false
		textView.font = LineStyle.font
		textView.textContainerInset = .zero
		textView.textContainer?.lineFragmentPadding = 0
		textView.textContainer?.widthTracksTextView = false
		textView.isVerticallyResizable = false
		textView.isHorizontallyResizable = false
		textView.isAutomaticQuoteSubstitutionEnabled = false
		textView.isAutomaticDashSubstitutionEnabled = false
		textView.isAutomaticTextReplacementEnabled = false
		textView.isAutomaticSpellingCorrectionEnabled = false
		textView.defaultParagraphStyle = LineStyle.paragraph
		textView.typingAttributes = LineStyle.typing

		results.textView = textView

		addSubview(textView)
		addSubview(results)
	}

	required init?(coder: NSCoder) { fatalError("not used") }

	override var isFlipped: Bool { true }

	private func textWidth(in total: CGFloat) -> CGFloat {
		max(total - columnWidth - gap, 80)
	}

	/// How tall the sheet is at this width, which is what SwiftUI asks for.
	func height(forWidth width: CGFloat) -> CGFloat {
		guard let manager = textView.layoutManager, let container = textView.textContainer else {
			return LineStyle.lineHeight
		}

		container.containerSize = NSSize(width: textWidth(in: width), height: .greatestFiniteMagnitude)
		manager.ensureLayout(for: container)

		return max(manager.usedRect(for: container).height, LineStyle.lineHeight)
	}

	override func layout() {
		super.layout()

		let width = textWidth(in: bounds.width)
		textView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
		textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)

		results.frame = NSRect(x: width + gap, y: 0, width: columnWidth, height: bounds.height)
		results.needsDisplay = true
	}
}

/// Draws each result level with the line it belongs to.
final class ResultsView: NSView {
	weak var textView: NSTextView?
	var results: [String?] = []

	override var isFlipped: Bool { true }

	override func draw(_ dirtyRect: NSRect) {
		guard let textView,
			  let manager = textView.layoutManager,
			  let container = textView.textContainer else { return }

		let tops = LineGeometry.tops(of: textView.string, manager: manager, container: container)

		for (index, value) in results.enumerated() {
			guard let value, index < tops.count else { continue }

			let drawn = NSAttributedString(string: value, attributes: [
				.font: LineStyle.resultFont, .foregroundColor: NSColor.resultColour
			])

			let size = drawn.size()
			drawn.draw(at: NSPoint(x: max(bounds.width - size.width, 0), y: tops[index]))
		}
	}
}
#endif

// MARK: - iOS

#if os(iOS)
/// The sheet, and its results, as one UIKit view. The same shape as the Mac
/// side: one text view so selection runs across lines, and the results drawn
/// beside it from the same layout so they cannot drift.
struct SheetTextView: UIViewRepresentable {
	@Binding var text: String
	/// One per logical line, already formatted, nil where a line has no value.
	var results: [String?]
	var columnWidth: CGFloat

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> SheetEditorView {
		let view = SheetEditorView()
		view.columnWidth = columnWidth
		view.textView.delegate = context.coordinator
		view.textView.attributedText = LineStyle.attributed(text)
		return view
	}

	func sizeThatFits(_ proposal: ProposedViewSize, uiView view: SheetEditorView,
					  context: Context) -> CGSize? {
		guard let width = proposal.width, width > 0, width < .infinity else { return nil }
		return CGSize(width: width, height: view.height(forWidth: width))
	}

	func updateUIView(_ view: SheetEditorView, context: Context) {
		context.coordinator.parent = self
		view.columnWidth = columnWidth

		if view.textView.text != text {
			let selected = view.textView.selectedRange
			view.textView.attributedText = LineStyle.attributed(text)
			view.textView.selectedRange = NSRange(
				location: min(selected.location, (text as NSString).length), length: 0)
		}

		if view.results.results != results {
			view.results.results = results
			view.results.setNeedsDisplay()
		}
	}

	final class Coordinator: NSObject, UITextViewDelegate {
		var parent: SheetTextView

		init(_ parent: SheetTextView) { self.parent = parent }

		func textViewDidChange(_ view: UITextView) {
			// Typing loses the colouring, so it goes straight back on with the
			// selection where it was.
			let selected = view.selectedRange
			view.attributedText = LineStyle.attributed(view.text)
			view.selectedRange = selected

			parent.text = view.text
			(view.superview as? SheetEditorView)?.results.setNeedsDisplay()
		}
	}
}

/// The text on the left, the results on the right, sharing one layout.
final class SheetEditorView: UIView {
	// TextKit 1: the results are placed from the layout manager, and asking a
	// TextKit 2 view for one quietly changes how it lays out.
	let textView = UITextView(usingTextLayoutManager: false)
	let results = ResultsView()

	var columnWidth: CGFloat = 132 { didSet { setNeedsLayout() } }
	private let gap: CGFloat = 12

	override init(frame: CGRect) {
		super.init(frame: frame)

		textView.backgroundColor = .clear
		textView.isScrollEnabled = false
		textView.textContainerInset = .zero
		textView.textContainer.lineFragmentPadding = 0
		textView.autocorrectionType = .no
		textView.autocapitalizationType = .none
		textView.spellCheckingType = .no
		textView.font = LineStyle.font
		textView.typingAttributes = LineStyle.typing

		results.textView = textView
		results.backgroundColor = .clear

		addSubview(textView)
		addSubview(results)
	}

	required init?(coder: NSCoder) { fatalError("not used") }

	private func textWidth(in total: CGFloat) -> CGFloat {
		max(total - columnWidth - gap, 80)
	}

	func height(forWidth width: CGFloat) -> CGFloat {
		let fitting = textView.sizeThatFits(
			CGSize(width: textWidth(in: width), height: .greatestFiniteMagnitude))
		return max(fitting.height, LineStyle.lineHeight)
	}

	override func layoutSubviews() {
		super.layoutSubviews()

		let width = textWidth(in: bounds.width)
		textView.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
		results.frame = CGRect(x: width + gap, y: 0, width: columnWidth, height: bounds.height)
		results.setNeedsDisplay()
	}
}

/// Draws each result level with the line it belongs to.
final class ResultsView: UIView {
	weak var textView: UITextView?
	var results: [String?] = []

	override func draw(_ rect: CGRect) {
		guard let textView, let manager = textView.layoutManager as NSLayoutManager? else { return }
		let container = textView.textContainer

		let tops = LineGeometry.tops(of: textView.text, manager: manager, container: container)

		for (index, value) in results.enumerated() {
			guard let value, index < tops.count else { continue }

			let drawn = NSAttributedString(string: value, attributes: [
				.font: LineStyle.resultFont, .foregroundColor: UIColor.resultColour
			])

			let size = drawn.size()
			drawn.draw(at: CGPoint(x: max(bounds.width - size.width, 0), y: tops[index]))
		}
	}
}
#endif
