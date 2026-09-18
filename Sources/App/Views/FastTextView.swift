import SwiftUI
import UIKit

struct FastTextView: UIViewRepresentable {
    let text: String

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
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }
}
