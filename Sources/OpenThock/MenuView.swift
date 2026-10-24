import ServiceManagement
import SwiftUI

let accent = Color(hex: "#f97316")

struct MenuView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var stats = AppState.shared.stats
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if !state.hasPermission { permissionCard }
                Card { switchSets }
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        volume
                        TonePadSection(pitch: $state.tonePitch, variation: $state.toneVariation)
                    }
                }
                Card { spatial }
                Card { sounds }
                Card { sleep }
                footer
            }
            .padding(12)
        }
        .frame(width: 330, height: min(760, (NSScreen.main?.visibleFrame.height ?? 900) - 60))
        .tint(accent)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 1) {
                Text("OpenThock").font(.system(size: 15, weight: .semibold))
                Text(state.enabled ? "\(stats.today.formatted()) keystrokes today" : "Paused")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Toggle("", isOn: $state.enabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                .help("Toggle anywhere with ⌃⌥K")
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var permissionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Permission needed", systemImage: "hand.raised.fill").font(.subheadline.weight(.semibold))
                    .foregroundStyle(accent)
                Text("Allow OpenThock in Input Monitoring so it can hear your keystrokes. Nothing you type is stored or sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Grant Access…") { state.requestPermission() }.buttonStyle(.borderedProminent)
                    Button("Reset") { state.resetPermission() }.help("Use this if OpenThock is already listed but still silent")
                }
            }
        }
    }

    // MARK: Switches

    private var switchSets: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionTitle("Switches", icon: "keyboard")
                Spacer()
                Button { state.previewPack() } label: {
                    Label("Preview", systemImage: "play.fill").font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            .padding(.bottom, 4)
            ForEach(PackCategory.allCases, id: \.self) { category in
                let packs = state.packs.filter { PackCategory(pack: $0) == category }
                if !packs.isEmpty {
                    Text(category.title).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                        .textCase(.uppercase).padding(.top, 6).padding(.leading, 6)
                    ForEach(packs) { pack in SwitchRow(pack: pack, selected: pack.id == state.selectedPackID) {
                        state.selectedPackID = pack.id
                    } }
                }
            }
        }
    }

    // MARK: Tuning

    private var volume: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Volume", icon: "speaker.wave.2.fill")
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $state.volume, in: 0...1)
                Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var spatial: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle("Spatial Audio", icon: "airpodspro")
                Spacer()
                if state.spatialMode == .auto {
                    Text(state.isHeadphones ? "3D · headphones" : "2D · speakers")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $state.spatialMode) {
                ForEach(SpatialMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Picker(selection: $state.outputDeviceUID) {
                Text("System Output").tag(String?.none)
                ForEach(state.devices) { Text($0.name).tag(String?.some($0.uid)) }
            } label: {
                Text("Output").font(.caption).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private var sounds: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Sounds", icon: "waveform")
            ToggleRow("Modifier keys", icon: "command", isOn: $state.modifierSounds)
            ToggleRow("Mouse clicks", icon: "computermouse.fill", isOn: $state.mouseSounds)
            ToggleRow("Scroll wheel", icon: "arrow.up.and.down", isOn: $state.scrollSounds)
            ToggleRow("Ding on return", icon: "bell.fill", isOn: $state.returnDing)
        }
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Sleep", icon: "moon.fill")
            if let until = state.sleepUntil, until > Date() {
                HStack {
                    Text("Sleeping until \(until.formatted(date: .omitted, time: .shortened))").font(.caption)
                    Spacer()
                    Button("Wake") { state.sleep(for: nil) }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach([("15m", 900.0), ("1h", 3600.0), ("8h", 28_800.0)], id: \.0) { label, seconds in
                        Button(label) { state.sleep(for: seconds) }.controlSize(.small)
                    }
                }
            }
            if let app = state.lastExternalApp, let id = app.bundleIdentifier {
                ToggleRow("Mute in \(app.localizedName ?? id)", icon: "app.dashed", isOn: Binding(
                    get: { state.mutedApps.contains(id) },
                    set: { _ in state.toggleMute(for: app) }
                ))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "recorder")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Record Keyboard", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            Spacer()
            Menu {
                Toggle("Launch at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                ))
                Divider()
                Button("Open Packs Folder") { state.openPacksFolder() }
                Button("Import Mechvibes Pack…") { MechvibesImporter.runPanel() }
                Button("Reload Packs") { state.reloadPacks() }
                Divider()
                Button("Welcome Guide") { WelcomeWindow.show() }
                Button("Fix Keyboard Permission…") { state.resetPermission() }
                Button("GitHub Page") { NSWorkspace.shared.open(URL(string: "https://github.com/wenayy/OpenThock")!) }
                Text("\(stats.total.formatted()) keystrokes total" + (stats.topKey.map { " · top key \($0)" } ?? ""))
                Divider()
                Button("Quit OpenThock") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape.fill")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

// MARK: - Components

enum PackCategory: CaseIterable {
    case yours, recorded, synth
    init(pack: PackInfo) {
        if pack.id.hasPrefix("synth-") { self = .synth }
        else if pack.manifest.bundledVersion != nil { self = .recorded }
        else { self = .yours }
    }
    var title: String {
        switch self {
        case .yours: return "Your sets"
        case .recorded: return "Recorded switches"
        case .synth: return "Synthesized"
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

struct SectionTitle: View {
    let title: String, icon: String
    init(_ title: String, icon: String) { self.title = title; self.icon = icon }
    var body: some View {
        Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
    }
}

struct ToggleRow: View {
    let title: String, icon: String
    @Binding var isOn: Bool
    init(_ title: String, icon: String, isOn: Binding<Bool>) { self.title = title; self.icon = icon; _isOn = isOn }
    var body: some View {
        HStack {
            Image(systemName: icon).frame(width: 18).foregroundStyle(.secondary).font(.caption)
            Text(title).font(.callout).lineLimit(1)
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

struct SwitchRow: View {
    let pack: PackInfo
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                SwitchSwatch(colors: pack.colors).frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pack.name).font(.callout.weight(selected ? .semibold : .regular))
                    if let d = pack.manifest.description {
                        Text(d).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent) }
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? accent.opacity(0.14) : hover ? Color.primary.opacity(0.06) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A tiny keycap in the switch's colors (Klack shows switch stems the same way).
struct SwitchSwatch: View {
    let colors: [String]
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: colors.map { Color(hex: $0) }, startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            Image(systemName: "plus").font(.system(size: 9, weight: .heavy)).foregroundStyle(.black.opacity(0.3))
        }
        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
    }
}

/// Drag to tune the set. X = pitch, Y = per-press variation (Klack's "Tone Pad").
struct TonePadSection: View {
    @Binding var pitch: Double
    @Binding var variation: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionTitle("Tone Pad", icon: "circle.grid.cross.fill")
                Spacer()
                Button("Reset") { pitch = 0; variation = 0.25 }.buttonStyle(.borderless).font(.caption)
            }
            GeometryReader { geo in
                let size = geo.size
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                    Canvas { ctx, s in
                        for i in 1..<8 {
                            let x = s.width * CGFloat(i) / 8, y = s.height * CGFloat(i) / 8
                            ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: s.height / 2 - 1, width: 2, height: 2)), with: .color(.secondary.opacity(0.4)))
                            ctx.fill(Path(ellipseIn: CGRect(x: s.width / 2 - 1, y: y - 1, width: 2, height: 2)), with: .color(.secondary.opacity(0.4)))
                        }
                    }
                    Circle().fill(accent).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                        .shadow(color: accent.opacity(0.6), radius: 6)
                        .position(x: (pitch + 1) / 2 * size.width, y: (1 - variation) * size.height)
                    VStack {
                        Text("Varied").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        HStack {
                            Text("Deep").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Uniform").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                            Text("Bright").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    pitch = min(1, max(-1, Double(value.location.x / size.width) * 2 - 1))
                    variation = min(1, max(0, 1 - Double(value.location.y / size.height)))
                })
            }
            .frame(height: 96)
        }
    }
}

extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}
