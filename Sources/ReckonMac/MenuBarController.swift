import SwiftUI
import AppKit

/// Owns the icon in the menu bar and the panel that drops from it.
///
/// This is a plain `NSStatusItem` rather than SwiftUI's `MenuBarExtra`, for two
/// reasons: `MenuBarExtra` gives no way to answer a right click, and it insets
/// its panel, which leaves a lighter frame showing around the sheet. A popover
/// hands over its whole content area, so the sheet reaches the edges.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
	private var statusItem: NSStatusItem?
	private let popover = NSPopover()
	private var outsideClick: Any?

	func applicationDidFinishLaunching(_ notification: Notification) {
		let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

		item.button?.image = MenuBarController.icon()
		item.button?.target = self
		item.button?.action = #selector(iconClicked)
		item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

		statusItem = item

		popover.behavior = .transient
		popover.animates = false
		popover.delegate = self
		popover.contentSize = NSSize(width: 460, height: 460)
		popover.contentViewController = NSHostingController(
			rootView: MenuBarPanel(store: SheetStore.shared))
	}

	/// The panel is a window, so closing it leaves none open, and the default
	/// answer to that is to quit. For an app that lives in the menu bar it is
	/// the wrong answer: the icon is still there, so the app still is.
	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
		false
	}

	/// A rounded square with a plus cut out of it, so the plus is a hole rather
	/// than a drawn stroke.
	///
	/// It is a template image: the system fills the solid part to suit the menu
	/// bar it is sitting in, white on a dark bar and black on a light one, and
	/// the hole stays a hole either way.
	private static func icon() -> NSImage {
		let side: CGFloat = 16
		let thickness: CGFloat = 2
		let arm: CGFloat = 4.5     // how far the plus reaches from the centre

		let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
			NSColor.black.setFill()
			NSBezierPath(roundedRect: rect, xRadius: 3.5, yRadius: 3.5).fill()

			// Clearing rather than painting leaves the plus transparent.
			NSGraphicsContext.current?.compositingOperation = .clear

			let middle = side / 2
			NSBezierPath(rect: NSRect(x: middle - arm, y: middle - thickness / 2,
									  width: arm * 2, height: thickness)).fill()
			NSBezierPath(rect: NSRect(x: middle - thickness / 2, y: middle - arm,
									  width: thickness, height: arm * 2)).fill()
			return true
		}

		image.isTemplate = true
		return image
	}

	/// Coming back to the app — clicking its window, or switching to it — is
	/// the other moment the folder may have moved on without us.
	func applicationDidBecomeActive(_ notification: Notification) {
		SheetStore.shared.reloadFromDisk()
	}

	@objc private func iconClicked() {
		if NSApp.currentEvent?.type == .rightMouseUp {
			showMenu()
		} else {
			togglePanel()
		}
	}

	private func togglePanel() {
		guard let button = statusItem?.button else { return }

		if popover.isShown {
			popover.performClose(nil)
		} else {
			// Opening the panel is this app's equivalent of opening the app.
			SheetStore.shared.reloadFromDisk()
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			popover.contentViewController?.view.window?.makeKey()
			watchForClicksElsewhere()
		}
	}

	/// A transient popover closes itself when you click away from it — until a
	/// menu has been opened inside it. The menu runs an event loop of its own,
	/// and the popover's watch for those clicks does not survive it, so the
	/// panel then sits over everything until the icon is clicked again.
	///
	/// This is that watch, kept by hand. A global monitor sees only the clicks
	/// that land in other applications, which is exactly the case the popover
	/// stops noticing; clicks inside this app are still its own business.
	private func watchForClicksElsewhere() {
		stopWatchingForClicksElsewhere()

		outsideClick = NSEvent.addGlobalMonitorForEvents(
			matching: [.leftMouseDown, .rightMouseDown]
		) { [weak self] _ in
			// Global monitors are delivered on the main thread, but a wrong
			// guess about that is a crash rather than a mistake, so this hops
			// rather than asserts.
			Task { @MainActor in self?.popover.performClose(nil) }
		}
	}

	private func stopWatchingForClicksElsewhere() {
		if let outsideClick { NSEvent.removeMonitor(outsideClick) }
		outsideClick = nil
	}

	/// Right click. Attaching the menu and clicking the button is how a status
	/// item is made to show one without losing the left click behaviour.
	private func showMenu() {
		let menu = NSMenu()
		menu.addItem(withTitle: "Quit Myo Calc", action: #selector(quit), keyEquivalent: "q")
			.target = self

		statusItem?.menu = menu
		statusItem?.button?.performClick(nil)
		statusItem?.menu = nil
	}

	@objc private func quit() {
		SheetStore.shared.settleNow()
		NSApp.terminate(nil)
	}
}

extension MenuBarController: NSPopoverDelegate {
	/// However the panel closed — clicked away from, or by the icon — the
	/// watch goes with it.
	func popoverDidClose(_ notification: Notification) {
		stopWatchingForClicksElsewhere()
	}
}
