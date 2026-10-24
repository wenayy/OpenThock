import AppKit

/// Converts a Mechvibes pack (config.json + audio) to OpenThock's layout. Mechvibes keys
/// use the same libuiohook codes Klack does, so the mapping is direct.
/// Note: macOS can't decode Ogg Vorbis, so only wav/mp3/m4a/flac packs import.
enum MechvibesImporter {
    struct Config: Decodable {
        let name: String?
        let key_define_type: String?
        let sound: String?
        let defines: [String: Define?]
    }

    enum Define: Decodable {
        case file(String)
        case slice(start: Double, duration: Double)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .file(s); return }
            let pair = try c.decode([Double].self)
            guard pair.count == 2 else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad slice") }
            self = .slice(start: pair[0], duration: pair[1])
        }
    }

    @MainActor
    static func runPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a Mechvibes pack folder (containing config.json)"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let dest = try importPack(at: url)
            AppState.shared.reloadPacks()
            AppState.shared.selectedPackID = dest.lastPathComponent
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    static func importPack(at source: URL) throws -> URL {
        let data = try Data(contentsOf: source.appendingPathComponent("config.json"))
        let config = try JSONDecoder().decode(Config.self, from: data)
        let name = config.name ?? source.lastPathComponent
        let dest = PackStore.directory.appendingPathComponent("mechvibes-\(source.lastPathComponent)", isDirectory: true)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        var whole: AudioIO.Clip?
        if config.key_define_type != "multi", let sound = config.sound {
            whole = try AudioIO.read(source.appendingPathComponent(sound))
        }
        var written = 0
        for (code, define) in config.defines {
            guard let define else { continue }
            let clip: AudioIO.Clip
            switch define {
            case .file(let file):
                guard let c = try? AudioIO.read(source.appendingPathComponent(file)) else { continue }
                clip = c
            case let .slice(start, duration):
                guard let w = whole else { continue }
                let a = max(0, Int(start / 1000 * w.sampleRate))
                let b = min(w.left.count, a + Int(duration / 1000 * w.sampleRate))
                guard b > a else { continue }
                clip = AudioIO.Clip(left: Array(w.left[a..<b]), right: nil, sampleRate: w.sampleRate)
            }
            try AudioIO.writeWAV(clip.left, sampleRate: clip.sampleRate, to: dest.appendingPathComponent("\(code)-down.wav"))
            written += 1
        }
        guard written > 0 else {
            throw NSError(domain: "OpenThock", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "No sounds could be decoded. Ogg Vorbis packs aren't supported by macOS; convert them to WAV first."])
        }
        try PackStore.writeManifest(PackManifest(name: name, author: "Mechvibes import", license: nil,
                                                 description: "Imported from Mechvibes (press sounds only).",
                                                 colors: ["#e7e5e4", "#a8a29e"], gain: 1, groupGains: nil,
                                                 generatorVersion: nil), to: dest)
        return dest
    }
}
