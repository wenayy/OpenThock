import Foundation

/// Families of keys that sound alike. Used for fallbacks and per-group gain.
enum KeyGroup: String, CaseIterable, Codable {
    case alpha, number, punctuation, space, enter, backspace, tab, capslock, shift,
         modifier, function, escape, arrow, navigation, numpad, mouse, scroll, other

    /// Keys with stabilizers / long caps, which sound deeper and rattle a bit.
    var isLarge: Bool { [.space, .enter, .backspace, .shift, .tab, .capslock].contains(self) }

    /// Order in which other groups are tried when a pack lacks every key of this group.
    var fallbackChain: [KeyGroup] {
        switch self {
        case .alpha: return [.punctuation, .number]
        case .number: return [.alpha]
        case .punctuation: return [.alpha]
        case .space: return [.shift, .enter, .alpha]
        case .enter: return [.backspace, .shift, .alpha]
        case .backspace: return [.enter, .shift, .alpha]
        case .tab: return [.capslock, .shift, .alpha]
        case .capslock: return [.tab, .shift, .alpha]
        case .shift: return [.enter, .backspace, .modifier, .alpha]
        case .modifier: return [.shift, .alpha]
        case .function: return [.escape, .alpha]
        case .escape: return [.function, .alpha]
        case .arrow: return [.navigation, .alpha]
        case .navigation: return [.arrow, .alpha]
        case .numpad: return [.number, .alpha]
        case .mouse, .scroll: return []
        case .other: return [.alpha]
        }
    }
}

/// One physical key. `id` is the libuiohook / PC set-1 scancode Klack names its files
/// with (e.g. "37" for K, see docs/REVERSE_ENGINEERING.md), so `37-down.wav` is K's press.
struct KeyDef: Identifiable, Hashable {
    let id: String
    let label: String
    let macKeyCodes: [Int]
    let group: KeyGroup
    /// Layout position in key units. Rows 0 (function row) … 5 (space row).
    let row: Int
    let x: Double
    let width: Double
    /// Part of the main Mac keyboard block (vs. the extended nav/numpad clusters).
    let isMainBlock: Bool

    var centerX: Double { x + width / 2 }
    var isModifierLike: Bool { [.modifier, .shift, .capslock].contains(group) }
}

enum KeyMap {
    static let mainBlockWidth = 15.0

    static let all: [KeyDef] = build()
    static let byID: [String: KeyDef] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let byMacKeyCode: [Int: KeyDef] = {
        var map: [Int: KeyDef] = [:]
        for key in all { for code in key.macKeyCodes where map[code] == nil { map[code] = key } }
        return map
    }()

    static let mouseLeft = KeyDef(id: "mouse-left", label: "Left click", macKeyCodes: [], group: .mouse, row: 6, x: 6, width: 1.5, isMainBlock: false)
    static let mouseRight = KeyDef(id: "mouse-right", label: "Right click", macKeyCodes: [], group: .mouse, row: 6, x: 9, width: 1.5, isMainBlock: false)
    static let scroll = KeyDef(id: "scroll", label: "Scroll", macKeyCodes: [], group: .scroll, row: 6, x: 7.5, width: 1.5, isMainBlock: false)
    static let pointer: [KeyDef] = [mouseLeft, mouseRight]

    /// Keys that appear in the visual layout, grouped by row.
    static func rows(includeExtended: Bool) -> [[KeyDef]] {
        (0...5).map { r in
            all.filter { $0.row == r && $0.width > 0 && (includeExtended || $0.isMainBlock) }
                .sorted { $0.x < $1.x }
        }
    }

    /// Stereo position -1 (left) … 1 (right). The main block spans roughly -1…1; the
    /// numpad and nav cluster sit to the right of it and clamp.
    static func pan(for key: KeyDef) -> Double {
        if key.group == .mouse || key.group == .scroll { return 0.35 }
        let p = (key.centerX - mainBlockWidth / 2) / (mainBlockWidth / 2)
        return max(-1, min(1, p))
    }

    /// Media keys (NX_SYSDEFINED, subtype 8) → the F-key they live on, so the top row
    /// makes sound even when F-keys act as media keys.
    static func idForMediaKey(_ nxKeyType: Int) -> String? {
        switch nxKeyType {
        case 3: return "59"          // brightness down → F1
        case 2: return "60"          // brightness up   → F2
        case 22: return "63"         // illumination down → F5
        case 21: return "64"         // illumination up   → F6
        case 18, 20: return "65"     // previous / rewind → F7
        case 16: return "66"         // play             → F8
        case 17, 19: return "67"     // next / fast        → F9
        case 7: return "68"          // mute             → F10
        case 1: return "87"          // volume down      → F11
        case 0: return "88"          // volume up        → F12
        default: return nil
        }
    }

    // MARK: - Table

    private typealias Spec = (label: String, id: Int, mac: [Int], group: KeyGroup, width: Double)

    private static func build() -> [KeyDef] {
        var keys: [KeyDef] = []
        func row(_ r: Int, startX: Double = 0, main: Bool = true, _ specs: [Spec]) {
            var x = startX
            for s in specs {
                keys.append(KeyDef(id: String(s.id), label: s.label, macKeyCodes: s.mac, group: s.group,
                                   row: r, x: x, width: s.width, isMainBlock: main))
                x += s.width
            }
        }
        let fw = 14.0 / 12.0
        row(0, [
            ("esc", 1, [0x35], .escape, 1),
            ("F1", 59, [0x7A], .function, fw), ("F2", 60, [0x78], .function, fw),
            ("F3", 61, [0x63, 0xA0], .function, fw), ("F4", 62, [0x76, 0x83, 0xB1], .function, fw),
            ("F5", 63, [0x60, 0xB0], .function, fw), ("F6", 64, [0x61, 0xB2], .function, fw),
            ("F7", 65, [0x62], .function, fw), ("F8", 66, [0x64], .function, fw),
            ("F9", 67, [0x65], .function, fw), ("F10", 68, [0x6D], .function, fw),
            ("F11", 87, [0x67], .function, fw), ("F12", 88, [0x6F], .function, fw),
        ])
        row(1, [
            ("`", 41, [0x32], .punctuation, 1),
            ("1", 2, [0x12], .number, 1), ("2", 3, [0x13], .number, 1), ("3", 4, [0x14], .number, 1),
            ("4", 5, [0x15], .number, 1), ("5", 6, [0x17], .number, 1), ("6", 7, [0x16], .number, 1),
            ("7", 8, [0x1A], .number, 1), ("8", 9, [0x1C], .number, 1), ("9", 10, [0x19], .number, 1),
            ("0", 11, [0x1D], .number, 1), ("-", 12, [0x1B], .punctuation, 1), ("=", 13, [0x18], .punctuation, 1),
            ("delete", 14, [0x33], .backspace, 2),
        ])
        row(2, [
            ("tab", 15, [0x30], .tab, 1.5),
            ("Q", 16, [0x0C], .alpha, 1), ("W", 17, [0x0D], .alpha, 1), ("E", 18, [0x0E], .alpha, 1),
            ("R", 19, [0x0F], .alpha, 1), ("T", 20, [0x11], .alpha, 1), ("Y", 21, [0x10], .alpha, 1),
            ("U", 22, [0x20], .alpha, 1), ("I", 23, [0x22], .alpha, 1), ("O", 24, [0x1F], .alpha, 1),
            ("P", 25, [0x23], .alpha, 1), ("[", 26, [0x21], .punctuation, 1), ("]", 27, [0x1E], .punctuation, 1),
            ("\\", 43, [0x2A], .punctuation, 1.5),
        ])
        row(3, [
            ("caps", 58, [0x39], .capslock, 1.75),
            ("A", 30, [0x00], .alpha, 1), ("S", 31, [0x01], .alpha, 1), ("D", 32, [0x02], .alpha, 1),
            ("F", 33, [0x03], .alpha, 1), ("G", 34, [0x05], .alpha, 1), ("H", 35, [0x04], .alpha, 1),
            ("J", 36, [0x26], .alpha, 1), ("K", 37, [0x28], .alpha, 1), ("L", 38, [0x25], .alpha, 1),
            (";", 39, [0x29], .punctuation, 1), ("'", 40, [0x27], .punctuation, 1),
            ("return", 28, [0x24], .enter, 2.25),
        ])
        row(4, [
            ("shift", 42, [0x38], .shift, 2.25),
            ("Z", 44, [0x06], .alpha, 1), ("X", 45, [0x07], .alpha, 1), ("C", 46, [0x08], .alpha, 1),
            ("V", 47, [0x09], .alpha, 1), ("B", 48, [0x0B], .alpha, 1), ("N", 49, [0x2D], .alpha, 1),
            ("M", 50, [0x2E], .alpha, 1), (",", 51, [0x2B], .punctuation, 1), (".", 52, [0x2F], .punctuation, 1),
            ("/", 53, [0x2C], .punctuation, 1),
            ("shift", 54, [0x3C], .shift, 2.75),
        ])
        // fn has no libuiohook code; 3683 (0x0E63) is OpenThock's own, unused by uiohook.
        row(5, [
            ("fn", 3683, [0x3F], .modifier, 1), ("control", 29, [0x3B], .modifier, 1),
            ("option", 56, [0x3A], .modifier, 1), ("command", 3675, [0x37], .modifier, 1.25),
            ("", 57, [0x31], .space, 5),
            ("command", 3676, [0x36], .modifier, 1.25), ("option", 3640, [0x3D], .modifier, 1),
            ("←", 57419, [0x7B], .arrow, 0.875), ("↑", 57416, [0x7E], .arrow, 0.875),
            ("↓", 57424, [0x7D], .arrow, 0.875), ("→", 57421, [0x7C], .arrow, 0.875),
        ])

        // Extended keyboard: F13–F15, navigation cluster, numpad.
        row(0, startX: 15.5, main: false, [
            ("F13", 91, [0x69], .function, 1), ("F14", 92, [0x6B], .function, 1), ("F15", 93, [0x71], .function, 1),
        ])
        row(1, startX: 15.5, main: false, [
            ("help", 3666, [0x72], .navigation, 1), ("home", 3655, [0x73], .navigation, 1),
            ("pg up", 3657, [0x74], .navigation, 1),
        ])
        row(2, startX: 15.5, main: false, [
            ("del", 3667, [0x75], .navigation, 1), ("end", 3663, [0x77], .navigation, 1),
            ("pg dn", 3665, [0x79], .navigation, 1),
        ])
        row(1, startX: 19, main: false, [
            ("clear", 69, [0x47], .numpad, 1), ("=", 3597, [0x51], .numpad, 1),
            ("/", 3637, [0x4B], .numpad, 1), ("*", 55, [0x43], .numpad, 1),
        ])
        row(2, startX: 19, main: false, [
            ("7", 71, [0x59], .numpad, 1), ("8", 72, [0x5B], .numpad, 1),
            ("9", 73, [0x5C], .numpad, 1), ("-", 74, [0x4E], .numpad, 1),
        ])
        row(3, startX: 19, main: false, [
            ("4", 75, [0x56], .numpad, 1), ("5", 76, [0x57], .numpad, 1),
            ("6", 77, [0x58], .numpad, 1), ("+", 78, [0x45], .numpad, 1),
        ])
        row(4, startX: 19, main: false, [
            ("1", 79, [0x53], .numpad, 1), ("2", 80, [0x54], .numpad, 1),
            ("3", 81, [0x55], .numpad, 1), ("enter", 3612, [0x4C], .numpad, 1),
        ])
        row(5, startX: 19, main: false, [
            ("0", 82, [0x52], .numpad, 2), (".", 83, [0x41], .numpad, 1),
        ])

        // Keys with no slot in the drawn layout (width 0); they still play sounds.
        func hidden(_ label: String, _ id: Int, _ mac: [Int], _ group: KeyGroup, row r: Int, x: Double) {
            keys.append(KeyDef(id: String(id), label: label, macKeyCodes: mac, group: group,
                               row: r, x: x, width: 0, isMainBlock: false))
        }
        hidden("control", 3613, [0x3E], .modifier, row: 5, x: 13.5)
        hidden("menu", 3677, [0x6E], .modifier, row: 5, x: 13)
        hidden("§", 86, [0x0A], .punctuation, row: 1, x: 0)
        hidden("F16", 99, [0x6A], .function, row: 0, x: 18.5)
        hidden("F17", 100, [0x40], .function, row: 0, x: 19.5)
        hidden("F18", 101, [0x4F], .function, row: 0, x: 20.5)
        hidden("F19", 102, [0x50], .function, row: 0, x: 21.5)
        hidden("F20", 103, [0x5A], .function, row: 0, x: 22.5)
        hidden("¥", 125, [0x5D], .punctuation, row: 1, x: 13)
        hidden("_", 115, [0x5E], .punctuation, row: 4, x: 12)
        hidden(",", 126, [0x5F], .numpad, row: 5, x: 21)
        hidden("英数", 123, [0x66], .modifier, row: 5, x: 3.5)
        hidden("かな", 112, [0x68], .modifier, row: 5, x: 9.5)
        return keys
    }
}
