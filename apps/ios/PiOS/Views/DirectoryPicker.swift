import PiOSCore
import SwiftUI

/// Where a new session runs. Rooted at home on the daemon, ordered by the
/// most recent pi work below each directory; opens on the current session's
/// directory, since a second agent on the same project is the common case.
struct DirectoryPicker: View {
    let start: String?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirectoryListing? = nil
    /// Nil until the user walks somewhere; `start` applies until then.
    @State private var path: String? = nil
    @State private var error: String? = nil
    @State private var trust = false

    var body: some View {
        List {
            if let listing {
                Section {
                    Text(collapseHome(listing.path))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .listRowBackground(Color.clear)
                    Toggle("Trust this directory", isOn: $trust)
                        .listRowBackground(Theme.panel)
                } footer: {
                    Text("Trusted projects load their own extensions, settings and packages.")
                        .foregroundStyle(Theme.muted)
                }
                Section {
                    if let parent = listing.parent {
                        Button { path = parent } label: { Label("..", systemImage: "arrow.up") }
                            .listRowBackground(Theme.panel)
                    }
                    ForEach(listing.entries) { entry in
                        Button { path = entry.path } label: {
                            HStack {
                                Label(entry.name, systemImage: "folder").foregroundStyle(Theme.text)
                                Spacer()
                                if let at = entry.lastSessionAt {
                                    Text(listTime(at)).font(.system(size: 12)).foregroundStyle(Theme.muted)
                                }
                            }
                        }
                        .listRowBackground(Theme.panel)
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(Theme.error).listRowBackground(Color.clear)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            }
        }
        .themedList()
        .foregroundStyle(Theme.text)
        .navigationTitle(listing?.name ?? "New session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Start here") {
                    guard let listing else { return }
                    model.newDraft(cwd: listing.path, trustProject: trust)
                    dismiss()
                }
                .disabled(listing == nil)
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let api = model.api else { return }
        do {
            listing = try await api.directories(path: path ?? start)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
