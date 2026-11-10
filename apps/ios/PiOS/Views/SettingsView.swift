import PiOSCore
import SwiftUI

private let fontSizes: [Double] = [8, 10, 12, 14, 16, 18]

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pios.showThinking") private var showThinking = true
    @AppStorage("pios.expandTools") private var expandTools = false
    @AppStorage("pios.showStats") private var showStats = false
    @AppStorage("pios.steeringMode") private var steeringMode = StreamingBehavior.steer.rawValue
    @AppStorage("pios.directorySort") private var directorySort = "recent"
    @AppStorage("pios.editorFontSize") private var editorFontSize = 12.0
    @AppStorage("pios.terminalFontSize") private var terminalFontSize = 12.0
    @State private var confirmForget: Machine? = nil
    @State private var pairing = false

    var body: some View {
        Form {
            Section("Machine") {
                ForEach(model.machines.machines) { machine in
                    Button {
                        model.activate(machine)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.label).foregroundStyle(Theme.text)
                                Text(machine.url.absoluteString).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                            Spacer()
                            if machine.id == model.activeMachine?.id { Image(systemName: "checkmark").foregroundStyle(Theme.ok) }
                        }
                    }
                    .swipeActions { Button("Forget", role: .destructive) { confirmForget = machine } }
                }
                Button { pairing = true } label: { Label("Pair another machine", systemImage: "plus") }
            }
            .listRowBackground(Theme.panel)

            Section("Transcript") {
                Toggle("Show thinking", isOn: $showThinking)
                Toggle("Expand finished tool calls", isOn: $expandTools)
                Toggle("Session stats after replies", isOn: $showStats)
            }
            .listRowBackground(Theme.panel)

            Section {
                Picker("While the agent works", selection: $steeringMode) {
                    Text("Steer").tag(StreamingBehavior.steer.rawValue)
                    Text("Follow up").tag(StreamingBehavior.followUp.rawValue)
                }
            } header: {
                Text("Delivery")
            } footer: {
                Text("What Send does mid-turn. Long-press Send to pick the other for one message.")
            }
            .listRowBackground(Theme.panel)

            Section("Directories") {
                Picker("Sort order", selection: $directorySort) {
                    Text("Recent work first").tag("recent")
                    Text("Alphabetical").tag("alphabetical")
                }
            }
            .listRowBackground(Theme.panel)

            Section("Files and terminal") {
                Picker("Editor font size", selection: $editorFontSize) {
                    ForEach(fontSizes, id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                Picker("Terminal font size", selection: $terminalFontSize) {
                    ForEach(fontSizes, id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
            }
            .listRowBackground(Theme.panel)

            UsageSection()

            Section {
                Text("Notifications when a turn settles come from the PWA's web push. Keep the PWA installed on the home screen for them; the daemon skips them while this app shows the session.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
            } header: {
                Text("Notifications")
            }
            .listRowBackground(Theme.panel)

            Section("Connection") {
                LabeledContent("Status", value: model.connection.transport.rawValue)
                LabeledContent("Sync", value: model.connection.sync.rawValue)
                if let reason = model.connection.reason { LabeledContent("Last reason", value: reason) }
                if let version = model.connection.serverVersion { LabeledContent("Daemon", value: version) }
                if let version = model.connection.piVersion { LabeledContent("pi", value: version) }
                LabeledContent("Outbox", value: "\(model.outbox.count) pending")
                Button("Reconnect now") { model.client.supervisor.wake("manual") }
            }
            .listRowBackground(Theme.panel)

            Section {
                LabeledContent("App", value: AppModel.clientVersion)
                LabeledContent("Wire protocol", value: "v\(wireVersion)")
            }
            .listRowBackground(Theme.panel)
        }
        .themedList()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        // Presented from here: a second sheet from the root would be refused
        // while this one is up.
        .sheet(isPresented: $pairing) { NavigationStack { PairingView() } }
        .confirmationDialog(
            "Forget \(confirmForget?.label ?? "")?",
            isPresented: Binding(get: { confirmForget != nil }, set: { if !$0 { confirmForget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let machine = confirmForget { model.forget(machine) }
            }
        } message: {
            Text("The token is removed from this phone. Run `pios-server revoke` on the machine to cut it off there too.")
        }
    }
}

/// Plan usage for pi's Anthropic login on the machine, as the PWA shows it.
struct UsageSection: View {
    @Environment(AppModel.self) private var model
    @State private var report: UsageReport? = nil
    @State private var state = "loading"

    var body: some View {
        Section("Claude usage") {
            switch state {
            case "loading":
                Text("Loading...").foregroundStyle(Theme.muted)
            case "error":
                Text("Usage is unavailable right now.").foregroundStyle(Theme.muted)
            default:
                if let report {
                    ForEach(report.windows) { window in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(window.label)
                                Spacer()
                                Text("\(Int(window.percent.rounded()))%").monospacedDigit().foregroundStyle(Theme.muted)
                            }
                            .font(.system(size: 14))
                            ProgressView(value: min(max(window.percent, 0), 100), total: 100).tint(Theme.accent)
                            if let resets = window.resetsAt.flatMap({ resetsIn($0) }) {
                                Text(resets).font(.system(size: 12)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    if let spend = report.spend {
                        Text("Extra usage: \(format(spend))").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                } else {
                    Text("No usage data on this machine.").foregroundStyle(Theme.muted)
                }
            }
        }
        .listRowBackground(Theme.panel)
        .task {
            guard let api = model.api else { return }
            do {
                report = try await api.usage()
                state = "ready"
            } catch {
                state = "error"
            }
        }
    }

    private func format(_ spend: UsageReport.Spend) -> String {
        let scale = pow(10, Double(spend.exponent))
        let style = FloatingPointFormatStyle<Double>.Currency(code: spend.currency)
        let used = (spend.used / scale).formatted(style)
        guard let limit = spend.limit else { return "\(used) used" }
        return "\(used) of \((limit / scale).formatted(style))"
    }
}
