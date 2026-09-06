import SwiftUI
import UIKit

/// The sheet list, hosted in UIKit rather than built as a SwiftUI `Menu`.
///
/// SwiftUI's menu has no moment it can be told about, and two things needed
/// one. The keyboard has to go down as the menu comes up, or the sheet is left
/// in a strip between the two. And the first tap on a delete has to change what
/// its own row says without closing the menu, so there is somewhere for the
/// second tap to happen.
///
/// UIKit hands over both. A deferred element is asked for its contents every
/// time the menu is shown, which is the opening the keyboard needs; and an
/// action can keep the menu standing after it fires, which is the two taps.
struct SheetMenuButton: UIViewRepresentable {
	@ObservedObject var store: PhoneStore

	func makeCoordinator() -> Coordinator { Coordinator(store: store) }

	func makeUIView(context: Context) -> UIButton {
		let button = UIButton(type: .system)
		button.setImage(UIImage(systemName: "line.3.horizontal",
							    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17)),
						for: .normal)
		button.showsMenuAsPrimaryAction = true

		// A system button tints itself with the accent colour, which made this
		// the one blue thing in a toolbar of plain glyphs. The plus beside it
		// is drawn in the label colour, so this is too.
		button.tintColor = .label
		button.accessibilityLabel = "Switch sheet"

		context.coordinator.button = button
		button.menu = context.coordinator.freshMenu()

		return button
	}

	func updateUIView(_ button: UIButton, context: Context) {
		context.coordinator.store = store
	}

	/// The glyph and nothing more. An AppKit or UIKit view handed to SwiftUI
	/// takes whatever room it is offered unless it says otherwise, and what it
	/// is offered here is the whole toolbar.
	func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIButton,
					  context: Context) -> CGSize? {
		CGSize(width: 28, height: 28)
	}

	@MainActor
	final class Coordinator {
		var store: PhoneStore
		weak var button: UIButton?

		/// The sheet one tap into being deleted, waiting for the second.
		///
		/// A row in a menu is a row a thumb can find by accident, and a delete
		/// has no undo on a phone. The first tap only changes what the row
		/// says: its name becomes a question, in the red a destructive action
		/// is drawn in.
		private var armed: String?
		private var forgetting: Task<Void, Never>?

		init(store: PhoneStore) { self.store = store }

		/// The menu as it is between openings: a deferred element, so that its
		/// contents are worked out at the moment it is shown rather than
		/// whenever the screen was last drawn.
		func freshMenu() -> UIMenu {
			UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] complete in
				guard let self else { return complete([]) }

				// Opening, which is the one moment the keyboard can be sent
				// away without guessing at when it happened.
				self.button?.window?.endEditing(true)

				// And a sheet armed a while ago is not still armed now.
				self.disarm()
				complete(self.elements())
			}])
		}

		private func elements() -> [UIMenuElement] {
			var groups: [UIMenuElement] = [sheets, folderActions]

			guard !store.sheets.isEmpty else { return groups }

			// The second tap is asked for out here rather than inside the
			// submenu, because a submenu closes back to this level the moment
			// anything in it is tapped — so the row that asked the question
			// would be gone by the time there was an answer. Out here it is
			// standing where the finger already is.
			if let armed, store.sheets.contains(armed) {
				groups.append(UIMenu(options: .displayInline, children: [confirm(armed)]))
			} else {
				groups.append(UIMenu(options: .displayInline, children: [deleteMenu]))
			}

			return groups
		}

		private func confirm(_ name: String) -> UIAction {
			UIAction(title: "Delete \(store.displayName(of: name))?",
					 image: UIImage(systemName: "trash.fill"),
					 attributes: [.destructive, .keepsMenuPresented]) { [weak self] _ in
				guard let self else { return }

				self.disarm()
				self.store.remove(name)
				self.button?.menu = self.freshMenu()
			}
		}

		private var sheets: UIMenuElement {
			if store.isFetching, store.sheets.isEmpty {
				return note("Fetching sheets…")
			}
			guard !store.sheets.isEmpty else {
				return note(store.hasChosenFolder ? "No sheets in this folder"
												  : "No folder chosen yet")
			}

			return UIMenu(options: .displayInline, children: store.sheets.map { name in
				UIAction(title: store.displayName(of: name), image: mark(for: name)) {
					[weak self] _ in self?.store.load(name)
				}
			})
		}

		private var folderActions: UIMenuElement {
			UIMenu(options: .displayInline, children: [
				UIAction(title: "Choose Folder…") { [weak self] _ in
					self?.store.isChoosingFolder = true
				},
				UIAction(title: "Add Sheets…") { [weak self] _ in
					self?.store.isAddingSheets = true
				},
			])
		}

		/// Deleting from a menu, which takes a menu of its own.
		///
		/// A row up there does one thing when tapped, and that one thing has to
		/// be open the sheet. So the sheets appear again under here, where
		/// tapping one deletes it instead.
		private var deleteMenu: UIMenu {
			UIMenu(title: "Delete Sheet", image: UIImage(systemName: "trash"),
				   children: store.sheets.map { name in row(for: name) })
		}

		/// Picking a sheet in here does not delete it. It asks, out in the menu
		/// this one hangs off.
		///
		/// The icon says which of the two acts is being asked for. A trash can
		/// for a sheet that will really be deleted; a minus for a linked one,
		/// which is only let go of — the file stays in the Dropbox or Drive
		/// folder it was put in.
		private func row(for name: String) -> UIAction {
			UIAction(title: store.displayName(of: name),
					 image: UIImage(systemName: store.isLinked(name) ? "minus.circle" : "trash"),
					 attributes: [.keepsMenuPresented]) { [weak self] _ in
				self?.arm(name)
			}
		}

		private func arm(_ name: String) {
			armed = name

			// Assembled here and now, rather than left to the deferred element:
			// asking that for its contents again would run the opening above,
			// which disarms the very row just armed.
			button?.menu = UIMenu(children: elements())

			forgetting?.cancel()
			forgetting = Task { [weak self] in
				try? await Task.sleep(for: .seconds(6))
				guard !Task.isCancelled, let self else { return }

				// Back to the deferred menu, so the next opening puts the
				// keyboard away again.
				self.disarm()
				self.button?.menu = self.freshMenu()
			}
		}

		private func disarm() {
			forgetting?.cancel()
			forgetting = nil
			armed = nil
		}

		/// What a row wears: whether it is the sheet on screen, whether it
		/// lives in a cloud of its own, or both at once.
		private func mark(for name: String) -> UIImage? {
			let symbol = switch (name == store.current, store.isLinked(name)) {
			case (true, true): "checkmark.icloud"
			case (true, false): "checkmark"
			case (false, true): "cloud"
			case (false, false): nil as String?
			}
			return symbol.flatMap { UIImage(systemName: $0) }
		}

		/// A line that says something and does nothing.
		private func note(_ text: String) -> UIMenuElement {
			let action = UIAction(title: text) { _ in }
			action.attributes = .disabled
			return action
		}
	}
}
