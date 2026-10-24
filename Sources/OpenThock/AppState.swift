import AppKit
import CMixer
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private let defaults = UserDefaults.standard

    // MARK: Settings (persisted)

    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled") } }
    @Published var selectedPackID: String { didSet { defaults.set(selectedPackID, forKey: "pack"); loadSelectedPack() } }
    @Published var volume: Double { didSet { defaults.set(volume, forKey: "volume"); applyVolume() } }
    @Published var tonePitch: Double { didSet { defaults.set(tonePitch, forKey: "tone.pitch"); player.pitch = tonePitch } }
    @Published var toneVariation: Double { didSet { defaults.set(toneVariation, forKey: "tone.variation"); player.variation = toneVariation } }
    @Published var spatialMode: SpatialMode { didSet { defaults.set(spatialMode.rawValue, forKey: "spatial"); player.spatial = spatialMode } }
    @Published var modifierSounds: Bool { didSet { defaults.set(modifierSounds, forKey: "sounds.modifiers") } }
    @Published var mouseSounds: Bool { didSet { defaults.set(mouseSounds, forKey: "sounds.mouse") } }
    @Published var scrollSounds: Bool { didSet { defaults.set(scrollSounds, forKey: "sounds.scroll") } }
    @Published var returnDing: Bool { didSet { defaults.set(returnDing, forKey: "sounds.ding") } }
    @Published var outputDeviceUID: String? { didSet { defaults.set(outputDeviceUID, forKey: "output"); output.use(deviceUID: outputDeviceUID); refreshHeadphones() } }
    @Published var mutedApps: [String] { didSet { defaults.set(mutedApps, forKey: "mutedApps") } }

    // MARK: Runtime state

    @Published var hasPermission = InputMonitor.hasPermission
    @Published var packs: [PackInfo] = []
    @Published var devices: [OutputDevice] = []
    @Published var sleepUntil: Date?
    @Published var lastExternalApp: NSRunningApplication?
    @Published var isHeadphones = false

    let stats = Stats()
    let recorder = KeyboardRecorder()
    var recorderOpen = false

    private let monitor = InputMonitor()
    private let output = AudioOutput()
    private let bank: SoundBank
    private var player = SoundPlayer()
    private var frontmostBundleID: String?
    private var permissionTimer: Timer?
    private var tapHasPermission = false

    private init() {
        defaults.register(defaults: [
            "enabled": true, "pack": "mechvibes-topre", "volume": 0.7, "tone.pitch": 0.0, "tone.variation": 0.25,
            "spatial": SpatialMode.auto.rawValue, "sounds.modifiers": true, "sounds.mouse": false,
            "sounds.scroll": false, "sounds.ding": false,
        ])
        enabled = defaults.bool(forKey: "enabled")
        selectedPackID = defaults.string(forKey: "pack") ?? "mechvibes-topre"
        volume = defaults.double(forKey: "volume")
        tonePitch = defaults.double(forKey: "tone.pitch")
        toneVariation = defaults.double(forKey: "tone.variation")
        spatialMode = SpatialMode(rawValue: defaults.string(forKey: "spatial") ?? "") ?? .auto
        modifierSounds = defaults.bool(forKey: "sounds.modifiers")
        mouseSounds = defaults.bool(forKey: "sounds.mouse")
        scrollSounds = defaults.bool(forKey: "sounds.scroll")
        returnDing = defaults.bool(forKey: "sounds.ding")
        outputDeviceUID = defaults.string(forKey: "output")
        mutedApps = defaults.stringArray(forKey: "mutedApps") ?? []

        bank = SoundBank()
        player.pitch = tonePitch
        player.variation = toneVariation
        player.spatial = spatialMode

        Synth.ensureBuiltInPacks()
        PackStore.installBundledPacks()
        reloadPacks()
        loadSelectedPack()

        output.use(deviceUID: outputDeviceUID)
        applyVolume()
        devices = AudioDevices.all()
        refreshHeadphones()
        AudioDevices.onChange { [weak self] in
            guard let self else { return }
            self.devices = AudioDevices.all()
            if self.outputDeviceUID == nil { self.output.use(deviceUID: nil) }
            self.refreshHeadphones()
        }

        monitor.handler = { [weak self] event, hostTime in
            MainActor.assumeIsolated { self?.handle(event, hostTime: hostTime) }
        }
        startMonitoring()
        observeFrontmostApp()
        recorder.onPreview = { [weak self] take in self?.preview(take) }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in cm_collect() }
        if !hasPermission { InputMonitor.requestPermission() }
        if !hasPermission || !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { WelcomeWindow.show() }
        }
    }

    // MARK: - Input

    func startMonitoring() {
        tapHasPermission = InputMonitor.hasPermission
        hasPermission = tapHasPermission
        monitor.stop()
        monitor.start()
        // Without Input Monitoring, macOS still creates the tap but only delivers keys typed
        // into our own windows. Keep checking, and re-create the tap once access is granted.
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let granted = InputMonitor.hasPermission
                    if granted != self.tapHasPermission || !self.monitor.isRunning { self.startMonitoring() }
                }
            }
        }
    }

    /// Clears a stale Input Monitoring entry (e.g. after an update changed the app's signature)
    /// and asks again.
    func resetPermission() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ListenEvent", Bundle.main.bundleIdentifier ?? "dev.openthock.OpenThock"]
        try? task.run()
        task.waitUntilExit()
        requestPermission()
    }

    func requestPermission() {
        InputMonitor.requestPermission()
        startMonitoring()
    }

    private var isAsleep: Bool {
        if let sleepUntil, sleepUntil > Date() { return true }
        if let id = frontmostBundleID, mutedApps.contains(id) { return true }
        return false
    }

    private func handle(_ event: InputEvent, hostTime: UInt64) {
        if case .toggleHotkey = event {
            enabled.toggle()
            return
        }
        if recorderOpen, case let .key(key, down) = event {
            recorder.handle(key, down: down, hostTime: hostTime)
        }
        // Never play while recording: the speakers would bleed into the mic.
        guard enabled, !isAsleep, !(recorderOpen && recorder.isListening) else { return }

        switch event {
        case let .key(key, down):
            if key.group == .mouse {
                guard mouseSounds else { return }
            } else {
                if down { stats.record(key) }
                if key.isModifierLike && !modifierSounds { return }
            }
            play(key, down: down)
            if down, returnDing, key.id == "28" || key.id == "3612", let ding = bank.ding ?? bank.sharedDing {
                player.trigger(sample: ding, key: key, gain: 0.6)
            }
        case .scroll:
            guard scrollSounds, let sample = bank.entry(for: "scroll")?.down else { return }
            player.trigger(sample: sample, key: KeyMap.scroll, gain: 0.8)
        case .toggleHotkey:
            break
        }
    }

    private func play(_ key: KeyDef, down: Bool) {
        guard let entry = bank.entry(for: key.id), let sample = down ? entry.down : entry.up else { return }
        player.trigger(sample: sample, key: key, gain: bank.packGain * bank.groupGain(key.group))
    }

    // MARK: - Packs

    func reloadPacks() {
        packs = PackStore.list()
        if !packs.contains(where: { $0.id == selectedPackID }), let first = packs.first {
            selectedPackID = first.id
        }
    }

    private func loadSelectedPack() {
        guard let pack = PackStore.list().first(where: { $0.id == selectedPackID }) else { return }
        bank.load(pack)
    }

    var selectedPack: PackInfo? { packs.first { $0.id == selectedPackID } }

    /// Plays the same phrase timing as Klack's website preview:
    /// down at t, up at t + 125 ms, 250 ms per key, 500 ms pauses.
    func previewPack() {
        let phrase: [String?] = ["24", "25", "18", "49", nil, "20", "35", "24", "46", "37", nil, "3675", "28"]
        var t = 0.0
        for id in phrase {
            guard let id, let key = KeyMap.byID[id] else { t += 0.5; continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.play(key, down: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.125) { [weak self] in self?.play(key, down: false) }
            t += 0.25
        }
    }

    private func preview(_ take: TakeExtractor.Take) {
        // Plays a take back right after it's captured, centered and at the original pitch.
        let rate = recorder.sampleRate
        let clips = [take.down] + (take.up.map { [$0] } ?? [])
        let ids = clips.map { AudioIO.register(AudioIO.Clip(left: $0, right: nil, sampleRate: rate)) }.filter { $0 >= 0 }
        for (index, id) in ids.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.18) {
                var t = cm_trigger_t(sample: id, rate: 1, gainL: 1, gainR: 1, delayL: 0, delayR: 0, shadowL: 0, shadowR: 0)
                cm_trigger(&t)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { ids.forEach { cm_sample_retire($0) } }
    }

    func openPacksFolder() {
        NSWorkspace.shared.open(PackStore.directory)
    }

    // MARK: - Output

    private func applyVolume() {
        // Perceptual curve; capped by the system volume like Klack.
        cm_set_master_gain(Float(volume * volume) * 1.6)
    }

    private func refreshHeadphones() {
        let id = outputDeviceUID.flatMap { AudioDevices.device(uid: $0)?.id } ?? AudioDevices.defaultOutput()
        isHeadphones = id.map(AudioDevices.isHeadphones) ?? false
        player.headphones = isHeadphones
    }

    // MARK: - Sleep

    func sleep(for seconds: TimeInterval?) {
        sleepUntil = seconds.map { Date().addingTimeInterval($0) }
    }

    func toggleMute(for app: NSRunningApplication) {
        guard let id = app.bundleIdentifier else { return }
        if let index = mutedApps.firstIndex(of: id) { mutedApps.remove(at: index) } else { mutedApps.append(id) }
    }

    private func observeFrontmostApp() {
        let ownID = Bundle.main.bundleIdentifier
        let update: (NSRunningApplication?) -> Void = { [weak self] app in
            guard let self else { return }
            self.frontmostBundleID = app?.bundleIdentifier
            if let app, app.bundleIdentifier != ownID { self.lastExternalApp = app }
        }
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { update(app) }
        }
    }
}
