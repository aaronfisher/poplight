import PoplightKit
import SwiftUI

@main
struct PoplightApp: App {
    @State private var ble: BLEManager
    @State private var store: LightStore
    @State private var lab = LabState()
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        let manager = BLEManager()
        _ble = State(initialValue: manager)
        _store = State(initialValue: LightStore(manager: manager))
    }

    /// `--lab` opens the Lab window at launch (handy while reverse-engineering).
    private var openLabAtLaunch: Bool {
        CommandLine.arguments.contains("--lab")
    }

    var body: some Scene {
        WindowGroup("Poplight", id: "main") {
            ControlView()
                .environment(ble)
                .environment(store)
                .environment(lab)
        }
        .defaultSize(width: 520, height: 480)
        .defaultLaunchBehavior(.presented)

        MenuBarExtra("Poplight", systemImage: "lamp.desk", isInserted: $showMenuBarExtra) {
            MenuBarView()
                .environment(ble)
                .environment(store)
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
        .defaultLaunchBehavior(openLabAtLaunch ? .presented : .suppressed)

        Settings {
            Form {
                Toggle("Show in menu bar", isOn: $showMenuBarExtra)
            }
            .padding(20)
            .frame(width: 320)
        }
    }
}
