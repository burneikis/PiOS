import PiOSCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("pios.showThinking") private var showThinking = true
    @AppStorage("pios.expandTools") private var expandTools = false
    @AppStorage("pios.showStats") private var showStats = false
    @AppStorage("pios.steeringMode") private var steeringMode = StreamingBehavior.steer.rawValue
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
