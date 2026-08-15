//
// Renders the menu bar panel to a PNG, one per sheet.
//
//   swift run macshots AppStore/mac/panels AppStore/sheets/*.myocalc
//
// The panel is the real view from ReckonUI hosted in an offscreen window, not
// a picture of it, so a store shot cannot drift away from what the app draws.
// The background comes out transparent because the panel is translucent over
// whatever is behind it; the compositor puts a desktop there.
//
import AppKit
import SwiftUI
import ReckonCore
import ReckonUI

/// The same arrangement as `MenuBarPanel`: name in the middle, controls on the
/// right, sheet underneath. Kept in step by eye, which is the price of not
/// dragging the app's store of folders and bookmarks into a screenshot tool.
private struct Panel: View {
	@State var document: SheetDocument

	var body: some View {
		VStack(spacing: 0) {
			ZStack {
				Text("Myo Calc")
					.font(.headline)
					.foregroundStyle(Palette.label)
					.frame(maxWidth: .infinity)

				HStack(spacing: 14) {
					Spacer()
					Image(systemName: "plus").font(Palette.controlFont)
					Image(systemName: "line.3.horizontal").font(Palette.controlFont)
				}
				.foregroundStyle(Palette.label)
			}
			.padding(.horizontal, 14)
			.padding(.top, 8)
			.padding(.bottom, 2)

			SheetView(document: $document, locale: Locale(identifier: "en_GB"))
		}
		.frame(width: Shot.side, height: Shot.side)
		.background(Color.black.opacity(0.30))
	}
}

enum Shot {
	/// What `MenuBarController` gives the popover.
	static let side: CGFloat = 460

	/// More than retina. A 460pt panel drawn at 2x is a fifth of a 2880 wide
	/// store shot and unreadable as a thumbnail, so it is drawn larger and the
	/// desktop around it is scaled to match.
	static let scale: CGFloat = 2.75
}

@MainActor
func render(_ text: String, to url: URL) -> Bool {
	let host = NSHostingView(rootView: Panel(document: SheetDocument(text: text)))
	host.frame = NSRect(x: 0, y: 0, width: Shot.side, height: Shot.side)

	// A window the panel is never shown in. Views lay out once they belong to
	// one, and the text view needs that before its lines can be measured.
	let window = NSWindow(contentRect: host.frame,
						  styleMask: [.borderless], backing: .buffered, defer: false)
	window.isOpaque = false
	window.backgroundColor = .clear
	window.appearance = NSAppearance(named: .darkAqua)
	window.contentView = host
	window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))

	host.layoutSubtreeIfNeeded()
	// SwiftUI builds its body on the next turn of the run loop, and the results
	// column waits on the text view's line positions, which is another turn.
	RunLoop.current.run(until: Date().addingTimeInterval(0.4))
	host.layoutSubtreeIfNeeded()

	guard let rep = NSBitmapImageRep(
		bitmapDataPlanes: nil,
		pixelsWide: Int(Shot.side * Shot.scale), pixelsHigh: Int(Shot.side * Shot.scale),
		bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
		colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
	) else { return false }

	// Points, not pixels: cacheDisplay scales the drawing to fill the buffer.
	rep.size = NSSize(width: Shot.side, height: Shot.side)
	host.cacheDisplay(in: host.bounds, to: rep)

	guard let data = rep.representation(using: .png, properties: [:]) else { return false }
	try? data.write(to: url)
	return true
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else {
	FileHandle.standardError.write(Data("usage: macshots <out folder> <sheet>…\n".utf8))
	exit(2)
}

let output = URL(fileURLWithPath: arguments[0])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// An accessory app: no Dock icon, no menu bar of its own, nothing on screen.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

MainActor.assumeIsolated {
	for path in arguments.dropFirst() {
		let source = URL(fileURLWithPath: path)
		guard let text = try? String(contentsOf: source, encoding: .utf8) else {
			FileHandle.standardError.write(Data("could not read \(path)\n".utf8))
			continue
		}

		let name = source.deletingPathExtension().lastPathComponent
		let destination = output.appendingPathComponent(name + ".png")

		if render(text, to: destination) {
			print("  \(name).png")
		} else {
			FileHandle.standardError.write(Data("could not render \(name)\n".utf8))
		}
	}
}
