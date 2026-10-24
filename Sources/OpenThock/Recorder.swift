import AVFoundation

/// Continuously captures the microphone into a ring buffer addressable by mach host time,
/// so a key event's timestamp can be turned into a window of audio.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var ring: [Float] = []
    private var written: Int64 = 0            // total frames ever written
    private var anchorHostTime: UInt64 = 0    // host time of frame `anchorFrame`
    private var anchorFrame: Int64 = 0
    private(set) var sampleRate: Double = 48_000
    private(set) var level: Float = 0

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "OpenThock", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone input available."])
        }
        sampleRate = format.sampleRate
        ring = [Float](repeating: 0, count: Int(sampleRate * 8))
        written = 0
        input.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in
            self?.append(buffer, time: time)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var peak: Float = 0
        lock.lock()
        if time.isHostTimeValid {
            anchorHostTime = time.hostTime
            anchorFrame = written
        }
        let size = ring.count
        for i in 0..<n {
            let x = data[i]
            ring[Int((written + Int64(i)) % Int64(size))] = x
            peak = max(peak, abs(x))
        }
        written += Int64(n)
        level = max(peak, level * 0.85)
        lock.unlock()
    }

    /// Absolute frame index that corresponds to a host time.
    func frame(at hostTime: UInt64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        let delta = hostTime >= anchorHostTime
            ? HostClock.seconds(hostTime - anchorHostTime)
            : -HostClock.seconds(anchorHostTime - hostTime)
        return anchorFrame + Int64((delta * sampleRate).rounded())
    }

    var latestFrame: Int64 {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    /// Copies `[start, end)`; frames no longer (or not yet) in the ring are zero.
    func copy(from start: Int64, to end: Int64) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let size = Int64(ring.count)
        return (start..<max(start, end)).map { f in
            (f >= 0 && f < written && f >= written - size) ? ring[Int(f % size)] : 0
        }
    }
}

/// Finds the press and release sounds in a captured window and trims them.
enum TakeExtractor {
    struct Take {
        var down: [Float]
        var up: [Float]?
    }

    static let preRoll = 0.5   // seconds captured before key-down
    static let postRoll = 0.4  // seconds captured after key-up

    /// `downAt` / `upAt` are frame offsets of the key events inside `signal`.
    static func extract(_ input: [Float], sampleRate sr: Double, downAt: Int, upAt: Int?) -> Take? {
        guard downAt > Int(sr * 0.2), downAt < input.count else { return nil }
        let block = max(1, Int(sr / 1000))  // 1 ms envelope blocks

        // Remove DC using the quiet pre-roll.
        let noiseRegion = 0..<(downAt - Int(sr * 0.12))
        let dc = noiseRegion.isEmpty ? 0 : noiseRegion.reduce(Float(0)) { $0 + input[$1] } / Float(noiseRegion.count)
        let signal = input.map { $0 - dc }
        let env: [Float] = stride(from: 0, to: signal.count, by: block).map { start in
            signal[start..<min(start + block, signal.count)].reduce(Float(0)) { max($0, abs($1)) }
        }
        let noiseBlocks = env[0..<max(1, noiseRegion.count / block)].sorted()
        let noise = max(noiseBlocks[noiseBlocks.count * 9 / 10], 2e-4)
        let threshold = max(noise * 5, 0.004)

        func onset(searchFrom a: Int, to b: Int) -> Int? {
            let lo = max(10, a / block), hi = min(env.count, b / block)
            guard lo < hi else { return nil }
            for i in lo..<hi {
                let history = env[(i - 10)..<i].reduce(0, +) / 10
                if env[i] > threshold && env[i] > history * 2.5 { return i * block }
            }
            return nil
        }

        func clip(from start: Int, limit: Int) -> [Float] {
            let begin = max(0, start - Int(sr * 0.002))
            var last = start / block
            let limitBlock = min(env.count, limit / block)
            var i = start / block
            while i < limitBlock {
                if env[i] > noise * 2.5 { last = i }
                i += 1
            }
            let end = min(limit, signal.count, (last + 1) * block + Int(sr * 0.012))
            var out = Array(signal[begin..<max(begin + 1, end)])
            let fadeIn = min(out.count, Int(sr * 0.001))
            for k in 0..<fadeIn { out[k] *= Float(k) / Float(fadeIn) }
            let fadeOut = min(out.count, Int(sr * 0.010))
            for k in 0..<fadeOut {
                out[out.count - 1 - k] *= 0.5 - 0.5 * cos(Float.pi * Float(k) / Float(fadeOut))
            }
            return out
        }

        let releaseSearch = upAt.map { $0 - Int(sr * 0.05) } ?? signal.count
        guard let downOnset = onset(searchFrom: downAt - Int(sr * 0.08), to: min(releaseSearch, downAt + Int(sr * 0.25))) else {
            return nil
        }
        let downLimit = min(releaseSearch, downOnset + Int(sr * 0.4))
        let down = clip(from: downOnset, limit: max(downLimit, downOnset + Int(sr * 0.015)))

        var up: [Float]?
        if let upAt, let upOnset = onset(searchFrom: max(releaseSearch, downOnset + Int(sr * 0.02)),
                                         to: min(signal.count, upAt + Int(sr * 0.25))) {
            up = clip(from: upOnset, limit: min(signal.count, upOnset + Int(sr * 0.35)))
        }
        return Take(down: down, up: up)
    }
}

/// Guided "record every key of your keyboard" session.
@MainActor
final class KeyboardRecorder: ObservableObject {
    enum Phase: Equatable { case idle, listening, failed(String) }

    @Published var phase: Phase = .idle
    @Published var takes: [String: TakeExtractor.Take] = [:]
    @Published var selected: String?
    @Published var lastMessage = "Press any key once, firmly, and release it."
    @Published var level: Float = 0
    @Published var includeExtended = false { didSet { selectNextMissing() } }
    @Published var packName = "My Keyboard"
    @Published var author = NSFullUserName()

    private let mic = MicCapture()
    private var pendingDown: [String: UInt64] = [:]
    private var meterTimer: Timer?
    var onPreview: ((TakeExtractor.Take) -> Void)?

    var sampleRate: Double { mic.sampleRate }

    var targets: [KeyDef] {
        KeyMap.rows(includeExtended: includeExtended).flatMap { $0 } + KeyMap.pointer
    }
    var recordedCount: Int { targets.filter { takes[$0.id] != nil }.count }
    var isListening: Bool { phase == .listening }

    func start() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            phase = .failed("Microphone access was denied. Enable it in System Settings → Privacy & Security → Microphone.")
            return
        }
        do {
            try mic.start()
            phase = .listening
            selectNextMissing()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.level = self?.mic.level ?? 0 }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func stop() {
        mic.stop()
        meterTimer?.invalidate()
        meterTimer = nil
        pendingDown.removeAll()
        phase = .idle
    }

    func clear(_ id: String) {
        takes[id] = nil
        selected = id
    }

    /// Fed every key / mouse event while the recorder window is open.
    func handle(_ key: KeyDef, down: Bool, hostTime: UInt64) {
        guard isListening, targets.contains(where: { $0.id == key.id }) else { return }
        // Only record unrecorded keys, or the selected key (to re-record it).
        guard takes[key.id] == nil || selected == key.id else { return }
        if down {
            pendingDown[key.id] = hostTime
            return
        }
        guard let downTime = pendingDown.removeValue(forKey: key.id) else { return }
        let id = key.id, label = key.label.isEmpty ? "space" : key.label
        let startFrame = mic.frame(at: downTime) - Int64(mic.sampleRate * TakeExtractor.preRoll)
        let downFrame = mic.frame(at: downTime)
        let upFrame = mic.frame(at: hostTime)
        let endFrame = upFrame + Int64(mic.sampleRate * TakeExtractor.postRoll)
        let sr = mic.sampleRate

        // Wait until the release tail has been captured.
        DispatchQueue.main.asyncAfter(deadline: .now() + TakeExtractor.postRoll + 0.1) { [weak self] in
            guard let self else { return }
            let window = self.mic.copy(from: startFrame, to: endFrame)
            let take = TakeExtractor.extract(window, sampleRate: sr,
                                             downAt: Int(downFrame - startFrame), upAt: Int(upFrame - startFrame))
            guard let take else {
                self.lastMessage = "Couldn't hear “\(label)” — press it a bit harder, or move the mic closer."
                return
            }
            self.takes[id] = take
            self.lastMessage = take.up == nil
                ? "Got “\(label)” (press only; hold it a little longer to capture the release)."
                : "Got “\(label)”."
            self.onPreview?(take)
            self.selectNextMissing()
        }
    }

    func selectNextMissing() {
        selected = targets.first { takes[$0.id] == nil }?.id
    }

    /// Writes the pack. Gain is normalized across the whole pack, never per key,
    /// so the natural loudness differences between keys are kept.
    func save() throws -> URL {
        let name = packName.trimmingCharacters(in: .whitespaces).isEmpty ? "My Keyboard" : packName
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        let dir = PackStore.directory.appendingPathComponent("recorded-\(slug)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let peak = takes.values.flatMap { [$0.down, $0.up ?? []] }.reduce(Float(0)) { acc, clip in
            max(acc, clip.reduce(0) { max($0, abs($1)) })
        }
        let scale = peak > 0 ? 0.89 / peak : 1
        for (id, take) in takes {
            try AudioIO.writeWAV(take.down.map { $0 * scale }, sampleRate: mic.sampleRate,
                                 to: dir.appendingPathComponent("\(id)-down.wav"))
            if let up = take.up {
                try AudioIO.writeWAV(up.map { $0 * scale }, sampleRate: mic.sampleRate,
                                     to: dir.appendingPathComponent("\(id)-up.wav"))
            }
        }
        let manifest = PackManifest(name: name, author: author, license: "CC-BY-4.0",
                                    description: "Recorded with OpenThock's keyboard recorder.",
                                    colors: ["#bbf7d0", "#16a34a"], gain: 1, groupGains: nil, generatorVersion: nil)
        try PackStore.writeManifest(manifest, to: dir)
        return dir
    }
}
