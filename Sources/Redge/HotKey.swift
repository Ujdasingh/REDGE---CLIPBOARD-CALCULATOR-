import AppKit
import Carbon.HIToolbox

final class HotKey {
    private static var instances: [UInt32: HotKey] = [:]
    private static var sharedHandler: EventHandlerRef?
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private let id: UInt32
    let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        self.action = action
        HotKey.installSharedHandler()

        let hotKeyID = EventHotKeyID(signature: OSType(0x52454447), id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            print("RegisterEventHotKey failed: \(status)")
            return nil
        }
        HotKey.instances[id] = self
    }

    deinit {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        HotKey.instances.removeValue(forKey: id)
    }

    private static func installSharedHandler() {
        guard sharedHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, eventRef, _) -> OSStatus in
            guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard result == noErr, let instance = HotKey.instances[hotKeyID.id] else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { instance.action() }
            return noErr
        }, 1, &eventType, nil, &sharedHandler)
    }
}
