import AppKit
import Carbon.HIToolbox

/// The global shortcuts offered in Settings for opening the panel from anywhere.
enum HotKeyChoice: String, CaseIterable, Identifiable {
    case off
    case controlOptionT
    case controlOptionN
    case controlOptionSpace
    case optionShiftT

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "off"
        case .controlOptionT: return "⌃⌥T"
        case .controlOptionN: return "⌃⌥N"
        case .controlOptionSpace: return "⌃⌥Space"
        case .optionShiftT: return "⌥⇧T"
        }
    }

    fileprivate var keyCode: UInt32? {
        switch self {
        case .off: return nil
        case .controlOptionT, .optionShiftT: return UInt32(kVK_ANSI_T)
        case .controlOptionN: return UInt32(kVK_ANSI_N)
        case .controlOptionSpace: return UInt32(kVK_Space)
        }
    }

    fileprivate var modifiers: UInt32 {
        switch self {
        case .off: return 0
        case .controlOptionT, .controlOptionN, .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .optionShiftT: return UInt32(optionKey | shiftKey)
        }
    }
}

/// Registers one system-wide shortcut. Uses the Carbon hot-key API, which needs no
/// Accessibility permission.
@MainActor
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Switches to another shortcut (or none). Returns false if macOS wouldn't register it,
    /// which usually means another app already owns that combination.
    @discardableResult
    func set(_ choice: HotKeyChoice) -> Bool {
        unregister()
        guard let keyCode = choice.keyCode else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x4E_42_41_52), id: 1)   // 'NBAR'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, choice.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return false }
        hotKeyRef = ref
        return true
    }

    private func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { hotKey.action() }
            }
            return noErr
        }, 1, &spec, pointer, &handlerRef)
    }
}
