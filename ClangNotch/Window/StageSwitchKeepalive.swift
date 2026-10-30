import AppKit
import Metal
import QuartzCore

/// An invisible 1pt Metal layer that keeps the notch animating through Stage Manager switches.
///
/// While Stage Manager swaps stages, WindowServer stops showing new frames from other apps'
/// windows: the glow froze for 0.1–0.7s on every app switch even though the app kept
/// drawing (measured 2026-10-30). A window that holds a Metal layer which has presented a
/// drawable is exempt, and so is everything else in it. One transparent present is enough;
/// level, collection behavior and a private CGS space all made no difference.
final class StageSwitchKeepalive: NSView {
    private let metalLayer = CAMetalLayer()
    private let queue: MTLCommandQueue?

    override init(frame: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init(frame: frame)
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.drawableSize = CGSize(width: 2, height: 2)
        layer = metalLayer
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        presentClearFrame()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        presentClearFrame()
    }

    private func presentClearFrame() {
        guard window != nil, let queue, let drawable = metalLayer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
