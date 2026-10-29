import AppKit
import SwiftUI

/// Puts the enclosing scroll view on macOS's thin overlay scrollers. With a mouse attached
/// `.scrollIndicators(.visible)` draws the wide legacy scroller, which crowded the
/// 질문 드롭다운. Goes on the scroll view's content.
struct ThinScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The scroll view adopts this view only once it is in the hierarchy.
        DispatchQueue.main.async {
            guard let scrollView = view.enclosingScrollView, scrollView.scrollerStyle != .overlay else { return }
            scrollView.scrollerStyle = .overlay
            scrollView.scrollerKnobStyle = .light
        }
    }
}
