import PoplightKit
import SwiftUI

/// The shared control strip used by light cards and group cards:
/// power switch, brightness slider, warmth picker, timer menu.
struct ControlsPanel: View {
    var isOn: Bool
    var warmth: PoplightColorTemperature
    var enabled: Bool
    @Binding var brightness: Double
    var onPower: (Bool) -> Void
    var onBrightness: (Int) -> Void
    var onWarmth: (PoplightColorTemperature) -> Void
    var onTimer: (Int) -> Void

    static let timerChoices = [15, 30, 45, 60, 120, 240]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sun.min")
                Slider(value: $brightness, in: 1...99, step: 1) { editing in
                    if !editing { onBrightness(Int(brightness)) }
                }
                Image(systemName: "sun.max")
                Text("\(Int(brightness))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
            }

            HStack {
                Picker("Warmth", selection: Binding(get: { warmth }, set: onWarmth)) {
                    Text("Warm").tag(PoplightColorTemperature.warm)
                    Text("Neutral").tag(PoplightColorTemperature.neutral)
                    Text("Cool").tag(PoplightColorTemperature.cool)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                Spacer()

                Menu {
                    ForEach(Self.timerChoices, id: \.self) { minutes in
                        Button(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")") {
                            onTimer(minutes)
                        }
                    }
                } label: {
                    Label("Timer", systemImage: "timer")
                }
                .fixedSize()
            }
        }
        .disabled(!enabled)
    }

    /// The switch shown in the card header.
    static func powerSwitch(isOn: Bool, enabled: Bool, action: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: Binding(get: { isOn }, set: action))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!enabled)
    }
}
