import PiOSCore
import SwiftUI

/// Where a new session runs. Rooted at home on the daemon, ordered by the
/// most recent pi work below each directory.
struct DirectoryPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirectoryListing? = nil
    @State private var path: String? = nil
    @State private var error: String? = nil
    @State private var trust = false

    var body: some View {
        List {
            if let listing {
                Section {
                    Toggle(isOn: $trust) {
                        VStack(alignment: .leading) {
                            Text("Trust this project")
                            Text("Loads project-local extensions, settings and packages.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        model.newDraft(cwd: listing.path, trustProject: trust)
                        dismiss()
                    } label: {
                        Label("Start in \(collapseHome(listing.path))", systemImage: "play.fill")
                    }
                }
                Section {
                    if let parent = listing.parent {
                        Button { path = parent } label: { Label("..", systemImage: "arrow.up") }
                    }
                    ForEach(listing.entries) { entry in
                        Button { path = entry.path } label: {
                            HStack {
                                Label(entry.name, systemImage: "folder")
                                Spacer()
                                if let at = entry.lastSessionAt {
                                    Text(relativeTime(at)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .navigationTitle(listing.map { $0.name } ?? "New session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            listing = try await api.directories(path: path)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
