import SwiftUI

/// First-run guide. Shown automatically until Input Monitoring is granted.
@MainActor
enum WelcomeWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: WelcomeView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

struct WelcomeView: View {
    @ObservedObject var state = AppState.shared

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                .padding(.top, 28)
            VStack(spacing: 6) {
                Text("Welcome to OpenThock").font(.system(size: 26, weight: .bold))
                Text("A satisfying mechanical keyboard sound for every keystroke.\nEvery key has its own press and release recording.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, title: "Allow Input Monitoring",
                     detail: "macOS asks this for any app that reacts to your keyboard. OpenThock never stores or sends what you type, and it has no network code.",
                     done: state.hasPermission) {
                    Button(state.hasPermission ? "Granted" : "Open System Settings…") { state.requestPermission() }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(state.hasPermission)
                }
                Step(number: 2, title: "Type anything",
                     detail: "Sounds play in every app. Toggle with ⌃⌥K, or from the keyboard icon in the menu bar.",
                     done: state.hasPermission && state.stats.today > 0) { EmptyView() }
                Step(number: 3, title: "Pick a switch",
                     detail: "Open the menu bar icon to choose Topre, Cherry MX Blue/Brown/Red/Black, or record your own keyboard.",
                     done: false) { EmptyView() }
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 14).fill(.quaternary.opacity(0.5)))
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
            Button("Done") { WelcomeWindow.close() }
                .keyboardShortcut(.defaultAction).controlSize(.large).padding(.bottom, 24)
        }
        .frame(width: 520, height: 560)
    }
}

private struct Step<Accessory: View>: View {
    let number: Int, title: String, detail: String, done: Bool
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : accent).frame(width: 26, height: 26)
                if done { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) }
                else { Text("\(number)").font(.callout.bold()).foregroundStyle(.white) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                accessory
            }
        }
    }
}
