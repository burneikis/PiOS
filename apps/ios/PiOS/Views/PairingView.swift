import PiOSCore
import SwiftUI
import UIKit
import VisionKit

/// Pairs this phone with a machine running `pios-server`.
///
/// The printed link carries a one-shot token in its fragment; it is traded
/// for a long-lived device token, which goes straight to the Keychain.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var url = ""
    @State private var token = ""
    @State private var label = ""
    @State private var error: String? = nil
    @State private var busy = false
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pair with a machine").font(.title2.bold())
                    Text("Run `pios-server pair` on the machine, then scan its link as a QR code, paste it, or type the address and token.")
                        .font(.callout)
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Color.clear)
            }

            if let notice = model.pairingNotice {
                Section { Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warn) }
            }

            Section {
                Button {
                    if let text = UIPasteboard.general.string { apply(link: text) }
                } label: {
                    Label("Paste pairing link", systemImage: "doc.on.clipboard")
                }
                if DataScannerViewController.isSupported {
                    Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                }
            }

            Section("Machine") {
                TextField("https://pios-relay.you.workers.dev", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Pairing link or token", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: token) { _, value in apply(link: value) }
                TextField("Device label", text: $label)
            }

            if let error {
                Section { Text(error).foregroundStyle(Theme.error) }
            }

            Section {
                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        Text(busy ? "Pairing..." : "Pair")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy || token.trimmingCharacters(in: .whitespaces).isEmpty || url.isEmpty)
            }
        }
        .themedList()
        .navigationTitle("PiOS")
        .toolbar {
            if model.isPaired {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .sheet(isPresented: $scanning) {
            QRScanner { payload in
                scanning = false
                apply(link: payload)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            if label.isEmpty { label = UIDevice.current.name }
            if let link = model.pendingPairingLink {
                model.pendingPairingLink = nil
                apply(link: link)
            }
        }
    }

    private func apply(link: String) {
        guard let parsed = MachineAPI.parsePairingLink(link) else { return }
        url = parsed.origin.absoluteString
        token = parsed.token
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        guard let base = URL(string: url.trimmingCharacters(in: .whitespaces)), base.scheme != nil, base.host != nil else {
            error = "The machine URL is not valid, e.g. https://pios-relay.you.workers.dev"
            return
        }
        do {
            try await model.pair(url: base, pairingToken: token.trimmingCharacters(in: .whitespaces), label: label)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// VisionKit's live scanner, reporting the first QR payload it reads.
struct QRScanner: UIViewControllerRepresentable {
    var onScan: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScan: (String) -> Void
        private var done = false

        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            for case let .barcode(code) in items {
                guard !done, let payload = code.payloadStringValue else { continue }
                done = true
                scanner.stopScanning()
                onScan(payload)
            }
        }
    }
}
