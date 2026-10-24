import AVFoundation
import CMixer
import CoreAudio

struct OutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
}

enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                               _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var addr = address(selector, scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func defaultOutput() -> AudioDeviceID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice).flatMap { $0 == 0 ? nil : $0 }
    }

    static func all() -> [OutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streamsAddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamSize) == noErr, streamSize > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return OutputDevice(id: id, uid: uid, name: name,
                                transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    static func device(uid: String) -> OutputDevice? { all().first { $0.uid == uid } }

    /// Headphones get the 3-D treatment in Auto mode (Klack: "3D sound while using AirPods").
    static func isHeadphones(_ id: AudioDeviceID) -> Bool {
        if let source = uint32(id, kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput),
           source == 0x6864_706E /* 'hdpn' */ {
            return true
        }
        guard let device = all().first(where: { $0.id == id }), device.isBluetooth else { return false }
        let name = device.name.lowercased()
        return ["airpods", "headphone", "beats", "buds", "wh-", "wf-", "bose", "sennheiser"].contains { name.contains($0) }
    }

    static func onChange(_ block: @escaping () -> Void) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in block() }
        }
    }
}

/// Hosts the C mixer inside AVAudioEngine.
final class AudioOutput {
    private let engine = AVAudioEngine()
    private lazy var sourceNode = AVAudioSourceNode { _, _, frameCount, bufferList -> OSStatus in
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard let left = buffers.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        cm_render(left, right, frameCount)
        return noErr
    }
    private var deviceUID: String?
    private var observer: NSObjectProtocol?
    private(set) var currentDeviceID: AudioDeviceID?

    init() {
        engine.attach(sourceNode)
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: .main) { [weak self] _ in
            // Our own device switch can post this too; don't loop on it.
            guard let self, Date().timeIntervalSince(self.lastRestart) > 0.5 else { return }
            self.restart()
        }
    }

    private var lastRestart = Date.distantPast

    /// `uid == nil` follows the system default output.
    func use(deviceUID uid: String?) {
        deviceUID = uid
        restart()
    }

    func restart() {
        lastRestart = Date()
        engine.stop()
        let target = deviceUID.flatMap { AudioDevices.device(uid: $0)?.id } ?? AudioDevices.defaultOutput()
        if let target {
            do {
                try engine.outputNode.auAudioUnit.setDeviceID(target)
                currentDeviceID = target
            } catch {
                NSLog("OpenThock: could not select output device \(target): \(error)")
            }
        }
        setLowLatencyBuffer(frames: 256)

        let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sampleRate = rate > 0 ? rate : 48_000
        cm_set_output_rate(sampleRate)
        engine.disconnectNodeOutput(sourceNode)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: nil)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("OpenThock: audio engine failed to start: \(error)")
        }
    }

    private func setLowLatencyBuffer(frames: UInt32) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var size = frames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                             &size, UInt32(MemoryLayout<UInt32>.size))
    }
}
