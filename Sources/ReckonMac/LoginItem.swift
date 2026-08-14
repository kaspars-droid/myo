import AppKit
import ServiceManagement

/// Whether the app starts itself when you log in.
///
/// `SMAppService` registers the bundle with the system rather than writing a
/// launch agent, so it appears in System Settings under Login Items where it
/// can be turned off without coming back here.
enum LoginItem {
	static var isEnabled: Bool {
		SMAppService.mainApp.status == .enabled
	}

	static func setEnabled(_ enabled: Bool) {
		do {
			if enabled {
				try SMAppService.mainApp.register()
			} else {
				try SMAppService.mainApp.unregister()
			}
		} catch {
			// Registering fails for an app that is not where it will stay —
			// running from a build folder, say. Nothing to do but leave the
			// switch as the system reports it.
			NSSound.beep()
		}
	}
}
