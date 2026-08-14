import SwiftUI
import AppKit
import ReckonCore
import ReckonUI

@main
struct MyoApp: App {
	@StateObject private var store = SheetStore.shared

	@NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

	var body: some Scene {
		Window("Myo", id: MyoApp.windowID) {
			SheetView(document: $store.document)
				.frame(minWidth: 460, minHeight: 340)
				.background(CentredTitle())
				.onAppear { store.start() }
				.onChange(of: store.document) { store.scheduleSave() }
				// Dropping DocumentGroup lost "open with Myo"; this restores it.
				.onOpenURL { store.load($0) }
				.toolbar { toolbar }
		}
		.defaultSize(width: 640, height: 520)
		// Launching a menu bar app should put an icon up there and nothing
		// else. The window opens when it is asked for.
		.defaultLaunchBehavior(.suppressed)
	}

	static let windowID = "sheet"

	// MARK: - Window toolbar

	@ToolbarContentBuilder
	private var toolbar: some ToolbarContent {
		if #available(macOS 26.0, *) {
			// Toolbar content sits on a capsule of glass by default. A word is
			// not a button and these icons do not want a second outline, so it
			// comes off both.
			ToolbarItem(placement: .principal) { MyoApp.title }
				.sharedBackgroundVisibility(.hidden)

			ToolbarItemGroup(placement: .primaryAction) { SheetControls(store: store) }
				.sharedBackgroundVisibility(.hidden)
		} else {
			ToolbarItem(placement: .principal) { MyoApp.title }
			ToolbarItemGroup(placement: .primaryAction) { SheetControls(store: store) }
		}
	}

	static var title: some View {
		Text("Myo").font(.headline).foregroundStyle(Palette.label)
	}
}

/// What drops down from the menu bar: the name in the middle, the controls on
/// the right, and the sheet underneath.
struct MenuBarPanel: View {
	@ObservedObject var store: SheetStore

	var body: some View {
		VStack(spacing: 0) {
			ZStack {
				MyoApp.title
					.font(.callout.weight(.semibold))
					.frame(maxWidth: .infinity)

				HStack(spacing: 14) {
					Spacer()
					SheetControls(store: store)
				}
			}
			.padding(.horizontal, 14)
			.padding(.top, 8)
			.padding(.bottom, 2)

			SheetView(document: $store.document)
				.onAppear { store.start() }
				.onChange(of: store.document) { store.scheduleSave() }
		}
		.frame(width: 460, height: 460)
		// The popover hands over its whole content area, so this reaches the
		// edges rather than leaving a lighter frame around the sheet.
		.background(Color.black.opacity(0.30).ignoresSafeArea())
	}
}

/// New sheet, and the list of sheets to switch between. Shared by the window's
/// toolbar and the menu bar panel.
private struct SheetControls: View {
	@ObservedObject var store: SheetStore
	@Environment(\.openWindow) private var openWindow

	var body: some View {
		Button {
			store.newSheet()
		} label: {
			Image(systemName: "plus")
		}
		.buttonStyle(.plain)
		.help("New sheet")

		// A menu rather than a popover: it is what the system uses for a list
		// hanging off a button, and it places itself.
		Menu {
			if store.entries.isEmpty {
				Text(store.folder == nil ? "No folder chosen yet" : "No sheets in this folder")
			} else {
				ForEach(store.entries) { entry in
					Button {
						if entry.url != store.url { store.load(entry.url) }
					} label: {
						if entry.url == store.url {
							Label(entry.name, systemImage: "checkmark")
						} else {
							Text(entry.name)
						}
					}
				}
			}

			Divider()
			Button("Select Folder…") { store.chooseFolder() }

			// Without a Dock icon or an application menu, these are the only
			// ways left to reach the window or to quit.
			Button("Open in a Window") {
				openWindow(id: MyoApp.windowID)
				NSApp.activate(ignoringOtherApps: true)
			}

			Divider()
			Button("Quit Myo") { NSApplication.shared.terminate(nil) }
				.keyboardShortcut("q")
		} label: {
			Image(systemName: "line.3.horizontal")
		}
		.buttonStyle(.plain)
		.help("Switch sheet")
	}
}

/// macOS sets the window title beside the traffic lights. Hiding it and
/// putting the name in the middle of the toolbar puts it in the centre
/// instead, which is the only way to move it.
private struct CentredTitle: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		DispatchQueue.main.async {
			view.window?.titleVisibility = .hidden
		}
		return view
	}

	func updateNSView(_ view: NSView, context: Context) {}
}
