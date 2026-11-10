import PiOSCore
import SwiftUI

@main
struct PiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onChange(of: scenePhase) { _, phase in model.setScenePhase(phase) }
                .onOpenURL { url in openPairingLink(url) }
        }
    }

    /// `pios://host/#pt=...` is the printed link with its scheme swapped, so
    /// a QR code or a tapped link lands straight in the pairing sheet.
    private func openPairingLink(_ url: URL) {
        guard MachineAPI.parsePairingLink(url.absoluteString) != nil else { return }
        model.pendingPairingLink = url.absoluteString
        model.showPairing = true
    }
}

/// One list, two presentations: docked beside the chat on iPad, a stack on
/// iPhone. `NavigationSplitView` keeps the open chat and its draft mounted
/// across a rotation, so a resize is never a navigation event.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired {
                NavigationSplitView {
                    SessionListView()
                } detail: {
                    if let id = model.selection {
                        ChatView(sessionId: id).id(id)
                    } else {
                        ContentUnavailableView(
                            "No session open", systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("Pick a session or start a new one.")
                        )
                    }
                }
            } else {
                NavigationStack { PairingView() }
            }
        }
        .sheet(isPresented: $model.showPairing) {
            NavigationStack { PairingView() }
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.footnote)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if model.toast == toast { withAnimation { model.toast = nil } }
                }
        }
    }
}
