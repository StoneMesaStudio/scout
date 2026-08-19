import AppKit
import Carbon.HIToolbox

/// Registers system-wide keyboard shortcuts.
///
/// This uses Carbon's `RegisterEventHotKey`, which is old but is still the only way to claim a
/// shortcut without asking for Accessibility permission — and asking for Accessibility just to
/// open a search box would be a bad trade. The modern alternative, a `CGEventTap`, sees every
/// keystroke the user types, which is far more access than this needs.
@MainActor
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var actions: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false

    private init() {}

    /// Claim a shortcut. Returns false if the system refused it — usually because another app
    /// already owns it.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        // 'SCT ' — the four-character signature Carbon uses to tell apps' hotkeys apart.
        let hotKeyID = EventHotKeyID(signature: OSType(0x53435420), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)

        guard status == noErr, let ref else { return false }

        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), scoutHotKeyHandler, 1, &spec, nil, nil)
    }
}

/// Carbon calls this on the main thread, but it is a plain C function pointer and so cannot
/// capture context or carry actor isolation — hence the hop through the shared center.
private let scoutHotKeyHandler: EventHandlerUPP = { _, event, _ in
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }

    MainActor.assumeIsolated {
        HotKeyCenter.shared.fire(id: id.id)
    }
    return noErr
}
