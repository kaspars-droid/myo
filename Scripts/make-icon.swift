#!/usr/bin/env swift
//
// Draws the app icon and writes it into the asset catalogue.
//
//   swift Scripts/make-icon.swift        run from the top of the checkout
//
// The mark is the one already in the menu bar: a rounded square with a plus
// cut out of it, so the plus is a hole rather than a drawn stroke. Drawing it
// here rather than shipping a PNG someone has to open a paint program to
// change keeps the two in step, and keeps the proportions written down as
// numbers instead of pixels.
//
// An icon may not carry transparency, so the hole is painted in the
// background colour rather than cleared, and the bitmap is made with the
// alpha channel skipped rather than merely opaque. CoreGraphics has no
// 24 bit RGB context, and asking AppKit for one hands back nothing to draw
// into, which paints a black square and no warning.
//
import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

let side = 1024

// The sheet's own ground, and the colour it prints results in.
let ground: (CGFloat, CGFloat, CGFloat) = (0.09, 0.10, 0.12)
let mark: (CGFloat, CGFloat, CGFloat) = (0.09, 0.66, 0.85)

// Proportions taken from MenuBarController.icon(), where the mark is 16 wide
// with a 3.5 corner, a plus reaching 4.5 from the centre and 2 thick.
let markSide = CGFloat(side) * 0.62
let corner = markSide * (3.5 / 16)
let arm = markSide * (4.5 / 16)
let thickness = markSide * (2.0 / 16)

guard let context = CGContext(
	data: nil,
	width: side, height: side,
	bitsPerComponent: 8, bytesPerRow: 0,
	space: CGColorSpaceCreateDeviceRGB(),
	bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
	FileHandle.standardError.write(Data("could not make the drawing context\n".utf8))
	exit(1)
}

context.setFillColor(red: ground.0, green: ground.1, blue: ground.2, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: CGFloat(side), height: CGFloat(side)))

let origin = (CGFloat(side) - markSide) / 2
context.setFillColor(red: mark.0, green: mark.1, blue: mark.2, alpha: 1)
context.addPath(CGPath(
	roundedRect: CGRect(x: origin, y: origin, width: markSide, height: markSide),
	cornerWidth: corner, cornerHeight: corner, transform: nil))
context.fillPath()

// The hole, in the ground colour rather than cleared.
let middle = CGFloat(side) / 2
context.setFillColor(red: ground.0, green: ground.1, blue: ground.2, alpha: 1)
context.fill(CGRect(x: middle - arm, y: middle - thickness / 2,
                    width: arm * 2, height: thickness))
context.fill(CGRect(x: middle - thickness / 2, y: middle - arm,
                    width: thickness, height: arm * 2))

guard let image = context.makeImage() else {
	FileHandle.standardError.write(Data("could not read the drawing back\n".utf8))
	exit(1)
}

let out = URL(fileURLWithPath: "myo/myo/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
guard let sink = CGImageDestinationCreateWithURL(
	out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
	FileHandle.standardError.write(Data("could not open \(out.path)\n".utf8))
	exit(1)
}

CGImageDestinationAddImage(sink, image, nil)
guard CGImageDestinationFinalize(sink) else {
	FileHandle.standardError.write(Data("could not write \(out.path)\n".utf8))
	exit(1)
}

print("wrote \(out.path)")
