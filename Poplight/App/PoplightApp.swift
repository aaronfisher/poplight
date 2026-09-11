import PoplightKit
import SwiftUI

@main
struct PoplightApp: App {
    @State private var ble = BLEManager()
    @State private var lab = LabState()

    /// Until the protocol is decoded the Lab is the whole app, so open it at launch.
    /// `--lab` forces it, `--no-lab` suppresses it.
    private var shouldOpenLabAtLaunch: Bool {
        let args = CommandLine.arguments
        if args.contains("--no-lab") { return false }
        if args.contains("--lab") { return true }
        return !PoplightProtocol.isKnown
    }

    var body: some Scene {
        MenuBarExtra("Poplight", systemImage: "lamp.desk") {
            MenuBarView()
                .environment(ble)
                .environment(lab)
        }
        .menuBarExtraStyle(.window)

        Window("Poplight Lab", id: LabState.windowID) {
            LabView()
                .environment(ble)
                .environment(lab)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .defaultLaunchBehavior(shouldOpenLabAtLaunch ? .presented : .suppressed)
    }
}
