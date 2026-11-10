import PiOSCore
import SwiftUI
import UIKit

@main
struct PiOSApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onChange(of: scenePhase) { _, phase in model.setScenePhase(phase) }
                .onOpenURL { url in openPairingLink(url) }
        }
        // Collects what the daemon's inbox holds for this device.
        .backgroundTask(.appRefresh(Notifications.refreshTask)) { [model] in
            await model.backgroundRefresh()
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

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.isPaired {
                Workspace()
            } else {
                NavigationStack { PairingView() }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $model.showPairing) {
            NavigationStack { PairingView() }
        }
        .sheet(isPresented: $model.showSettings) {
            NavigationStack { SettingsView() }
        }
        .sheet(item: Binding(
            get: { model.pickerStart.map(PickerStart.init) },
            set: { model.pickerStart = $0?.path }
        )) { start in
            NavigationStack { DirectoryPicker(start: start.path.isEmpty ? nil : start.path) }
        }
        .sheet(item: $model.sharedFile) { file in
            ShareSheet(items: [file.url]).ignoresSafeArea()
        }
        .overlay(alignment: .top) { ToastView() }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private struct PickerStart: Identifiable {
    var path: String
    var id: String { path }
}

/// One list, two presentations, as in the PWA: docked beside the chat when
/// there is room, a drawer over it when there is not. The chat stays mounted
/// either way, so opening the list is never a navigation event and a
/// rotation loses neither the draft nor the scroll position.
struct Workspace: View {
    @Environment(AppModel.self) private var model
    /// Drag translation in points; positive pulls the drawer open.
    @State private var drag: CGFloat = 0

    /// The PWA's breakpoint.
    private static let dockWidth: CGFloat = 720

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > Self.dockWidth {
                docked
            } else {
                narrow(width: geo.size.width)
            }
        }
    }

    private var docked: some View {
        HStack(spacing: 0) {
            if model.sidebarVisible {
                Sidebar()
                    .frame(width: 320)
                    .transition(.move(edge: .leading))
                Rectangle().fill(Theme.line).frame(width: 1).ignoresSafeArea()
            }
            detail(docked: true)
        }
        .animation(.snappy, value: model.sidebarVisible)
    }

    @ViewBuilder
    private func narrow(width: CGFloat) -> some View {
        if model.selection == nil {
            Sidebar()
        } else {
            let drawerWidth = min(width * 0.86, 360)
            let progress = min(max((model.drawerOpen ? 1 : 0) + drag / drawerWidth, 0), 1)
            ZStack(alignment: .leading) {
                detail(docked: false)

                // Pulled from the leading edge, as the PWA's edge swipe.
                // Below the bar, so it never covers the back button, and
                // only on the chat itself: over a pushed screen the edge
                // belongs to the system's swipe back.
                if model.path.isEmpty {
                    Color.clear
                        .frame(width: 16)
                        .frame(maxHeight: .infinity)
                        .padding(.top, 110)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(width: drawerWidth))
                        .allowsHitTesting(!model.drawerOpen)
                }

                // Taps outside the drawer dismiss it without reaching the chat.
                Color.black
                    .opacity(0.45 * progress)
                    .ignoresSafeArea()
                    .allowsHitTesting(progress > 0)
                    .onTapGesture { close() }

                Sidebar()
                    .frame(width: drawerWidth)
                    .background(Theme.bg.ignoresSafeArea())
                    .shadow(color: .black.opacity(0.55 * progress), radius: 40)
                    .offset(x: -drawerWidth * (1 - progress))
                    // Simultaneous, so the list still scrolls under a vertical drag.
                    .simultaneousGesture(dragGesture(width: drawerWidth))
                    .accessibilityHidden(progress == 0)
            }
            .animation(.snappy(duration: 0.22), value: model.drawerOpen)
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                // Horizontal intent only: a scroll in the list is not a pull.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                drag = value.translation.width
            }
            .onEnded { value in
                guard drag != 0 else { return }
                let predicted = (model.drawerOpen ? 1 : 0) + value.predictedEndTranslation.width / width
                model.drawerOpen = predicted > 0.5
                drag = 0
            }
    }

    private func close() {
        model.drawerOpen = false
    }

    @ViewBuilder
    private func detail(docked: Bool) -> some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            if let id = model.selection {
                ChatView(sessionId: id, docked: docked).id(id)
            } else {
                EmptyDetail(docked: docked)
            }
        }
    }
}

struct EmptyDetail: View {
    let docked: Bool
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            ConnectionBanner()
            Text("Pick a session or start a new one.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .toolbar {
            if docked, !model.sidebarVisible {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.sidebarVisible = true } label: { Image(systemName: "sidebar.left") }
                }
            }
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassSurface(cornerRadius: 18)
                .padding(.top, 8)
                .padding(.horizontal)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onTapGesture { model.toast = nil }
                .task(id: toast) {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if model.toast == toast { withAnimation { model.toast = nil } }
                }
        }
    }
}
