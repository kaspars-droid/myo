import SwiftUI
import ReckonCore

/// The whole interface: the sheet on the left, its results down the right hand
/// side, and the total of that column along the bottom.
///
/// The sheet is one text view, not a field per line, so selecting, selecting
/// all, and every editing key work the way they do in any editor. The results
/// are laid out beside it using the line positions the text view measures,
/// which is what keeps them level with their lines when one wraps.
public struct SheetView: View {
	@Binding private var document: SheetDocument

	private let sheet: Sheet


	public init(document: Binding<SheetDocument>, locale: Locale = .current) {
		_document = document
		sheet = Sheet(locale: locale)
	}

	public var body: some View {
		let results = sheet.evaluate(document.text)
		let totals = sheet.grandTotal(of: results)
		// The column follows its contents, growing when a wider number turns up.
		let resultColumn = LineStyle.columnWidth(
			for: results.map(\.formatted) + totals.map { sheet.format($0) })

		VStack(spacing: 0) {
			ScrollView {
				// The sheet and its results are one view: they share a layout,
				// which is the only way a result stays level with its line.
				SheetTextView(text: textBinding,
							  results: results.map(\.formatted),
							  columnWidth: resultColumn)
					.frame(maxWidth: .infinity, alignment: .topLeading)
					.padding(20)
			}
			// The sheet measures itself once it is laid out, and a scroll view
			// flashes its bars whenever the content size changes. On a sheet
			// that fits, that reads as a glitch on opening.
			.scrollIndicators(.never)
			.scrollBounceBehavior(.basedOnSize)

			Divider()
			totalBar(for: totals, width: resultColumn)
		}
	}

	// MARK: - The bar along the bottom

	@ViewBuilder
	private func totalBar(for totals: [Quantity], width resultColumn: CGFloat) -> some View {
		HStack(alignment: .firstTextBaseline, spacing: 12) {
			Spacer(minLength: 8)

			if totals.isEmpty {
				Text("—")
					.font(.system(.body, design: .monospaced))
					.foregroundStyle(.tertiary)
					.frame(width: resultColumn, alignment: .trailing)
			} else {
				// One line per currency, since there are no exchange rates.
				VStack(alignment: .trailing, spacing: 2) {
					ForEach(totals.indices, id: \.self) { index in
						Text(sheet.format(totals[index]))
							.font(.system(.body, design: .monospaced).weight(.semibold))
							.foregroundStyle(Palette.label)
							.lineLimit(1)
							.minimumScaleFactor(0.6)
					}
				}
				.frame(width: resultColumn, alignment: .trailing)
				.textSelection(.enabled)
			}
		}
		.padding(.horizontal, 20)
		.padding(.vertical, 10)
		.background(.thinMaterial)
	}

	// MARK: - Editing

	private var textBinding: Binding<String> {
		Binding(
			get: { document.text },
			set: { document.setText($0) }
		)
	}

	public static let sample = """
	# everything after a hash is a note

	rate = 0.21
	net = 1200
	net * rate      # the VAT

	35eur           # oil
	45eur           # filter
	12.50eur
	sum

	120 + 10%
	"""
}

public enum Palette {
	/// Dark gray, for the app's own furniture: its name, and the total of the
	/// result column. Both are labels on the sheet rather than part of it.
	public static let label = Color(white: 0.40)
}
