import SwiftUI
import UIKit

struct FastTextView: UIViewRepresentable {
    let text: String
    var wrapsLines: Bool = true

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.backgroundColor = .systemBackground
        tv.textColor = .label
        tv.font = UIFont.monospacedSystemFont(ofSize: 11.0, weight: .regular)
        tv.showsHorizontalScrollIndicator = true
        tv.showsVerticalScrollIndicator = true
        tv.alwaysBounceVertical = true
        tv.contentInset = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        configureLineWrapping(for: tv)
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        configureLineWrapping(for: uiView)
        if uiView.text != text {
            uiView.text = text
        }
    }

    private func configureLineWrapping(for textView: UITextView) {
        textView.textContainer.widthTracksTextView = wrapsLines
        textView.textContainer.lineBreakMode = wrapsLines ? .byWordWrapping : .byClipping
        if !wrapsLines {
            textView.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        textView.setNeedsLayout()
    }
}
