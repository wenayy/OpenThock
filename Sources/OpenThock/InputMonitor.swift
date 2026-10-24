import AppKit
import CoreGraphics

/// A physical input worth a sound.
enum InputEvent {
    case key(KeyDef, down: Bool)
    case scroll
    case toggleHotkey
}

/// Listen-only CGEventTap on the main run loop. Needs the Input Monitoring permission.
final class InputMonitor {
    /// Called on the main thread with the event and its mach host time.
    var handler: ((InputEvent, UInt64) -> Void)?
    var ignoreSyntheticEvents = true

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var held = Set<String>()
    private var lastScroll: UInt64 = 0

    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    static func requestPermission() {
        if !CGRequestListenEventAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                                    .rightMouseDown, .rightMouseUp, .scrollWheel]
        var mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        mask |= 1 << 14 // NX_SYSDEFINED (media keys)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        held.removeAll()
    }

    // MARK: - Event handling

    private func emit(_ event: InputEvent) { handler?(event, mach_absolute_time()) }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Klack: "Changed to ignore synthetic inputs". Real hardware events carry the
        // HID system state id; posted/synthesized ones don't.
        if ignoreSyntheticEvents,
           event.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue) {
            return
        }

        switch type {
        case .keyDown, .keyUp:
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown, code == 0x28, event.flags.contains([.maskControl, .maskAlternate]),
               !event.flags.contains(.maskCommand) {
                emit(.toggleHotkey)
            }
            guard let key = KeyMap.byMacKeyCode[code] else { return }
            press(key, down: type == .keyDown)

        case .flagsChanged:
            handleModifier(code: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                           flags: event.flags.rawValue)

        case .leftMouseDown, .leftMouseUp:
            press(KeyMap.mouseLeft, down: type == .leftMouseDown)
        case .rightMouseDown, .rightMouseUp:
            press(KeyMap.mouseRight, down: type == .rightMouseDown)

        case .scrollWheel:
            // Only notched wheels tick; trackpads/Magic Mouse scroll continuously.
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return }
            let now = mach_absolute_time()
            guard HostClock.seconds(now &- lastScroll) > 0.025 else { return }
            lastScroll = now
            emit(.scroll)

        default:
            if type.rawValue == 14 { handleSystemDefined(event) }
        }
    }

    private func press(_ key: KeyDef, down: Bool) {
        if down {
            guard held.insert(key.id).inserted else { return }
        } else {
            guard held.remove(key.id) != nil else { return }
        }
        emit(.key(key, down: down))
    }

    /// Device-dependent modifier bits (IOLLEvent.h) tell left from right.
    private static let modifierBits: [Int: UInt64] = [
        0x38: 0x0000_0002, // left shift
        0x3C: 0x0000_0004, // right shift
        0x3B: 0x0000_0001, // left control
        0x3E: 0x0000_2000, // right control
        0x3A: 0x0000_0020, // left option
        0x3D: 0x0000_0040, // right option
        0x37: 0x0000_0008, // left command
        0x36: 0x0000_0010, // right command
        0x3F: 0x0080_0000, // fn
    ]

    private func handleModifier(code: Int, flags: UInt64) {
        guard let key = KeyMap.byMacKeyCode[code] else { return }
        if code == 0x39 {
            // Caps lock reports one flagsChanged per press (toggle), with no release.
            press(key, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in self?.press(key, down: false) }
            return
        }
        let isDown: Bool
        if let bit = Self.modifierBits[code] {
            isDown = flags & bit != 0
        } else {
            isDown = !held.contains(key.id)
        }
        press(key, down: isDown)
    }

    private func handleSystemDefined(_ cgEvent: CGEvent) {
        guard let event = NSEvent(cgEvent: cgEvent), event.subtype.rawValue == 8 else { return }
        let data = event.data1
        let keyType = (data & 0xFFFF_0000) >> 16
        let state = (data & 0xFF00) >> 8
        let isRepeat = data & 0x1 != 0
        guard !isRepeat, state == 0xA || state == 0xB,
              let id = KeyMap.idForMediaKey(keyType), let key = KeyMap.byID[id] else { return }
        press(key, down: state == 0xA)
    }
}

enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}
