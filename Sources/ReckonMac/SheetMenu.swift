import SwiftUI
import AppKit
import ReckonCore
import ReckonUI

/// The list of sheets, hanging off the button in the toolbar and in the menu
/// bar panel.
///
/// Built in AppKit, which SwiftUI's `Menu` would otherwise have done for
/// nothing. The reason is the X on the right of each row: a SwiftUI menu row is
/// one button with one action, and a row that both opens a sheet and deletes it
/// needs two. A menu item can carry a view of its own, and a view can hold as
/// many things as it likes — so the menu is assembled here and the sheet rows
/// are views.
struct SheetMenu: NSViewRepresentable {
	@ObservedObject var store: SheetStore

	/// Opening the window is SwiftUI's to do, so it is handed in.
	var openWindow: () -> Void

	func makeCoordinator() -> Coordinator {
		Coordinator(store: store, openWindow: openWindow)
	}

	func makeNSView(context: Context) -> NSButton {
		let button = NSButton()
		button.isBordered = false
		button.bezelStyle = .regularSquare
		button.imagePosition = .imageOnly
		button.image = NSImage(systemSymbolName: "line.3.horizontal",
							   accessibilityDescription: "Switch sheet")?
			.withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
		button.contentTintColor = NSColor(white: 0.40, alpha: 1)
		button.toolTip = "Switch sheet"
		button.target = context.coordinator
		button.action = #selector(Coordinator.show(_:))

		// An AppKit view handed to SwiftUI takes whatever room it is offered
		// unless it says otherwise, and this one was offered the whole header:
		// the panel's title bar grew to a couple of hundred points and the
		// icon landed on top of the app's name.
		button.setContentHuggingPriority(.required, for: .horizontal)
		button.setContentHuggingPriority(.required, for: .vertical)
		button.setContentCompressionResistancePriority(.required, for: .horizontal)
		button.setContentCompressionResistancePriority(.required, for: .vertical)

		return button
	}

	/// The size of the glyph and nothing more, so it sits beside the plus the
	/// way it did when it was a SwiftUI menu.
	func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSButton,
					  context: Context) -> CGSize? {
		CGSize(width: 19, height: 17)
	}

	func updateNSView(_ button: NSButton, context: Context) {
		context.coordinator.store = store
		context.coordinator.openWindow = openWindow
	}

	@MainActor
	final class Coordinator: NSObject {
		var store: SheetStore
		var openWindow: () -> Void

		init(store: SheetStore, openWindow: @escaping () -> Void) {
			self.store = store
			self.openWindow = openWindow
		}

		@objc func show(_ sender: NSButton) {
			// Built fresh each time, which is also what resets a row that was
			// left one press into deleting itself.
			let menu = build()
			menu.popUp(positioning: nil,
					   at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
		}

		private func build() -> NSMenu {
			let menu = NSMenu()
			menu.autoenablesItems = false

			if store.entries.isEmpty {
				let empty = NSMenuItem(
					title: store.folder == nil ? "No folder chosen yet" : "No sheets in this folder",
					action: nil, keyEquivalent: "")
				empty.isEnabled = false
				menu.addItem(empty)
			} else {
				// One width for every row, so the names line up and the Xs do
				// too. A menu takes its width from the widest thing in it, and
				// rows that each measured themselves would step in and out.
				let width = SheetRow.width(fitting: store.entries.map(\.name))

				for entry in store.entries {
					let item = NSMenuItem()
					item.view = SheetRow(entry: entry,
										 isCurrent: entry.url == store.url,
										 width: width,
										 store: store)
					menu.addItem(item)
				}
			}

			menu.addItem(.separator())
			menu.addItem(plain("Select Folder…", #selector(chooseFolder)))

			// Without a Dock icon or an application menu, these are the only
			// ways left to reach the window or to quit.
			menu.addItem(plain("Open in a Window", #selector(openTheWindow)))

			menu.addItem(.separator())
			let login = plain("Start at Login", #selector(toggleLogin))
			login.state = LoginItem.isEnabled ? .on : .off
			menu.addItem(login)

			menu.addItem(.separator())
			let quit = plain("Quit Myo Calc", #selector(quit))
			quit.keyEquivalent = "q"
			menu.addItem(quit)

			return menu
		}

		private func plain(_ title: String, _ action: Selector) -> NSMenuItem {
			let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
			item.target = self
			return item
		}

		@objc private func chooseFolder() { store.chooseFolder() }
		@objc private func openTheWindow() { openWindow() }
		@objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
		@objc private func quit() { NSApplication.shared.terminate(nil) }
	}
}

/// One sheet in the list: a tick if it is the one on screen, its name, and an X
/// over on the right.
///
/// A menu item with a view of its own draws none of what a menu item usually
/// draws — not the highlight, not the hover, not the text colour that goes with
/// it — so all of that is here.
@MainActor
private final class SheetRow: NSView {
	private let url: URL
	private let name: String
	private let store: SheetStore

	private let label = NSTextField(labelWithString: "")
	private let button = NSButton()

	/// Whether the X has been pressed once, and is now a trash can waiting to
	/// be pressed again.
	///
	/// The whole point of the two presses. An X at the end of every row is
	/// easy to hit while reaching for the row beside it, and a sheet deleted
	/// by a slip is a sheet gone. The first press only changes the picture.
	private var armed = false
	private var hovered = false

	private static let height: CGFloat = 22
	private static let inset: CGFloat = 12
	private static let buttonWidth: CGFloat = 26
	private static var font: NSFont { .menuFont(ofSize: 13) }

	static func width(fitting names: [String]) -> CGFloat {
		let widest = names
			.map { ($0 as NSString).size(withAttributes: [.font: font]).width }
			.max() ?? 0
		return min(max(widest + 130, 200), 420)
	}

	init(entry: SheetEntry, isCurrent: Bool, width: CGFloat, store: SheetStore) {
		self.url = entry.url
		self.name = entry.name
		self.store = store
		super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))

		label.stringValue = (isCurrent ? "✓  " : "     ") + entry.name
		label.font = Self.font
		label.lineBreakMode = .byTruncatingMiddle
		label.frame = NSRect(x: Self.inset, y: 3,
							 width: width - Self.inset - Self.buttonWidth, height: 16)
		addSubview(label)

		button.isBordered = false
		button.bezelStyle = .regularSquare
		button.imagePosition = .imageOnly
		button.frame = NSRect(x: width - Self.buttonWidth, y: 3, width: 18, height: 16)
		button.target = self
		button.action = #selector(press)
		addSubview(button)

		dress()
	}

	required init?(coder: NSCoder) { fatalError("not from a nib") }

	// MARK: - The two presses

	@objc private func press() {
		guard armed else { return arm() }

		enclosingMenuItem?.menu?.cancelTracking()
		store.remove(url)
	}

	private func arm() {
		// One row at a time. Two armed trash cans in a list is two chances to
		// delete the wrong sheet.
		for item in enclosingMenuItem?.menu?.items ?? [] {
			(item.view as? SheetRow)?.disarm()
		}

		armed = true
		dress()
	}

	fileprivate func disarm() {
		guard armed else { return }
		armed = false
		dress()
	}

	private func dress() {
		let symbol = armed ? "trash.fill" : "xmark"
		button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
			.withSymbolConfiguration(.init(pointSize: armed ? 12 : 10, weight: .semibold))
		button.contentTintColor = armed ? .systemRed : .tertiaryLabelColor
		button.toolTip = armed ? "Delete \(name)" : "Delete \(name)…"

		label.textColor = hovered ? .selectedMenuItemTextColor : .labelColor
		needsDisplay = true
	}

	// MARK: - Looking like a menu

	override func updateTrackingAreas() {
		super.updateTrackingAreas()
		for area in trackingAreas { removeTrackingArea(area) }
		addTrackingArea(NSTrackingArea(rect: bounds,
									   options: [.mouseEnteredAndExited, .activeAlways],
									   owner: self))
	}

	override func mouseEntered(with event: NSEvent) {
		hovered = true
		dress()
	}

	override func mouseExited(with event: NSEvent) {
		hovered = false
		// Leaving the row forgets the first press. Coming back to a trash can
		// armed some time ago, on a row nobody remembers arming, is how the
		// wrong sheet goes.
		armed = false
		dress()
	}

	/// A click anywhere but the X opens the sheet. The button is a subview, so
	/// it takes its own clicks before this ever sees them.
	override func mouseUp(with event: NSEvent) {
		enclosingMenuItem?.menu?.cancelTracking()
		if url != store.url { store.load(url) }
	}

	override func draw(_ dirty: NSRect) {
		guard hovered else { return }
		NSColor.selectedContentBackgroundColor.setFill()
		NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 5, yRadius: 5).fill()
	}
}
