import SwiftUI
import UIKit

/// Read-only text with real range selection. SwiftUI's `Text` on iOS can
/// only copy itself whole, which is useless for picking a line out of an
/// answer.
struct SelectableText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.dataDetectorTypes = []
        view.linkTextAttributes = [
            .foregroundColor: UIColor(Theme.text),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        view.tintColor = UIColor(Theme.link)
        // Let SwiftUI decide the width; the text wraps to whatever it gets.
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.attributedText = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Reassigning identical text would drop a selection mid-stream.
        if !view.attributedText.isEqual(to: text) {
            view.attributedText = text
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let proposed = proposal.width ?? .infinity
        let width = proposed.isFinite ? proposed : CGFloat.greatestFiniteMagnitude
        let fitted = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: proposed.isFinite ? proposed : ceil(fitted.width), height: ceil(fitted.height))
    }
}
