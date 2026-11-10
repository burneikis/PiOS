import PiOSCore
import SwiftUI
import UIKit

/// The session's model scope first; the whole catalogue only when asked for,
/// because it is hundreds of rows on a phone.
struct ModelPicker: View {
    let sessionId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var all = false
    @State private var query = ""

    var body: some View {
        let listing = model.modelsFor(sessionId)
        let current = model.summary(sessionId)?.model
        let models = listing.models.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
        List {
            if listing.models.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(models) { option in
                Button {
                    model.client.setModel(sessionId, provider: option.provider, modelId: option.modelId)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(option.name)
                            Text(option.id).font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        if option.id == current?.id { Image(systemName: "checkmark") }
                    }
                }
                .foregroundStyle(.primary)
            }
            if !listing.all {
                Button("Show all models") { all = true }
            }
        }
        .searchable(text: $query)
        .themedList()
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task(id: all) {
            model.client.listModels(sessionId, all: all, create: model.create(for: sessionId))
        }
    }
}

/// Levels the current model accepts; they travel with the summary because
/// they change with the model.
struct ThinkingPicker: View {
    let sessionId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let summary = model.summary(sessionId)
        List(summary?.thinkingLevels ?? [], id: \.self) { level in
            Button {
                model.client.setThinkingLevel(sessionId, level)
                dismiss()
            } label: {
                HStack {
                    Text(level.capitalized)
                    Spacer()
                    if level == summary?.thinkingLevel { Image(systemName: "checkmark") }
                }
            }
            .foregroundStyle(.primary)
        }
        .themedList()
        .navigationTitle("Thinking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}

struct SessionInfoView: View {
    let sessionId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let summary = model.summary(sessionId)
        let stats = model.statsFor(sessionId)
        Form {
            if let summary {
                Section("Session") {
                    LabeledContent("Name", value: summary.name ?? "-")
                    LabeledContent("Directory", value: collapseHome(summary.cwd))
                    LabeledContent("Status", value: summary.status.rawValue)
                    LabeledContent("Model", value: summary.model?.name ?? "-")
                    LabeledContent("Thinking", value: summary.thinkingLevel ?? "-")
                    LabeledContent("Trusted", value: summary.trusted ? "yes" : "no")
                    Toggle("Auto-compaction", isOn: Binding(
                        get: { summary.autoCompaction ?? true },
                        set: { model.client.setAutoCompaction(sessionId, $0) }
                    ))
                    Button("Copy session id") { UIPasteboard.general.string = sessionId }
                }
            }
            if let stats {
                Section("Usage") {
                    if let percent = stats.contextPercent, let window = stats.contextWindow {
                        LabeledContent("Context", value: "\(Int(percent.rounded()))% of \(compactNumber(window))")
                    }
                    if let input = stats.tokensInput { LabeledContent("Input tokens", value: compactNumber(input)) }
                    if let output = stats.tokensOutput { LabeledContent("Output tokens", value: compactNumber(output)) }
                    if let read = stats.tokensCacheRead { LabeledContent("Cache read", value: compactNumber(read)) }
                    if let cost = stats.cost { LabeledContent("Cost", value: String(format: "$%.4f", cost)) }
                    if let calls = stats.toolCalls { LabeledContent("Tool calls", value: "\(calls)") }
                }
            }
        }
        .themedList()
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { model.client.requestStats(sessionId) }
    }
}
