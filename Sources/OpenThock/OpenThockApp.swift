import CMixer
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--generate-packs") {
            Synth.ensureBuiltInPacks()
            PackStore.installBundledPacks()
            print("Packs in \(PackStore.directory.path):")
            PackStore.list().forEach { print(" - \($0.name) (\($0.id))") }
            return
        }
        if args.contains("--self-test") {
            exit(SelfTest.run() ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--render-demo"), i + 1 < args.count {
            let pack = args.firstIndex(of: "--pack").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "synth-thock"
            exit(SelfTest.renderDemo(packID: pack, to: URL(fileURLWithPath: args[i + 1])) ? 0 : 1)
        }
        OpenThockApp.main()
    }
}

struct OpenThockApp: App {
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
        } label: {
            Image(systemName: state.enabled ? "keyboard.fill" : "keyboard")
                .opacity(state.enabled ? 1 : 0.5)
        }
        .menuBarExtraStyle(.window)

        Window("Record Your Keyboard", id: "recorder") {
            RecorderView()
        }
        .windowResizability(.contentSize)
    }
}
