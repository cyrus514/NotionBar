import Foundation
import ServiceManagement

/// "Launch at login", through `SMAppService.mainApp`.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var note: String?

    /// Login items only work for a real `.app` bundle, not a bare binary run from the build folder.
    var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    init() {
        refresh()
    }

    func refresh() {
        guard isAvailable else {
            isEnabled = false
            return
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ enabled: Bool) {
        guard isAvailable else {
            note = "build the .app first (./build.sh)"
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            note = nil
        } catch {
            note = error.localizedDescription
        }
        refresh()
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            note = "allow it in System Settings → General → Login Items"
        }
    }

    func toggle() {
        set(!isEnabled)
    }
}
