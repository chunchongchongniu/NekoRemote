import Cocoa
import Carbon.HIToolbox
import ApplicationServices

/// Global hotkey listener via CGEventTap.
final class HotkeyTap {
    var onToggle: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onRightDown: (() -> Void)?
    var onRightUp: (() -> Void)?
    var shouldHandle: () -> Bool = { true }

    private var rightHeld = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// True when both Accessibility and Input Monitoring trust are present.
    static func canCreateTap() -> Bool {
        AXIsProcessTrusted() && CGPreflightListenEventAccess()
    }

    func start() {
        // Tab and the arrow keys arrive as keyDown.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<HotkeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.log("EVENTTAP CREATION FAILED")
        NSLog("NekoRemote: event tap creation FAILED")
            return
        }
        self.tap = tap
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = src
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        Logger.log("event tap ready")
        NSLog("NekoRemote: event tap ready")
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            if keyCode == kVK_RightArrow, rightHeld {
                rightHeld = false
                guard shouldHandle() else { return Unmanaged.passUnretained(event) }
                DispatchQueue.main.async { self.onRightUp?() }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        switch keyCode {
        case kVK_Tab:
            guard shouldHandle() else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { self.onToggle?() }
            return nil   // swallow: one action per press
        case kVK_LeftArrow:
            guard shouldHandle() else { return Unmanaged.passUnretained(event) }
            DispatchQueue.main.async { self.onSeekBackward?() }
            return nil
        case kVK_RightArrow:
            guard shouldHandle() else { return Unmanaged.passUnretained(event) }
            if !rightHeld {
                rightHeld = true
                DispatchQueue.main.async { self.onRightDown?() }
            }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}




// MARK: - Right Option via NSEvent (fallback when Carbon is unavailable)
//
// Caps Lock is deliberately not handled: in Mac mode the system consumes short
// presses for input-source switching, so only long presses reach apps, which
// makes it unusable as a toggle. Right Option has no system binding.
final class TabMonitor {
    var onToggle: (() -> Void)?
    var shouldHandle: () -> Bool = { true }
    private var monitor: Any?
    private var isDown = false

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self, event.keyCode == 0x30 else { return }
            if event.type == .keyDown {
                guard !self.isDown else { return }   // autorepeat guard
                self.isDown = true
                guard self.shouldHandle() else { return }
                Logger.log("tab down")
                DispatchQueue.main.async { self.onToggle?() }
            } else {
                self.isDown = false
            }
        }
        Logger.log("tab monitor started: " + String(monitor != nil))
    }
}

// MARK: - Carbon global hotkey (no Input Monitoring needed)

final class CarbonHotkeys {
    var onToggle: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var shouldHandle: () -> Bool = { true }

    private var handlerRef: EventHandlerRef?
    private var tabRef: EventHotKeyRef?
    private var leftRef: EventHotKeyRef?
    private var rightRef: EventHotKeyRef?

    func start() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            let me = Unmanaged<CarbonHotkeys>.fromOpaque(userData).takeUnretainedValue()
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            me.dispatch(hkID.id)
            return noErr
        }, 1, &spec, selfPtr, &handlerRef)

        // Tab (kVK_Tab = 0x30). Carbon delivers a keyDown per press, so no state
        // tracking or debounce is needed. The event tap swallows it when available
        // so the page does not also move focus.
        register(id: 1, key: UInt32(kVK_Tab), mods: 0, ref: &tabRef)
        register(id: 2, key: UInt32(kVK_LeftArrow), mods: 0, ref: &leftRef)
        register(id: 3, key: UInt32(kVK_RightArrow), mods: 0, ref: &rightRef)
        Logger.log("Carbon hotkeys registered")
    }

    private func register(id: UInt32, key: UInt32, mods: UInt32, ref: inout EventHotKeyRef?) {
        let hkID = EventHotKeyID(signature: OSType(0x4E4B524D), id: id)  // 'NKRM'
        let status = RegisterEventHotKey(key, mods, hkID, GetApplicationEventTarget(), 0, &ref)
        Logger.log("RegisterEventHotKey id=\(id) key=\(key) status=\(status)")
    }

    private func dispatch(_ id: UInt32) {
        Logger.log("carbon hotkey fired id=" + String(id) + " gate=" + String(shouldHandle()))
        guard shouldHandle() else { return }
        switch id {
        case 1: DispatchQueue.main.async { self.onToggle?() }
        case 2: DispatchQueue.main.async { self.onSeekBackward?() }
        case 3: DispatchQueue.main.async { self.onSeekForward?() }
        default: break
        }
    }
}
