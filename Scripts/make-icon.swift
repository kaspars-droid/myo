#!/usr/bin/env swift
//
// Draws the icons and writes them where each platform expects them.
//
//   swift Scripts/make-icon.swift        run from the top of the checkout
//
// The mark is a ruled sheet with a plus on it: the notepad this app is, and
// the arithmetic it does to it. Drawing it here rather than shipping PNGs
// someone has to open a paint program to change keeps every size in step and
// keeps the proportions written down as numbers instead of pixels.
//
// Three things come out:
//
//   the iOS app icon    one opaque 1024 square, which the system masks itself
//   the macOS app icon  an .icns, rounded and inset, as macOS icons are
//   the document icon   an .icns for .myocalc files, the mark on a page
//
// An iOS icon may not carry transparency, so that one is drawn into a bitmap
// with the alpha channel skipped rather than merely opaque. CoreGraphics has
// no 24 bit RGB context, and asking AppKit for one hands back nothing to draw
// into, which paints a black square and no warning.
//
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// MARK: - The palette

// Cyan at the top falling to blue at the bottom, the sheet's own result colour
// at either end of it.
let top: (CGFloat, CGFloat, CGFloat) = (0.44, 0.82, 0.89)
let bottom: (CGFloat, CGFloat, CGFloat) = (0.25, 0.51, 0.86)
let paper: (CGFloat, CGFloat, CGFloat) = (0.97, 0.97, 0.98)

// MARK: - Drawing

func context(side: Int, opaque: Bool) -> CGContext? {
	CGContext(data: nil, width: side, height: side,
			  bitsPerComponent: 8, bytesPerRow: 0,
			  space: CGColorSpaceCreateDeviceRGB(),
			  bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast
								  : CGImageAlphaInfo.premultipliedLast).rawValue)
}

/// The mark itself: gradient, faint rules across it, and a plus.
///
/// Everything is a fraction of `rect`, so the same drawing serves a 16 point
/// document icon and a 1024 point app icon without a second set of numbers.
func drawMark(in context: CGContext, rect: CGRect, corner: CGFloat) {
	context.saveGState()

	let shape = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner,
					   transform: nil)
	context.addPath(shape)
	context.clip()

	// The ground.
	let space = CGColorSpaceCreateDeviceRGB()
	if let gradient = CGGradient(colorsSpace: space, colors: [
		CGColor(red: top.0, green: top.1, blue: top.2, alpha: 1),
		CGColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
	] as CFArray, locations: [0, 1]) {
		context.drawLinearGradient(gradient,
								   start: CGPoint(x: rect.minX, y: rect.maxY),
								   end: CGPoint(x: rect.maxX, y: rect.minY),
								   options: [])
	}

	// The rules. Faint, and inset from the edges so they read as a page rather
	// than as stripes.
	let rules = 7
	let inset = rect.width * 0.10
	context.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.16)
	context.setLineWidth(max(rect.width * 0.008, 0.5))

	for line in 1...rules {
		let y = rect.minY + rect.height * (CGFloat(line) / CGFloat(rules + 1))
		context.move(to: CGPoint(x: rect.minX + inset, y: y))
		context.addLine(to: CGPoint(x: rect.maxX - inset, y: y))
	}
	context.strokePath()

	// The plus, with rounded ends, over the middle.
	let arm = rect.width * 0.30
	let thickness = rect.width * 0.125
	let middle = CGPoint(x: rect.midX, y: rect.midY)
	let cap = thickness / 2

	context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
	for bar in [
		CGRect(x: middle.x - arm, y: middle.y - cap, width: arm * 2, height: thickness),
		CGRect(x: middle.x - cap, y: middle.y - arm, width: thickness, height: arm * 2)
	] {
		context.addPath(CGPath(roundedRect: bar, cornerWidth: cap, cornerHeight: cap,
							   transform: nil))
	}
	context.fillPath()

	context.restoreGState()
}

/// A page, for the document icon, with the mark sitting on it.
func drawDocument(in context: CGContext, side: CGFloat) {
	let width = side * 0.72
	let height = side * 0.88
	let page = CGRect(x: (side - width) / 2, y: (side - height) / 2,
					  width: width, height: height)
	let fold = width * 0.26

	// The page, with its top right corner turned down.
	let outline = CGMutablePath()
	outline.move(to: CGPoint(x: page.minX, y: page.minY))
	outline.addLine(to: CGPoint(x: page.maxX, y: page.minY))
	outline.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
	outline.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY))
	outline.addLine(to: CGPoint(x: page.minX, y: page.maxY))
	outline.closeSubpath()

	context.setShadow(offset: CGSize(width: 0, height: -side * 0.006),
					  blur: side * 0.02,
					  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.28))
	context.setFillColor(red: paper.0, green: paper.1, blue: paper.2, alpha: 1)
	context.addPath(outline)
	context.fillPath()
	context.setShadow(offset: .zero, blur: 0, color: nil)

	// The turned corner, darker so it reads as a fold rather than a notch.
	let turned = CGMutablePath()
	turned.move(to: CGPoint(x: page.maxX - fold, y: page.maxY))
	turned.addLine(to: CGPoint(x: page.maxX - fold, y: page.maxY - fold))
	turned.addLine(to: CGPoint(x: page.maxX, y: page.maxY - fold))
	turned.closeSubpath()

	context.setFillColor(red: 0.84, green: 0.85, blue: 0.87, alpha: 1)
	context.addPath(turned)
	context.fillPath()

	// The mark, low on the page, the way a document icon carries its app's.
	let markSide = width * 0.62
	let mark = CGRect(x: page.midX - markSide / 2,
					  y: page.minY + height * 0.12,
					  width: markSide, height: markSide)
	drawMark(in: context, rect: mark, corner: markSide * 0.22)
}

// MARK: - Writing

func write(_ image: CGImage, to url: URL) -> Bool {
	guard let sink = CGImageDestinationCreateWithURL(
		url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }

	CGImageDestinationAddImage(sink, image, nil)
	return CGImageDestinationFinalize(sink)
}

func render(side: Int, opaque: Bool, draw: (CGContext, CGFloat) -> Void) -> CGImage? {
	guard let context = context(side: side, opaque: opaque) else { return nil }

	if opaque {
		// Nothing may show through, and the corners are the system's to round.
		context.setFillColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
		context.fill(CGRect(x: 0, y: 0, width: side, height: side))
	}

	draw(context, CGFloat(side))
	return context.makeImage()
}

func fail(_ message: String) -> Never {
	FileHandle.standardError.write(Data("\(message)\n".utf8))
	exit(1)
}

/// Renders every size an .icns wants and runs iconutil over them.
func writeICNS(named name: String, to folder: URL,
			   draw: @escaping (CGContext, CGFloat) -> Void) {
	let iconset = folder.appendingPathComponent("\(name).iconset")
	try? FileManager.default.removeItem(at: iconset)
	try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

	for points in [16, 32, 128, 256, 512] {
		for scale in [1, 2] {
			let pixels = points * scale
			guard let image = render(side: pixels, opaque: false, draw: draw) else {
				fail("could not draw \(name) at \(pixels)")
			}

			let suffix = scale == 1 ? "" : "@2x"
			let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
			guard write(image, to: file) else { fail("could not write \(file.path)") }
		}
	}

	let iconutil = Process()
	iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
	iconutil.arguments = ["-c", "icns", iconset.path,
						  "-o", folder.appendingPathComponent("\(name).icns").path]
	try? iconutil.run()
	iconutil.waitUntilExit()
	guard iconutil.terminationStatus == 0 else { fail("iconutil failed for \(name)") }

	try? FileManager.default.removeItem(at: iconset)
	print("wrote \(folder.appendingPathComponent("\(name).icns").path)")
}

// MARK: - Run

let icons = URL(fileURLWithPath: "Scripts/Icons")
try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)

// The iOS icon: full bleed and opaque, masked by the system.
guard let phone = render(side: 1024, opaque: true, draw: { context, side in
	drawMark(in: context, rect: CGRect(x: 0, y: 0, width: side, height: side), corner: 0)
}) else { fail("could not draw the iOS icon") }

let phoneIcon = URL(fileURLWithPath: "myo/myo/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
guard write(phone, to: phoneIcon) else { fail("could not write \(phoneIcon.path)") }
print("wrote \(phoneIcon.path)")

// The macOS app icon: inset, and rounded by us rather than by the system.
writeICNS(named: "AppIcon", to: icons) { context, side in
	let inset = side * 0.09
	let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
	drawMark(in: context, rect: rect, corner: rect.width * 0.225)
}

// The document icon, for a .myocalc sheet in the Finder.
writeICNS(named: "Document", to: icons) { context, side in
	drawDocument(in: context, side: side)
}
