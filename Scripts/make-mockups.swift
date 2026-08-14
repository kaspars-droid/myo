#!/usr/bin/env swift
//
// Puts a screenshot inside a phone, on a background, at App Store size.
//
//   swift Scripts/make-mockups.swift AppStore/screenshots AppStore/mockups
//
// The frame is drawn rather than composited from a picture of a phone: the
// proportions are the screenshot's own, so a shot from any device fills its
// frame exactly instead of being stretched to fit somebody else's bezel.
//
// The output is the same pixel size as the input, which is what the App Store
// checks. The phone is scaled to sit inside that with room around it.
//
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
	FileHandle.standardError.write(Data("usage: make-mockups.swift <in folder> <out folder>\n".utf8))
	exit(2)
}

let input = URL(fileURLWithPath: arguments[0])
let output = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The app's own colours, so the surround belongs to it.
let top: (CGFloat, CGFloat, CGFloat) = (0.44, 0.82, 0.89)
let bottom: (CGFloat, CGFloat, CGFloat) = (0.25, 0.51, 0.86)

/// How much of the canvas height the phone takes.
let phoneShare: CGFloat = 0.84

func load(_ url: URL) -> CGImage? {
	guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
	return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func frame(_ shot: CGImage, into url: URL) -> Bool {
	let width = shot.width, height = shot.height

	guard let context = CGContext(
		data: nil, width: width, height: height,
		bitsPerComponent: 8, bytesPerRow: 0,
		space: CGColorSpaceCreateDeviceRGB(),
		bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
	) else { return false }

	let canvas = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))

	// The ground behind the phone.
	if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
		CGColor(red: top.0, green: top.1, blue: top.2, alpha: 1),
		CGColor(red: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
	] as CFArray, locations: [0, 1]) {
		context.drawLinearGradient(gradient,
								   start: CGPoint(x: 0, y: canvas.maxY),
								   end: CGPoint(x: canvas.maxX, y: 0), options: [])
	}

	// The screen, kept to the screenshot's own proportions.
	let screenHeight = canvas.height * phoneShare
	let screenWidth = screenHeight * (CGFloat(width) / CGFloat(height))
	let bezel = screenWidth * 0.022

	let screen = CGRect(x: canvas.midX - screenWidth / 2,
						y: canvas.midY - screenHeight / 2,
						width: screenWidth, height: screenHeight)
	let body = screen.insetBy(dx: -bezel, dy: -bezel)

	let screenCorner = screenWidth * 0.092
	let bodyCorner = screenCorner + bezel

	// A shadow, so the phone sits on the ground rather than in front of it.
	context.saveGState()
	context.setShadow(offset: CGSize(width: 0, height: -canvas.height * 0.008),
					  blur: canvas.width * 0.035,
					  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
	context.setFillColor(red: 0.06, green: 0.06, blue: 0.07, alpha: 1)
	context.addPath(CGPath(roundedRect: body, cornerWidth: bodyCorner,
						   cornerHeight: bodyCorner, transform: nil))
	context.fillPath()
	context.restoreGState()

	// The rail around the edge, a thin light line that reads as metal.
	context.setStrokeColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1)
	context.setLineWidth(max(bezel * 0.22, 1))
	context.addPath(CGPath(roundedRect: body.insetBy(dx: bezel * 0.1, dy: bezel * 0.1),
						   cornerWidth: bodyCorner, cornerHeight: bodyCorner, transform: nil))
	context.strokePath()

	// The screenshot, clipped to the rounded screen.
	context.saveGState()
	context.addPath(CGPath(roundedRect: screen, cornerWidth: screenCorner,
						   cornerHeight: screenCorner, transform: nil))
	context.clip()
	context.draw(shot, in: screen)
	context.restoreGState()

	guard let image = context.makeImage(),
		  let sink = CGImageDestinationCreateWithURL(
			url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }

	CGImageDestinationAddImage(sink, image, nil)
	return CGImageDestinationFinalize(sink)
}

let shots = ((try? FileManager.default.contentsOfDirectory(at: input,
														   includingPropertiesForKeys: nil)) ?? [])
	.filter { $0.pathExtension.lowercased() == "png" }
	.sorted { $0.lastPathComponent < $1.lastPathComponent }

guard !shots.isEmpty else {
	FileHandle.standardError.write(Data("no screenshots in \(input.path)\n".utf8))
	exit(1)
}

for shot in shots {
	guard let image = load(shot) else {
		FileHandle.standardError.write(Data("could not read \(shot.lastPathComponent)\n".utf8))
		continue
	}

	let destination = output.appendingPathComponent(shot.lastPathComponent)
	if frame(image, into: destination) {
		print("  \(shot.lastPathComponent)  \(image.width)x\(image.height)")
	} else {
		FileHandle.standardError.write(Data("could not write \(destination.path)\n".utf8))
	}
}
