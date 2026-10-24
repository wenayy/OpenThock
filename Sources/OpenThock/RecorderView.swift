import SwiftUI

struct RecorderView: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var recorder = AppState.shared.recorder
    @State private var saveMessage: String?

    private let unit: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record Your Keyboard").font(.title2.weight(.semibold))
            Text("Like Klack, every key gets its own press **and** release sound. Use a quiet room, put the mic close to your keyboard, then press each key once firmly and hold it for about half a second before letting go. Re-record a key by clicking it and pressing it again.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                switch recorder.phase {
                case .idle:
                    Button("Start Listening") {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        Task { await recorder.start() }
                    }
                    .keyboardShortcut(.defaultAction)
                case .listening:
                    Button("Stop") { recorder.stop() }
                    LevelMeter(level: recorder.level).frame(width: 120, height: 8)
                case .failed(let message):
                    Text(message).foregroundStyle(.red).font(.callout)
                    Button("Retry") { Task { await recorder.start() } }
                }
                Spacer()
                Toggle("Numpad & nav keys", isOn: $recorder.includeExtended).toggleStyle(.checkbox)
            }

            Text(recorder.lastMessage).font(.callout.weight(.medium))

            keyboard

            HStack(spacing: 8) {
                ForEach(KeyMap.pointer) { key in keyCap(key, width: 2.5) }
                Text("Click inside this window to record mouse buttons.").font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                // Locked while listening, or the keys you record would be typed into them.
                TextField("Pack name", text: $recorder.packName).frame(width: 200)
                    .disabled(recorder.isListening)
                TextField("Author", text: $recorder.author).frame(width: 160)
                    .disabled(recorder.isListening)
                Text("\(recorder.recordedCount)/\(recorder.targets.count) keys").foregroundStyle(.secondary)
                Spacer()
                Button("Save Switch Set") { save() }
                    .disabled(recorder.takes.isEmpty)
            }
            if let saveMessage { Text(saveMessage).font(.caption).foregroundStyle(.secondary) }
            Text("Keys you skip borrow a sound from a similar key, always the same one, so a partial set still sounds consistent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: recorder.includeExtended ? 960 : 640)
        .onAppear { state.recorderOpen = true }
        .onDisappear {
            state.recorderOpen = false
            recorder.stop()
        }
    }

    private var keyboard: some View {
        ZStack(alignment: .topLeading) {
            ForEach(KeyMap.rows(includeExtended: recorder.includeExtended), id: \.self) { row in
                ForEach(row) { key in
                    keyCap(key, width: key.width)
                        .offset(x: key.x * unit, y: CGFloat(key.row) * unit)
                }
            }
        }
        .frame(width: (recorder.includeExtended ? 23 : 15) * unit, height: 6 * unit, alignment: .topLeading)
    }

    private func keyCap(_ key: KeyDef, width: Double) -> some View {
        let recorded = recorder.takes[key.id] != nil
        let hasUp = recorder.takes[key.id]?.up != nil
        let isSelected = recorder.selected == key.id
        return Button {
            recorder.selected = key.id
        } label: {
            Text(key.label.isEmpty ? "space" : key.label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: width * unit - 4, height: unit - 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(
                        isSelected ? Color.accentColor.opacity(0.85)
                            : recorded ? (hasUp ? Color.green.opacity(0.35) : Color.yellow.opacity(0.35))
                            : Color.secondary.opacity(0.12)
                    )
                )
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if recorded { Button("Clear") { recorder.clear(key.id) } }
        }
    }

    private func save() {
        do {
            let url = try recorder.save()
            state.reloadPacks()
            state.selectedPackID = url.lastPathComponent
            saveMessage = "Saved to \(url.path). It's now your active switch set."
        } catch {
            saveMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(level > 0.9 ? Color.red : Color.green)
                    .frame(width: geo.size.width * CGFloat(min(1, sqrt(level))))
            }
        }
    }
}
