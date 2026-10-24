import Foundation

/// Keystroke counters, persisted to UserDefaults (Klack has a similar "Stats" tab).
@MainActor
final class Stats: ObservableObject {
    @Published private(set) var today = 0
    @Published private(set) var total = 0
    @Published private(set) var topKey: String?

    private var perKey: [String: Int]
    private var day: String
    private var saveScheduled = false
    private let defaults = UserDefaults.standard

    init() {
        total = defaults.integer(forKey: "stats.total")
        perKey = defaults.dictionary(forKey: "stats.perKey") as? [String: Int] ?? [:]
        day = defaults.string(forKey: "stats.day") ?? Self.dayString()
        today = day == Self.dayString() ? defaults.integer(forKey: "stats.today") : 0
        topKey = perKey.max { $0.value < $1.value }.flatMap { KeyMap.byID[$0.key]?.label }
    }

    func record(_ key: KeyDef) {
        let now = Self.dayString()
        if now != day { day = now; today = 0 }
        today += 1
        total += 1
        perKey[key.id, default: 0] += 1
        if !saveScheduled {
            saveScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.save() }
        }
    }

    func save() {
        saveScheduled = false
        topKey = perKey.max { $0.value < $1.value }.flatMap { KeyMap.byID[$0.key]?.label }
        defaults.set(total, forKey: "stats.total")
        defaults.set(today, forKey: "stats.today")
        defaults.set(day, forKey: "stats.day")
        defaults.set(perKey, forKey: "stats.perKey")
    }

    private static func dayString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
