import XCTest

/// The store shot that has the keyboard in it.
///
/// Nothing in the app takes focus on its own, so the keyboard only appears
/// after a tap, and a tap is beyond `simctl`. The shot is taken from inside
/// the simulator rather than by `simctl io screenshot` from outside, which
/// would be racing the keyboard's rise.
///
///   xcrun simctl boot "iPad Pro 13-inch (M5)"
///   xcrun simctl status_bar <device> override --time 9:41 \
///       --batteryState charged --batteryLevel 100 --wifiBars 3
///   cp AppStore/sheets/10-everything.myocalc \
///       "$(xcrun simctl get_app_container <device> lv.cirsis.myo data)/Documents/Sheets/"
///   xcodebuild test -project myo/myo.xcodeproj -scheme myo \
///       -destination "platform=iOS Simulator,id=<device>" \
///       -only-testing:myoUITests/KeyboardShot/testKeyboardShot
///
/// The picture comes out of the result bundle:
///
///   xcrun xcresulttool export attachments --path <result>.xcresult --output-path .
final class KeyboardShot: XCTestCase {
	func testKeyboardShot() throws {
		let app = XCUIApplication()
		app.launch()

		// A tap inside the sheet puts the caret in it, which is what raises
		// the keyboard: nothing in the app takes focus on its own.
		app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()

		let keyboard = app.keyboards.element
		XCTAssertTrue(keyboard.waitForExistence(timeout: 20), "no software keyboard")

		// Let the keyboard finish rising before the shutter.
		Thread.sleep(forTimeInterval: 2)

		let shot = XCUIScreen.main.screenshot()
		let destination = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("keyboard-shot.png")
		try shot.pngRepresentation.write(to: destination)
		print("KEYBOARD_SHOT_PATH \(destination.path)")

		let attachment = XCTAttachment(screenshot: shot)
		attachment.name = "keyboard-shot"
		// Attachments are thrown away on a passing test unless told otherwise,
		// and a passing test is exactly the one whose picture is wanted.
		attachment.lifetime = .keepAlways
		add(attachment)
	}
}
