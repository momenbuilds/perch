import Carbon.HIToolbox
import Foundation

/// Global keyboard shortcuts. Carbon hot keys are used deliberately: unlike an event
/// tap they need no Accessibility permission, so the app works the moment it launches.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    /// `key` is a `kVK_*` virtual key code; `modifiers` a Carbon mask such as
    /// `UInt32(controlKey | optionKey)`.
    func register(key: Int, modifiers: UInt32, action: @escaping () -> Void) {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1
        handlers[id] = action

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x50425752), id: id)  // 'PBWR'
        let status = RegisterEventHotKey(UInt32(key), modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            NSLog("Perch: hot key registration failed (\(status)) — probably already taken")
            handlers[id] = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let key = id.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.fire(key) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }
}
