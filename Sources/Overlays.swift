import AppKit

/// On-screen furniture around the selected region: a colored frame plus a
/// floating control bar with the timer and Stop button. These windows belong
/// to this app, and the capture filter excludes the app's windows, so they
/// never appear in the recording.
final class RecordingOverlays: NSObject {

    private let border: NSWindow
    private let bar: NSPanel
    private let borderView = RegionBorderView(frame: .zero)
    private let timerField: NSTextField
    private let regionRect: NSRect   // AppKit global rect of the region
    private let screen: NSScreen

    var onStop: (() -> Void)?

    init(region: RegionSelection) {
        screen = region.screen
        regionRect = Self.globalAppKitRect(for: region)
        timerField = NSTextField(labelWithString: "00:00")

        // Frame exactly around the region.
        border = NSWindow(contentRect: regionRect,
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        border.backgroundColor = .clear
        border.isOpaque = false
        border.hasShadow = false
        border.level = .floating
        border.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        border.ignoresMouseEvents = true
        border.isReleasedWhenClosed = false
        border.contentView = borderView

        // Floating control bar.
        let barSize = NSSize(width: 250, height: 48)
        bar = NSPanel(contentRect: NSRect(origin: .zero, size: barSize),
                      styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered,
                      defer: false)
        bar.backgroundColor = .clear
        bar.isOpaque = false
        bar.hasShadow = true
        bar.isFloatingPanel = true
        bar.level = .floating
        bar.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        bar.hidesOnDeactivate = false
        bar.isReleasedWhenClosed = false
        bar.animationBehavior = .utilityWindow

        super.init()

        buildBarContent(barSize: barSize)
        positionBar()
    }

    private func buildBarContent(barSize: NSSize) {
        let visual = NSVisualEffectView(frame: NSRect(origin: .zero, size: barSize))
        visual.material = .hudWindow
        visual.blendingMode = .behindWindow
        visual.state = .active
        visual.wantsLayer = true
        visual.layer?.cornerRadius = 10
        visual.layer?.masksToBounds = true

        timerField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        timerField.textColor = .white

        let dot = DotView(frame: NSRect(x: 0, y: 0, width: 12, height: 12))
        let stopButton = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = .systemFont(ofSize: 12, weight: .semibold)

        let stack = NSStackView(views: [dot, timerField, stopButton])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        visual.addSubview(stack)

        if let barContent = bar.contentView {
            barContent.addSubview(visual)
            NSLayoutConstraint.activate([
                visual.leadingAnchor.constraint(equalTo: barContent.leadingAnchor),
                visual.trailingAnchor.constraint(equalTo: barContent.trailingAnchor),
                visual.topAnchor.constraint(equalTo: barContent.topAnchor),
                visual.bottomAnchor.constraint(equalTo: barContent.bottomAnchor),
                stack.centerXAnchor.constraint(equalTo: visual.centerXAnchor),
                stack.centerYAnchor.constraint(equalTo: visual.centerYAnchor),
            ])
        }
    }

    @objc private func stopClicked() {
        onStop?()
    }

    func update(recording: Bool) {
        borderView.recording = recording
        if !border.isVisible { border.orderFrontRegardless() }
        if recording {
            if !bar.isVisible { bar.orderFrontRegardless() }
        } else {
            bar.orderOut(nil)   // control bar only while recording
        }
    }

    func setElapsed(_ seconds: TimeInterval) {
        timerField.stringValue = Self.elapsedString(seconds)
    }

    func dismiss() {
        border.orderOut(nil)
        bar.orderOut(nil)
    }

    static func elapsedString(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// Convert the display-local, top-left-origin region rect into an AppKit
    /// global window frame (bottom-left-origin coordinates).
    static func globalAppKitRect(for region: RegionSelection) -> NSRect {
        let f = region.screen.frame
        let local = NSRect(
            x: region.rect.minX,
            y: f.height - region.rect.maxY,
            width: region.rect.width,
            height: region.rect.height)
        return NSRect(
            origin: NSPoint(x: f.minX + local.minX, y: f.minY + local.minY),
            size: local.size)
    }

    private func positionBar() {
        let size = bar.frame.size
        let visible = screen.visibleFrame
        var origin = NSPoint(x: regionRect.midX - size.width / 2,
                             y: regionRect.minY - size.height - 10)
        if origin.y < visible.minY {
            origin.y = min(regionRect.maxY + 10, visible.maxY - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        bar.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - Views

private final class RegionBorderView: NSView {
    var recording = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = NSBezierPath(rect: inset)
        path.lineWidth = 3

        let stroke = recording ? NSColor.systemRed : NSColor.white.withAlphaComponent(0.75)
        stroke.setStroke()
        if !recording {
            path.setLineDash([8, 5], count: 2, phase: 0)
        }
        path.stroke()

        // Corner handles.
        let c: CGFloat = 8
        stroke.setFill()
        NSRect(x: inset.minX - c / 2, y: inset.minY - c / 2, width: c, height: c).fill()
        NSRect(x: inset.maxX - c / 2, y: inset.minY - c / 2, width: c, height: c).fill()
        NSRect(x: inset.minX - c / 2, y: inset.maxY - c / 2, width: c, height: c).fill()
        NSRect(x: inset.maxX - c / 2, y: inset.maxY - c / 2, width: c, height: c).fill()
    }
}

private final class DotView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}
