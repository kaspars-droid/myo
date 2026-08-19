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
	/// The face a sheet is written in.
	///
	/// Not the monospaced system font, which draws a caron as a hairline that
	/// never takes a whole pixel at this size: in a sheet written in Latvian
	/// the top half of every š, ž and č comes out greyer than the letter under
	/// it, as though the accent were a shade of the text rather than part of
	/// it. Raising the size or the weight does not fix it — the mark stays
	/// thin at every size the app would use.
	///
	/// Menlo draws the mark at the weight of the letter it belongs to, ships
	/// with both macOS and iOS so the two apps stay in step, and is close
	/// enough in proportion that nothing else about the sheet moves.
	static var font: PlatformFont {
		named("Menlo-Regular")
			?? .monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .regular)
	}

	/// A system font is asked for by weight and a bundled one by name, so the
	/// fallback is what keeps the sheet readable on a machine without Menlo
	/// rather than a face nobody chose.
	private static func named(_ name: String) -> PlatformFont? {
		PlatformFont(name: name, size: PlatformFont.systemFontSize)
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

	/// Results are the same size as the sheet, a little heavier. Menlo has no
	/// medium, so the step up is to its bold.
	static var resultFont: PlatformFont {
		named("Menlo-Bold")
			?? .monospacedSystemFont(ofSize: PlatformFont.systemFontSize, weight: .medium)
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

	/// Colours the sheet: notes in orange, and the names a sheet gives its
	/// figures in green, both where a name is defined and everywhere it is
	/// read. A name is the one word on a line that means something elsewhere
	/// in the sheet, so it is worth being able to pick out at a glance.
	static func attributed(_ text: String, sheet: Sheet) -> NSAttributedString {
		let result = NSMutableAttributedString(string: text, attributes: typing)
		let length = (text as NSString).length

		for span in sheet.names(in: text) where NSMaxRange(span.range) <= length {
			result.addAttribute(.foregroundColor, value: PlatformColor.nameColour,
								range: span.range)
		}

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

	/// Green. The results down the right are blue, so a name has to be its own
	/// colour rather than theirs: a name and the figure it stands for are two
	/// different things and sit in two different columns.
	static var nameColour: PlatformColor {
#if os(macOS)
		NSColor(srgbRed: 0.30, green: 0.66, blue: 0.36, alpha: 1)
#else
		UIColor(red: 0.30, green: 0.66, blue: 0.36, alpha: 1)
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
	/// The same engine the results came from, so the colouring agrees with
	/// them about which words are names.
	var sheet: Sheet

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeNSView(context: Context) -> SheetEditorView {
		let view = SheetEditorView()
		view.columnWidth = columnWidth
		view.sheet = sheet
		view.textView.delegate = context.coordinator
		view.show(text)
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
		view.sheet = sheet

		if view.textView.string != text { view.show(text) }

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
			view.textStorage?.setAttributedString(
				LineStyle.attributed(view.string, sheet: parent.sheet))
			view.setSelectedRange(selected)

			parent.text = view.string

			let editor = view.superview as? SheetEditorView
			editor?.results.needsDisplay = true
			editor?.revealCaret()
		}
	}
}

/// The text on the left, the results on the right, sharing one layout.
final class SheetEditorView: NSView {
	let textView = NSTextView()
	let results = ResultsView()

	var sheet = Sheet()
	var columnWidth: CGFloat = 132 { didSet { needsLayout = true } }
	private let gap: CGFloat = 12
	/// A caret to bring into sight once this view has a window to do it in.
	private var caretIsWaiting = false

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

	/// Puts a sheet on screen: a different one opened, or this one changed on
	/// disk. Either way the text arrived from outside rather than being typed
	/// here, so the caret goes where you would carry on from — the end of the
	/// last line — instead of wherever it happened to be in the sheet before.
	func show(_ text: String) {
		textView.textStorage?.setAttributedString(LineStyle.attributed(text, sheet: sheet))
		textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
		revealCaret()
	}

	/// Brings the caret back into sight.
	///
	/// The text view does not scroll: it is laid out at its full height and
	/// SwiftUI's scroll view is what moves. AppKit's own reveal, on the keypress
	/// itself, is therefore too early — the sheet is still the height it was, so
	/// a return typed at the bottom of a full window puts the new line past the
	/// end of the scrolled content, behind the total bar. This asks again once
	/// the sheet has been measured and laid out at its new height.
	func revealCaret() {
		DispatchQueue.main.async { [weak self] in self?.showCaret() }
	}

	private func showCaret() {
		// A sheet opened before its window is on screen — the panel's, every
		// time it is put together — has nothing to scroll yet, so the ask is
		// kept until there is.
		guard let window else {
			caretIsWaiting = true
			return
		}

		window.layoutIfNeeded()
		guard let caret = caretRect() else { return }

		// A line of air, so the caret is never flush against the bar.
		scrollToVisible(caret.insetBy(dx: 0, dy: -LineStyle.lineHeight))
	}

	/// Where the caret is, in this view's coordinates.
	private func caretRect() -> NSRect? {
		guard let manager = textView.layoutManager, let container = textView.textContainer else {
			return nil
		}

		manager.ensureLayout(for: container)

		let text = textView.string as NSString
		let location = min(textView.selectedRange().location, text.length)
		let rect: NSRect

		if text.length == 0 {
			rect = NSRect(x: 0, y: 0, width: 1, height: LineStyle.lineHeight)
		} else if location >= text.length, manager.extraLineFragmentTextContainer != nil {
			rect = manager.extraLineFragmentRect            // the empty line at the end
		} else {
			let glyph = manager.glyphIndexForCharacter(at: min(location, text.length - 1))
			rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
		}

		return convert(rect, from: textView)
	}

	override func layout() {
		super.layout()

		let width = textWidth(in: bounds.width)
		textView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
		textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)

		results.frame = NSRect(x: width + gap, y: 0, width: columnWidth, height: bounds.height)
		results.needsDisplay = true

		if caretIsWaiting, window != nil {
			caretIsWaiting = false
			revealCaret()      // after this layout, not during it
		}
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
	/// The same engine the results came from, so the colouring agrees with
	/// them about which words are names.
	var sheet: Sheet

	func makeCoordinator() -> Coordinator { Coordinator(self) }

	func makeUIView(context: Context) -> SheetEditorView {
		let view = SheetEditorView()
		view.columnWidth = columnWidth
		view.sheet = sheet
		view.textView.delegate = context.coordinator
		view.show(text)
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
		view.sheet = sheet

		if view.textView.text != text { view.show(text) }

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
			view.attributedText = LineStyle.attributed(view.text, sheet: parent.sheet)
			view.selectedRange = selected

			parent.text = view.text

			let editor = view.superview as? SheetEditorView
			editor?.results.setNeedsDisplay()
			editor?.revealCaret()
		}
	}
}

/// The text on the left, the results on the right, sharing one layout.
final class SheetEditorView: UIView {
	// TextKit 1: the results are placed from the layout manager, and asking a
	// TextKit 2 view for one quietly changes how it lays out.
	let textView = UITextView(usingTextLayoutManager: false)
	let results = ResultsView()

	var sheet = Sheet()
	var columnWidth: CGFloat = 132 { didSet { setNeedsLayout() } }
	private let gap: CGFloat = 12
	/// A caret to bring into sight once this view is on screen.
	private var caretIsWaiting = false

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

	/// Puts a sheet on screen: a different one opened, or this one changed on
	/// disk. Either way the text arrived from outside rather than being typed
	/// here, so the caret goes where you would carry on from — the end of the
	/// last line — instead of wherever it happened to be in the sheet before.
	func show(_ text: String) {
		textView.attributedText = LineStyle.attributed(text, sheet: sheet)
		textView.selectedRange = NSRange(location: (text as NSString).length, length: 0)
		revealCaret()
	}

	/// Brings the caret back into sight.
	///
	/// The text view does not scroll: it is laid out at its full height and
	/// SwiftUI's scroll view is what moves. So the usual reveal, on the keypress
	/// itself, is too early — the sheet is still the height it was, and a return
	/// typed at the bottom of a full screen puts the new line past the end of
	/// the scrolled content, behind the total bar. This asks again once the
	/// sheet has been measured and laid out at its new height.
	func revealCaret() {
		DispatchQueue.main.async { [weak self] in self?.showCaret() }
	}

	private func showCaret() {
		// A sheet opened before its view is on screen has nothing to scroll
		// yet, so the ask is kept until there is.
		guard let window else {
			caretIsWaiting = true
			return
		}

		window.layoutIfNeeded()

		var view: UIView? = superview
		while let next = view, !(next is UIScrollView) { view = next.superview }
		guard let scroll = view as? UIScrollView, let caret = caretRect() else { return }

		// A line of air, so the caret is never flush against the bar.
		scroll.scrollRectToVisible(
			scroll.convert(caret, from: self).insetBy(dx: 0, dy: -LineStyle.lineHeight),
			animated: false)
	}

	/// Where the caret is, in this view's coordinates.
	private func caretRect() -> CGRect? {
		guard let manager = textView.layoutManager as NSLayoutManager? else { return nil }
		let container = textView.textContainer
		manager.ensureLayout(for: container)

		let text = textView.text as NSString
		let location = min(textView.selectedRange.location, text.length)
		let rect: CGRect

		if text.length == 0 {
			rect = CGRect(x: 0, y: 0, width: 1, height: LineStyle.lineHeight)
		} else if location >= text.length, manager.extraLineFragmentTextContainer != nil {
			rect = manager.extraLineFragmentRect            // the empty line at the end
		} else {
			let glyph = manager.glyphIndexForCharacter(at: min(location, text.length - 1))
			rect = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
		}

		return convert(rect, from: textView)
	}

	override func layoutSubviews() {
		super.layoutSubviews()

		let width = textWidth(in: bounds.width)
		textView.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
		results.frame = CGRect(x: width + gap, y: 0, width: columnWidth, height: bounds.height)
		results.setNeedsDisplay()

		if caretIsWaiting, window != nil {
			caretIsWaiting = false
			revealCaret()      // after this layout, not during it
		}
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
