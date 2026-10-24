import AVFoundation
import CMixer

/// `pack.json` beside the audio files. All fields are optional.
struct PackManifest: Codable {
    var name: String?
    var author: String?
    var license: String?
    var description: String?
    /// Two hex colors for the switch swatch, like Klack's switch metadata.
    var colors: [String]?
    /// Overall gain multiplier for the pack.
    var gain: Double?
    /// Per-group gain, e.g. `{"space": 0.85}` (Klack tones its spacebars down).
    var groupGains: [String: Double]?
    /// Set by the built-in generator so stale synthesized packs are regenerated.
    var generatorVersion: Int?
    /// Set on packs shipped inside the app so updated copies replace installed ones.
    var bundledVersion: Int?
}

struct PackInfo: Identifiable, Hashable {
    let url: URL
    let manifest: PackManifest
    var id: String { url.lastPathComponent }
    var name: String { manifest.name ?? url.lastPathComponent }
    var colors: [String] { manifest.colors ?? ["#d6d3d1", "#78716c"] }

    static func == (a: PackInfo, b: PackInfo) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

enum PackStore {
    static let audioExtensions = ["wav", "aif", "aiff", "caf", "m4a", "mp3", "flac"]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("OpenThock/Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Packs shipped with the app: `Contents/Resources/Packs` in the .app, or `./Packs`
    /// in the repo when running a debug build.
    static var bundledDirectory: URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Packs"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Packs"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Copies bundled packs into the user's packs folder when missing or outdated.
    static func installBundledPacks() {
        guard let source = bundledDirectory,
              let dirs = try? FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else { return }
        for dir in dirs {
            guard let bundled = readManifest(at: dir)?.bundledVersion else { continue }
            let dest = directory.appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            if readManifest(at: dest)?.bundledVersion == bundled { continue }
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: dir, to: dest)
        }
    }

    static func readManifest(at dir: URL) -> PackManifest? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("pack.json")) else { return nil }
        return try? JSONDecoder().decode(PackManifest.self, from: data)
    }

    static func writeManifest(_ manifest: PackManifest, to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: dir.appendingPathComponent("pack.json"))
    }

    static func list() -> [PackInfo] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.compactMap { dir -> PackInfo? in
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !dir.lastPathComponent.hasPrefix(".") else { return nil }
            return PackInfo(url: dir, manifest: readManifest(at: dir) ?? PackManifest())
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Finds `<id>-down.*` / `<id>-up.*` files. Returns `[id: (down, up)]`.
    static func scanFiles(in dir: URL) -> [String: (down: URL?, up: URL?)] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var result: [String: (down: URL?, up: URL?)] = [:]
        for file in files where audioExtensions.contains(file.pathExtension.lowercased()) {
            let stem = file.deletingPathExtension().lastPathComponent
            if stem.hasSuffix("-down") {
                let id = String(stem.dropLast(5))
                result[id, default: (nil, nil)].down = file
            } else if stem.hasSuffix("-up") {
                let id = String(stem.dropLast(3))
                result[id, default: (nil, nil)].up = file
            } else if stem == "ding" {
                result["ding", default: (nil, nil)].down = file
            }
        }
        return result
    }
}

enum AudioIO {
    struct Clip {
        var left: [Float]
        var right: [Float]?
        var sampleRate: Double
    }

    static func read(_ url: URL) throws -> Clip {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let n = Int(buffer.frameLength)
        let left = Array(UnsafeBufferPointer(start: data[0], count: n))
        let right = format.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : nil
        return Clip(left: left, right: right, sampleRate: format.sampleRate)
    }

    /// Writes a mono 24-bit WAV.
    static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }

    static func writeStereoWAV(interleaved: [Float], sampleRate: Double, to url: URL) throws {
        let frames = interleaved.count / 2
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let data = buffer.floatChannelData else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            data[0][i] = interleaved[2 * i]
            data[1][i] = interleaved[2 * i + 1]
        }
        try file.write(from: buffer)
    }

    static func register(_ clip: Clip) -> Int32 {
        clip.left.withUnsafeBufferPointer { l in
            if let right = clip.right {
                return right.withUnsafeBufferPointer { r in
                    cm_sample_add(l.baseAddress, r.baseAddress, UInt32(clip.left.count), clip.sampleRate)
                }
            }
            return cm_sample_add(l.baseAddress, nil, UInt32(clip.left.count), clip.sampleRate)
        }
    }
}

/// The currently loaded pack, resolved to mixer sample ids for every key.
final class SoundBank {
    struct Entry { var down: Int32?; var up: Int32? }

    private(set) var pack: PackInfo?
    private(set) var entries: [String: Entry] = [:]
    private(set) var ding: Int32?
    private var ownedSamples: [Int32] = []
    /// Built-in mouse / scroll / ding sounds used when a pack lacks them.
    private var shared: [String: Entry] = [:]

    init() {
        for (id, clip) in Synth.sharedSounds() {
            let sample = AudioIO.register(AudioIO.Clip(left: clip, right: nil, sampleRate: Synth.sampleRate))
            guard sample >= 0 else { continue }
            let parts = id.split(separator: "|").map(String.init)
            if parts[1] == "down" { shared[parts[0], default: Entry()].down = sample } else { shared[parts[0], default: Entry()].up = sample }
        }
    }

    func entry(for id: String) -> Entry? { entries[id] ?? shared[id] }
    func sharedDing(_ style: DingStyle) -> Int32? { shared["ding-\(style.rawValue)"]?.down }

    func groupGain(_ group: KeyGroup) -> Float {
        Float(pack?.manifest.groupGains?[group.rawValue] ?? 1)
    }

    var packGain: Float { Float(pack?.manifest.gain ?? 1) }

    func load(_ newPack: PackInfo) {
        let files = PackStore.scanFiles(in: newPack.url)
        var cache: [URL: Int32] = [:]
        var newOwned: [Int32] = []
        func sample(_ url: URL?) -> Int32? {
            guard let url else { return nil }
            if let id = cache[url] { return id }
            guard let clip = try? AudioIO.read(url) else { return nil }
            let id = AudioIO.register(clip)
            guard id >= 0 else { return nil }
            cache[url] = id
            newOwned.append(id)
            return id
        }

        var direct: [String: Entry] = [:]
        for (id, urls) in files {
            direct[id] = Entry(down: sample(urls.down), up: sample(urls.up))
        }
        let newDing = direct.removeValue(forKey: "ding")?.down

        var resolved: [String: Entry] = [:]
        for key in KeyMap.all + KeyMap.pointer {
            var entry = direct[key.id] ?? Entry()
            if entry.down == nil { entry.down = Self.fallback(for: key, in: direct, \.down) }
            if entry.up == nil { entry.up = Self.fallback(for: key, in: direct, \.up) }
            if entry.down != nil || entry.up != nil { resolved[key.id] = entry }
        }
        // Mouse sounds only come from the pack if it actually has them.
        for key in KeyMap.pointer where direct[key.id] == nil { resolved.removeValue(forKey: key.id) }
        if let scroll = direct["scroll"] { resolved["scroll"] = scroll }

        let old = ownedSamples
        pack = newPack
        entries = resolved
        ding = newDing
        ownedSamples = newOwned
        old.forEach { cm_sample_retire($0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { cm_collect() }
    }

    /// A missing key borrows a sibling's sound. The sibling is chosen with a stable hash,
    /// so the same key always gets the same borrowed sound, never a random one.
    private static func fallback(for key: KeyDef, in direct: [String: Entry], _ path: KeyPath<Entry, Int32?>) -> Int32? {
        guard key.group != .mouse, key.group != .scroll else { return nil }
        for group in [key.group] + key.group.fallbackChain {
            let candidates = KeyMap.all
                .filter { $0.group == group && direct[$0.id]?[keyPath: path] != nil }
                .map(\.id)
                .sorted()
            if !candidates.isEmpty {
                let pick = candidates[Int(StableHash.fnv1a(key.id) % UInt64(candidates.count))]
                return direct[pick]?[keyPath: path]
            }
        }
        return direct.values.compactMap { $0[keyPath: path] }.min()
    }
}

enum StableHash {
    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
