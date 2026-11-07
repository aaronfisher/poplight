import PoplightKit
import SwiftUI

struct LogView: View {
    @Environment(LabState.self) private var lab
    let connection: BLEConnection

    var body: some View {
        @Bindable var lab = lab
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Log").font(.headline)
                Text("\(connection.log.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                TextField("Filter", text: $lab.logFilter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Toggle("Hide discovery noise", isOn: $lab.hideNoise)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Copy text") { copy(LogExport.text(filtered)) }
                Button("Copy JSON") { copy(LogExport.json(filtered)) }
                Button("Clear") { connection.clearLog() }
                Button("Show file") { NSWorkspace.shared.activateFileViewerSelecting([connection.logFileURL]) }
            }
            .controlSize(.small)
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { entry in
                            Text(entry.line(relativeTo: start))
                                .font(.caption.monospaced())
                                .foregroundStyle(color(for: entry.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: connection.log.count) {
                    if let last = filtered.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var start: Date {
        connection.log.first?.time ?? Date()
    }

    private var filtered: [LogEntry] {
        let needle = lab.logFilter.trimmingCharacters(in: .whitespaces)
        return connection.log.filter { entry in
            if lab.hideNoise, entry.kind == .discover { return false }
            guard !needle.isEmpty else { return true }
            let haystack = [entry.characteristic, entry.message, entry.data?.hexString, entry.kind.rawValue]
                .compactMap { $0 }
                .joined(separator: " ")
            return haystack.localizedCaseInsensitiveContains(needle)
        }
    }

    private func color(for kind: LogEntry.Kind) -> Color {
        switch kind {
        case .error: .red
        case .write, .writeResponse: .orange
        case .notify: .green
        case .read, .readRequest: .blue
        case .subscribe: .purple
        case .connect, .disconnect: .primary
        case .info, .discover: .secondary
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
