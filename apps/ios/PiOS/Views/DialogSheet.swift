import PiOSCore
import SwiftUI

struct DialogAnswer {
    var value: String?
    var confirmed: Bool?
    var cancelled: Bool?
}

/// An extension dialog rendered natively. The agent is blocked until it is
/// answered here, on another device, or by the daemon's deadline.
struct DialogSheet: View {
    let request: ExtensionUiRequest
    let answer: (DialogAnswer) -> Void
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                if let message = request.message, !message.isEmpty {
                    Section { Text(stripAnsi(message)).textSelection(.enabled) }
                }
                switch request.method {
                case .select:
                    Section {
                        ForEach(request.options, id: \.self) { option in
                            Button(stripAnsi(option)) { answer(DialogAnswer(value: option)) }
                        }
                    }
                case .confirm:
                    Section {
                        Button("Yes") { answer(DialogAnswer(confirmed: true)) }
                        Button("No", role: .destructive) { answer(DialogAnswer(confirmed: false)) }
                    }
                case .input:
                    Section {
                        TextField(request.placeholder ?? "", text: $text)
                            .onSubmit { answer(DialogAnswer(value: text)) }
                        Button("Submit") { answer(DialogAnswer(value: text)) }
                    }
                case .editor:
                    Section {
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 240)
                        Button("Submit") { answer(DialogAnswer(value: text)) }
                    }
                default:
                    EmptyView()
                }
            }
            .navigationTitle(request.title.map(stripAnsi) ?? "Extension")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { answer(DialogAnswer(cancelled: true)) }
                }
            }
        }
        .interactiveDismissDisabled()
        .presentationDetents(request.method == .editor ? [.large] : [.medium, .large])
        .onAppear { text = request.prefill ?? "" }
    }
}
