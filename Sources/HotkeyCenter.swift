import AppKit
import Carbon

/// System-wide keyboard shortcut (Carbon hot key) used to stop the active
/// recording. Registered only while recording, so the key combination is
/// consumed globally only then — even when another app is focused.
final class HotkeyCenter {

    /// Default: Escape, no modifiers.
    static let defaultKeyCode: UInt32 = 53   // kVK_Escape
    static let defaultModifiers: UInt32 = 0

    fileprivate static let signature: OSType = 0x6D535263   // 'MSRc'

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerInstalled = false

    var isRegistered: Bool { hotKeyRef != nil }

    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        unregister()
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let err = RegisterEventHotKey(keyCode, carbonModifiers, id,
                                      GetApplicationEventTarget(), 0, &ref)
        if err == noErr, let ref {
            hotKeyRef = ref
            return true
        }
        return false
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyEventHandler, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }
}

// MARK: - Event handler

private let hotkeyEventHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID)
    guard err == noErr, hotKeyID.signature == HotkeyCenter.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { center.onTrigger?() }
    return noErr
}

// MARK: - Names & validation

extension HotkeyCenter {

    /// Maps NSEvent modifiers to Carbon hot key modifier bits.
    static func carbonFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Valid stop hotkeys: Esc, a bare function key, or any key with at least
    /// one of ⌘/⌥/⌃/⇧. (Unmodified plain keys are rejected so recording-time
    /// typing elsewhere never stops the recording.)
    static func isValidStopHotkey(keyCode: UInt32, carbonModifiers: UInt32) -> Bool {
        if keyCode == defaultKeyCode { return true }
        if functionKeyNames[keyCode] != nil { return true }
        return carbonModifiers != 0
    }

    static func displayName(keyCode: UInt32, carbonModifiers: UInt32) -> String {
        var name = ""
        if carbonModifiers & UInt32(cmdKey) != 0 { name += "⌘" }
        if carbonModifiers & UInt32(optionKey) != 0 { name += "⌥" }
        if carbonModifiers & UInt32(controlKey) != 0 { name += "⌃" }
        if carbonModifiers & UInt32(shiftKey) != 0 { name += "⇧" }
        return name + keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        if let fn = functionKeyNames[keyCode] { return fn }
        if let named = specialKeyNames[keyCode] { return named }
        if let char = characterKeyNames[keyCode] { return char }
        return "key \(keyCode)"
    }

    private static let functionKeyNames: [UInt32: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
        107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    private static let specialKeyNames: [UInt32: String] = [
        36: "return", 48: "tab", 49: "space", 51: "delete", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static let characterKeyNames: [UInt32: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c",
        9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[",
        34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 50: "`",
    ]
}
