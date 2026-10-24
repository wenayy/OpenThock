import CMixer
import Foundation

/// `OpenThock --self-test`: headless checks for the parts that don't need a GUI,
/// permissions or audio hardware.
enum SelfTest {
    static func run() -> Bool {
        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
            if !ok { failures += 1 }
        }

        print("Key map")
        // The soundKey ↔ key pairs observed in Klack's website preview player.
        let klack: [(macKeyCode: Int, soundKey: String)] = [
            (0x28, "37"), (0x25, "38"), (0x00, "30"), (0x08, "46"), (0x31, "57"), (0x23, "25"),
            (0x0F, "19"), (0x0E, "18"), (0x09, "47"), (0x22, "23"), (0x0D, "17"), (0x37, "3675"), (0x24, "28"),
        ]
        check(klack.allSatisfy { KeyMap.byMacKeyCode[$0.macKeyCode]?.id == $0.soundKey },
              "macOS keycodes map to Klack's soundKeys (K→37, ⌘→3675, …)")
        check(Set(KeyMap.all.map(\.id)).count == KeyMap.all.count, "key ids are unique")
        check(KeyMap.rows(includeExtended: false).flatMap { $0 }.count >= 64, "main block has ≥ 64 keys")

        print("Synth")
        let style = Synth.styles[0]
        let e = KeyMap.byID["18"]!, r = KeyMap.byID["19"]!
        let e1 = Synth.keySound(e, style: style, down: true), e2 = Synth.keySound(e, style: style, down: true)
        check(e1 == e2, "same key → identical sound (deterministic)")
        check(e1 != Synth.keySound(r, style: style, down: true), "different keys → different sounds")
        check(e1 != Synth.keySound(e, style: style, down: false), "press and release differ")

        print("Mixer")
        cm_set_output_rate(48_000)
        cm_set_master_gain(1)
        let impulse = [Float](repeating: 0.5, count: 480)
        let id = AudioIO.register(AudioIO.Clip(left: impulse, right: nil, sampleRate: 48_000))
        check(id >= 0, "sample registers")
        var t = cm_trigger_t(sample: id, rate: 1, gainL: 1, gainR: 0, delayL: 0, delayR: 0, shadowL: 0, shadowR: 0)
        cm_trigger(&t)
        var left = [Float](repeating: 0, count: 256), right = [Float](repeating: 0, count: 256)
        cm_render(&left, &right, 256)
        check(left.contains { $0 > 0.1 } && right.allSatisfy { $0 == 0 }, "trigger renders to the panned channel")
        cm_sample_retire(id)
        cm_render(&left, &right, 256)
        check(left.allSatisfy { $0 == 0 }, "retired sample stops immediately")
        cm_collect()

        print("Recorder onset detection")
        let sr = 48_000.0
        var rng = SplitMix64(seed: 7)
        var signal = (0..<Int(sr * 1.4)).map { _ in rng.signed() * 0.001 }
        let downAt = Int(sr * 0.5), upAt = Int(sr * 0.9)
        let pressOnset = downAt + Int(sr * 0.010), releaseOnset = upAt + Int(sr * 0.015)
        for (onset, amp) in [(pressOnset, Float(0.6)), (releaseOnset, Float(0.3))] {
            for i in 0..<Int(sr * 0.05) { signal[onset + i] += amp * exp(-Float(i) / Float(sr * 0.006)) * sin(Float(i) * 0.3) }
        }
        if let take = TakeExtractor.extract(signal, sampleRate: sr, downAt: downAt, upAt: upAt) {
            check(take.up != nil, "finds both press and release")
            check(take.down.count > Int(sr * 0.02) && take.down.count < Int(sr * 0.2), "press clip trimmed to its tail")
        } else {
            check(false, "extracts a take")
        }

        print("Sound bank fallback")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("openthock-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            // A partial pack: only three alpha keys recorded.
            for key in ["30", "31", "32"] {
                let clip = Synth.keySound(KeyMap.byID[key]!, style: style, down: true)
                try AudioIO.writeWAV(clip, sampleRate: sr, to: tmp.appendingPathComponent("\(key)-down.wav"))
            }
            let bank = SoundBank()
            bank.load(PackInfo(url: tmp, manifest: PackManifest()))
            let first = bank.entry(for: "18")?.down
            bank.load(PackInfo(url: tmp, manifest: PackManifest()))
            check(first != nil, "missing key borrows a sibling")
            check(bank.entry(for: "57")?.down != nil, "space falls back across groups")
            let a = bank.entry(for: "30")?.down, s = bank.entry(for: "31")?.down
            check(a != nil && a != s, "recorded keys keep their own sounds")
        } catch {
            check(false, "temp pack: \(error)")
        }

        print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")
        return failures == 0
    }

    /// Renders typed text through the real engine path (bank → player → mixer) to a WAV,
    /// with human-ish timing, so a pack can be auditioned without any permissions.
    static func renderDemo(packID: String, to url: URL) -> Bool {
        Synth.ensureBuiltInPacks()
        PackStore.installBundledPacks()
        guard let pack = PackStore.list().first(where: { $0.id == packID }) else {
            print("No pack '\(packID)'. Available: \(PackStore.list().map(\.id).joined(separator: ", "))")
            return false
        }
        let bank = SoundBank()
        bank.load(pack)
        var player = SoundPlayer()
        player.spatial = .stereo
        cm_set_output_rate(48_000)
        cm_set_master_gain(0.8)

        let text = "the quick brown fox jumps over the lazy dog\nhello world"
        let letters: [Character: String] = Dictionary(uniqueKeysWithValues: KeyMap.all.compactMap { key in
            key.group == .alpha ? (Character(key.label.lowercased()), key.id) : nil
        })
        var events: [(time: Double, key: KeyDef, down: Bool)] = []
        var rng = SplitMix64(seed: 1)
        var t = 0.3
        for ch in text {
            let id = ch == " " ? "57" : ch == "\n" ? "28" : letters[ch]
            guard let id, let key = KeyMap.byID[id] else { continue }
            events.append((t, key, true))
            events.append((t + 0.07 + 0.05 * Double(rng.unit()), key, false))
            t += 0.11 + 0.09 * Double(rng.unit()) + (ch == " " ? 0.05 : 0)
        }
        events.sort { $0.time < $1.time }

        let sr = 48_000.0, block = 256
        var out = [Float]()
        var next = 0
        var left = [Float](repeating: 0, count: block), right = left
        while out.count / 2 < Int((t + 0.8) * sr) {
            let now = Double(out.count / 2) / sr
            while next < events.count, events[next].time <= now {
                let e = events[next]
                if let entry = bank.entry(for: e.key.id), let s = e.down ? entry.down : entry.up {
                    player.trigger(sample: s, key: e.key, gain: bank.packGain * bank.groupGain(e.key.group))
                }
                next += 1
            }
            cm_render(&left, &right, UInt32(block))
            for i in 0..<block { out.append(left[i]); out.append(right[i]) }
        }
        do {
            try AudioIO.writeStereoWAV(interleaved: out, sampleRate: sr, to: url)
            print("Wrote \(url.path) (\(pack.name))")
            return true
        } catch {
            print("Failed: \(error)")
            return false
        }
    }
}
