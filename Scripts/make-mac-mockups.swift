#!/usr/bin/env swift
//
// Puts a rendered panel on a desktop, and that desktop in a laptop.
//
//   swift Scripts/make-mac-mockups.swift AppStore/mac/panels \
//         AppStore/mac/screenshots AppStore/mac/mockups
//
// The panels come from `swift run macshots`, which draws the real view. This
// only supplies what a screenshot of a menu bar app needs around it: a desktop
// to sit on, a bar to hang from, and the icon it dropped out of.
//
// Both outputs are 2880x1800, which is one of the four sizes the Mac App Store
// takes and the only one with room for a 460pt panel at retina scale.
//
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 || arguments.count == 4 else {
	FileHandle.standardError.write(Data(
		"usage: make-mac-mockups.swift <panels> <screenshots out> <mockups out> [closeups]\n".utf8))
	exit(2)
}

let panels = URL(fileURLWithPath: arguments[0])
let flatOut = URL(fileURLWithPath: arguments[1])
let framedOut = URL(fileURLWithPath: arguments[2])
/// Panels drawn larger, to be shown on their own rather than in a laptop.
let closeupsIn = arguments.count == 4 ? URL(fileURLWithPath: arguments[3]) : nil

for folder in [flatOut, framedOut] {
	try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
}

// MARK: - Canvas

let canvasWidth = 2880, canvasHeight = 1800

/// The panel arrives already drawn at some multiple of its 460pt size, and
/// everything else on the desktop is measured in the same points so the bar
/// and the icon stay in proportion with it.
let panelPoints: CGFloat = 460

/// The app's own colours, so the surround belongs to it. Same pair the phone
/// mockups use.
let top = CGColor(red: 0.44, green: 0.82, blue: 0.89, alpha: 1)
let bottom = CGColor(red: 0.25, green: 0.51, blue: 0.86, alpha: 1)

func newContext(width: Int, height: Int) -> CGContext? {
	CGContext(data: nil, width: width, height: height,
			  bitsPerComponent: 8, bytesPerRow: 0,
			  space: CGColorSpaceCreateDeviceRGB(),
			  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
}

func load(_ url: URL) -> CGImage? {
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
	return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func write(_ image: CGImage, to url: URL) -> Bool {
	guard let sink = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
	CGImageDestinationAddImage(sink, image, nil)
	return CGImageDestinationFinalize(sink)
}

/// Text, drawn through AppKit because CoreGraphics on its own has no fonts.
func draw(_ text: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight,
		  colour: NSColor, in context: CGContext, rightAligned: Bool = false) {
	let previous = NSGraphicsContext.current
	NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
	defer { NSGraphicsContext.current = previous }

	let attributes: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: size, weight: weight),
		.foregroundColor: colour
	]
	let string = NSAttributedString(string: text, attributes: attributes)
	let width = string.size().width
	string.draw(at: CGPoint(x: rightAligned ? point.x - width : point.x, y: point.y))
}

/// A block of text that wraps inside a width, drawn from its top left.
func draw(_ text: String, in box: CGRect, size: CGFloat, weight: NSFont.Weight,
		  colour: NSColor, lineHeight: CGFloat, context: CGContext) {
	let previous = NSGraphicsContext.current
	NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
	defer { NSGraphicsContext.current = previous }

	let paragraph = NSMutableParagraphStyle()
	paragraph.alignment = .left
	paragraph.lineHeightMultiple = lineHeight

	NSAttributedString(string: text, attributes: [
		.font: NSFont.systemFont(ofSize: size, weight: weight),
		.foregroundColor: colour,
		.paragraphStyle: paragraph
	]).draw(in: box)
}

/// What each shot is for. Keyed by the sheet's file name so a new sheet only
/// needs a line here; one without gets the laptop and no words.
let headlines: [String: (String, String)] = [
	"01-invoices-vat":    ("Invoice a month\nof work",
						   "VAT added on every line, and the bar along the bottom keeps the total to invoice."),
	"02-car-service":     ("What the job\nreally cost",
						   "Parts and labour down the page, the bill along the bottom."),
	"03-trip-split":      ("Split a trip\nfour ways",
						   "Divide as you go. The bar shows what each of you owes."),
	"04-shopping":        ("A Saturday\nbasket",
						   "Prices as you read them off the receipt, and the bar does the adding."),
	"05-currencies":      ("Every currency\ntotals on its own",
						   "Euros, dollars and kronor in the same list, added up separately."),
	"06-areas":           ("Room by room,\nin square metres",
						   "Multiply as you measure. The bar keeps the running area."),
	"07-renovation":      ("Write it the way\nyou would say it",
						   "Commas, slashes and sizes in the description. The number still comes out."),
	"08-freelance-week":  ("Hours times rate,\nday by day",
						   "A word in the middle of a sum does not stop it."),
	"09-what-it-does":    ("Everything it does,\non one sheet",
						   "Arithmetic, percentages, functions, names, currencies, and a note anywhere you like.")
]

// MARK: - The pieces of a desktop

/// The menu bar's own icon: a rounded square with the plus cleared out of it,
/// the same shape `MenuBarController` builds at 16pt.
func drawMenuBarIcon(centre: CGPoint, side: CGFloat, in context: CGContext) {
	let thickness = side * (2.0 / 16), arm = side * (4.5 / 16)
	let box = CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)

	context.saveGState()
	context.setFillColor(CGColor(gray: 1, alpha: 0.95))
	context.addPath(CGPath(roundedRect: box, cornerWidth: side * (3.5 / 16),
						   cornerHeight: side * (3.5 / 16), transform: nil))
	context.fillPath()

	// Clearing rather than painting leaves the plus a hole, as it is in the app.
	context.setBlendMode(.clear)
	context.fill(CGRect(x: centre.x - arm, y: centre.y - thickness / 2,
						width: arm * 2, height: thickness))
	context.fill(CGRect(x: centre.x - thickness / 2, y: centre.y - arm,
						width: thickness, height: arm * 2))
	context.restoreGState()
}

/// A desktop with the panel open on it. Returns the image and where the panel
/// ended up, which the laptop frame does not need but the caption might.
func desktop(with panel: CGImage) -> CGImage? {
	guard let context = newContext(width: canvasWidth, height: canvasHeight) else { return nil }
	let canvas = CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))
	let scale = CGFloat(panel.width) / panelPoints

	// The wallpaper.
	if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
								 colors: [top, bottom] as CFArray, locations: [0, 1]) {
		context.drawLinearGradient(gradient,
								   start: CGPoint(x: 0, y: canvas.maxY),
								   end: CGPoint(x: canvas.maxX, y: 0), options: [])
	}

	let barHeight: CGFloat = 24 * scale
	let bar = CGRect(x: 0, y: canvas.maxY - barHeight, width: canvas.width, height: barHeight)

	let panelSide = CGFloat(panel.width)
	let panelRect = CGRect(x: canvas.maxX - panelSide - 60 * scale,
						   y: bar.minY - 10 * scale - panelSide,
						   width: panelSide, height: panelSide)
	let corner: CGFloat = 11 * scale

	let iconCentre = CGPoint(x: panelRect.midX, y: bar.midY)

	// What the popover's material does to whatever is behind it. The wallpaper
	// here is a smooth gradient, so darkening stands in for blurring it.
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -6 * scale),
					  blur: 40 * scale,
					  color: CGColor(gray: 0, alpha: 0.45))
	context.setFillColor(CGColor(gray: 0.02, alpha: 0.62))
	context.addPath(CGPath(roundedRect: panelRect, cornerWidth: corner,
						   cornerHeight: corner, transform: nil))
	context.fillPath()
	context.restoreGState()

	// The arrow that ties the panel to the icon it came from.
	let arrowWidth: CGFloat = 22 * scale, arrowHeight: CGFloat = 11 * scale
	let arrow = CGMutablePath()
	arrow.move(to: CGPoint(x: iconCentre.x - arrowWidth / 2, y: panelRect.maxY))
	arrow.addLine(to: CGPoint(x: iconCentre.x, y: panelRect.maxY + arrowHeight))
	arrow.addLine(to: CGPoint(x: iconCentre.x + arrowWidth / 2, y: panelRect.maxY))
	arrow.closeSubpath()
	context.setFillColor(CGColor(gray: 0.02, alpha: 0.62))
	context.addPath(arrow)
	context.fillPath()

	// The panel itself, clipped to the popover's corners.
	context.saveGState()
	context.addPath(CGPath(roundedRect: panelRect, cornerWidth: corner,
						   cornerHeight: corner, transform: nil))
	context.clip()
	context.draw(panel, in: panelRect)
	context.restoreGState()

	// The menu bar goes on last so the panel tucks under it, as it does on screen.
	context.setFillColor(CGColor(gray: 0.05, alpha: 0.55))
	context.fill(bar)

	// The icon is lit while its panel is open.
	let highlight = CGRect(x: iconCentre.x - 14 * scale, y: bar.minY + 2 * scale,
						   width: 28 * scale, height: barHeight - 4 * scale)
	context.setFillColor(CGColor(gray: 1, alpha: 0.22))
	context.addPath(CGPath(roundedRect: highlight, cornerWidth: 5 * scale,
						   cornerHeight: 5 * scale, transform: nil))
	context.fillPath()

	drawMenuBarIcon(centre: iconCentre, side: 16 * scale, in: context)

	draw("Fri 22:04", at: CGPoint(x: canvas.maxX - 18 * scale, y: bar.minY + 6 * scale),
		 size: 13 * scale, weight: .medium, colour: .white, in: context, rightAligned: true)

	return context.makeImage()
}

// MARK: - The laptop

/// The desktop inside a lid, on the same gradient. The frame is drawn rather
/// than composited from a photograph, so the screen keeps the canvas's own
/// proportions instead of being stretched into somebody else's bezel.
func laptop(around screenshot: CGImage, titled headline: (String, String)?) -> CGImage? {
	guard let context = newContext(width: canvasWidth, height: canvasHeight) else { return nil }
	let canvas = CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))

	if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
								 colors: [top, bottom] as CFArray, locations: [0, 1]) {
		context.drawLinearGradient(gradient,
								   start: CGPoint(x: 0, y: canvas.maxY),
								   end: CGPoint(x: canvas.maxX, y: 0), options: [])
	}

	// Words on the left, laptop on the right, running off the edge so the
	// screen stays big enough to read at the size a store lists it.
	if let headline {
		let column = CGRect(x: 150, y: canvas.midY - 300, width: 1080, height: 420)
		draw(headline.0, in: column, size: 104, weight: .bold,
			 colour: .white, lineHeight: 1.06, context: context)

		draw(headline.1, in: CGRect(x: column.minX, y: column.minY - 250, width: 1000, height: 240),
			 size: 46, weight: .regular,
			 colour: NSColor(white: 1, alpha: 0.86), lineHeight: 1.25, context: context)
	}

	let screenWidth = canvas.width * (headline == nil ? 0.74 : 0.52)
	let screenHeight = screenWidth * (CGFloat(canvasHeight) / CGFloat(canvasWidth))
	let bezel = screenWidth * 0.012

	let deckHeight = canvas.height * 0.028
	let stackHeight = screenHeight + bezel * 2 + deckHeight
	let stackBottom = canvas.midY - stackHeight / 2
	// Right up against the edge, but not over it: the panel lives in the top
	// right of the screen and must not be the thing that gets cropped.
	let middle = headline == nil ? canvas.midX : canvas.maxX - 50 - screenWidth / 2

	let screen = CGRect(x: middle - screenWidth / 2,
						y: stackBottom + deckHeight + bezel,
						width: screenWidth, height: screenHeight)
	let lid = screen.insetBy(dx: -bezel, dy: -bezel)
	let lidCorner = screenWidth * 0.014

	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -canvas.height * 0.01),
					  blur: canvas.width * 0.03,
					  color: CGColor(gray: 0, alpha: 0.35))
	context.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
	context.addPath(CGPath(roundedRect: lid, cornerWidth: lidCorner,
						   cornerHeight: lidCorner, transform: nil))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(CGPath(roundedRect: screen, cornerWidth: lidCorner * 0.6,
						   cornerHeight: lidCorner * 0.6, transform: nil))
	context.clip()
	context.draw(screenshot, in: screen)
	context.restoreGState()

	// The deck: a slab a little wider than the lid, with the notch you grip.
	let deck = CGRect(x: middle - screenWidth * 0.56, y: stackBottom,
					  width: screenWidth * 1.12, height: deckHeight)
	context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 1))
	context.addPath(CGPath(roundedRect: deck, cornerWidth: deckHeight * 0.35,
						   cornerHeight: deckHeight * 0.35, transform: nil))
	context.fillPath()

	let notch = CGRect(x: middle - screenWidth * 0.06, y: deck.maxY - deckHeight * 0.34,
					   width: screenWidth * 0.12, height: deckHeight * 0.34)
	context.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))
	context.addPath(CGPath(roundedRect: notch, cornerWidth: deckHeight * 0.17,
						   cornerHeight: deckHeight * 0.17, transform: nil))
	context.fillPath()

	return context.makeImage()
}

/// The panel on its own, big enough to read every line.
///
/// No laptop: a close-up is for showing what the app can do, and a frame
/// around it only makes the thing being shown smaller.
func closeup(with panel: CGImage, titled headline: (String, String)?) -> CGImage? {
	guard let context = newContext(width: canvasWidth, height: canvasHeight) else { return nil }
	let canvas = CGRect(x: 0, y: 0, width: CGFloat(canvasWidth), height: CGFloat(canvasHeight))
	let scale = CGFloat(panel.width) / panelPoints

	if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
								 colors: [top, bottom] as CFArray, locations: [0, 1]) {
		context.drawLinearGradient(gradient,
								   start: CGPoint(x: 0, y: canvas.maxY),
								   end: CGPoint(x: canvas.maxX, y: 0), options: [])
	}

	let side = CGFloat(panel.width)
	let panelRect = CGRect(x: canvas.maxX - side - 150,
						   y: canvas.midY - side / 2,
						   width: side, height: side)
	let corner: CGFloat = 11 * scale

	if let headline {
		let column = CGRect(x: 150, y: canvas.midY - 260, width: 1000, height: 400)
		draw(headline.0, in: column, size: 96, weight: .bold,
			 colour: .white, lineHeight: 1.06, context: context)

		draw(headline.1, in: CGRect(x: column.minX, y: column.minY - 300, width: 980, height: 300),
			 size: 44, weight: .regular,
			 colour: NSColor(white: 1, alpha: 0.86), lineHeight: 1.28, context: context)
	}

	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -10 * scale),
					  blur: 44 * scale,
					  color: CGColor(gray: 0, alpha: 0.45))
	context.setFillColor(CGColor(gray: 0.02, alpha: 0.62))
	context.addPath(CGPath(roundedRect: panelRect, cornerWidth: corner,
						   cornerHeight: corner, transform: nil))
	context.fillPath()
	context.restoreGState()

	context.saveGState()
	context.addPath(CGPath(roundedRect: panelRect, cornerWidth: corner,
						   cornerHeight: corner, transform: nil))
	context.clip()
	context.draw(panel, in: panelRect)
	context.restoreGState()

	return context.makeImage()
}

// MARK: - Run

let sheets = ((try? FileManager.default.contentsOfDirectory(
	at: panels, includingPropertiesForKeys: nil)) ?? [])
	.filter { $0.pathExtension.lowercased() == "png" }
	.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !sheets.isEmpty else {
	FileHandle.standardError.write(Data("no panels in \(panels.path)\n".utf8))
	exit(1)
}

for panel in sheets {
	guard let image = load(panel), let flat = desktop(with: image) else {
		FileHandle.standardError.write(Data("could not compose \(panel.lastPathComponent)\n".utf8))
		continue
	}

	let name = panel.lastPathComponent
	_ = write(flat, to: flatOut.appendingPathComponent(name))

	let key = panel.deletingPathExtension().lastPathComponent

	// A sheet with a close-up drawn for it gets that instead of the laptop:
	// it is there to be read, and a frame would only shrink it.
	if let big = closeupsIn.flatMap({ load($0.appendingPathComponent(name)) }) {
		if let shown = closeup(with: big, titled: headlines[key]) {
			_ = write(shown, to: framedOut.appendingPathComponent(name))
		}
	} else if let framed = laptop(around: flat, titled: headlines[key]) {
		_ = write(framed, to: framedOut.appendingPathComponent(name))
	}

	print("  \(name)  \(canvasWidth)x\(canvasHeight)")
}
