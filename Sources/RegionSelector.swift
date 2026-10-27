import AppKit
import CoreGraphics

/// A region chosen by the user, expressed in the coordinate space
/// ScreenCaptureKit expects for `sourceRect`: display-local points with a
/// top-left origin.
struct RegionSelection {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let rect: CGRect      // display-local, top-left origin, points
    let scale: CGFloat    // backing scale factor
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
    }
}

/// Full-screen overlay per display; drag a rectangle to choose the region.
/// Esc or right-click cancels.
final class RegionSelector: NSObject {

    static func begin(completion: @escaping (RegionSelection?) -> Void) {
        DispatchQueue.main.async {
            guard Self.active == nil else { return }
            let selector = RegionSelector(completion: completion)
            Self.active = selector   // strong: keeps the selector alive while
                                      // its overlay windows are on screen
            selector.show()
        }
    }

    static var isSelecting: Bool { active != nil }

    /// Dev/testing: frames of the current overlay windows.
    static var debugOverlayFrames: [NSRect] {
        active?.overlays.map(\.frame) ?? []
    }

    /// Dev/testing hook: synthesizes a drag on the overlay covering `screen`,
    /// with points in that display's top-left coordinate space. Returns false
    /// if no selection is in progress.
    static func simulateSelection(from start: CGPoint, to end: CGPoint, screen: NSScreen) -> Bool {
        guard let selector = active,
              let overlay = selector.overlays.first(where: { $0.frame == screen.frame }),
              let view = overlay.contentView as? OverlayView else { return false }

        func event(_ type: NSEvent.EventType, at viewPoint: NSPoint) -> NSEvent? {
            // The content view fills this borderless window, so window
            // coordinates are view coordinates.
            return NSEvent.mouseEvent(
                with: type,
                location: viewPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: overlay.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1)
        }
        func viewPoint(_ p: CGPoint) -> NSPoint {
            // translate top-left-origin points into the (unflipped) view space
            NSPoint(x: p.x, y: view.bounds.height - p.y)
        }

        guard let down = event(.leftMouseDown, at: viewPoint(start)),
              let drag = event(.leftMouseDragged, at: viewPoint(CGPoint(
                x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))),
              let up = event(.leftMouseUp, at: viewPoint(end)) else { return false }

        view.mouseDown(with: down)
        view.mouseDragged(with: drag)
        view.mouseUp(with: up)
        return true
    }

    /// The in-progress selector. Must be strong: the overlay windows capture
    /// the selector weakly, so this is the only thing keeping it alive.
    private static var active: RegionSelector?

    private let completion: (RegionSelection?) -> Void
    private var overlays: [OverlayWindow] = []
    private var finished = false

    private init(completion: @escaping (RegionSelection?) -> Void) {
        self.completion = completion
        super.init()
    }

    private func show() {
        NSCursor.crosshair.push()
        for screen in NSScreen.screens {
            let overlay = OverlayWindow(screen: screen) { [weak self] rect in
                self?.finish(rect: rect, screen: screen)
            }
            overlays.append(overlay)
        }
        overlays.first?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func finish(rect: CGRect?, screen: NSScreen) {
        guard !finished else { return }
        finished = true
        Self.active = nil

        for overlay in overlays { overlay.close() }
        overlays.removeAll()
        NSCursor.pop()

        guard let rect, rect.width >= 8, rect.height >= 8 else {
            completion(nil)
            return
        }

        // Convert the AppKit screen-local rect (bottom-left origin) to the
        // display-local top-left-origin space of ScreenCaptureKit.
        let cgRect = CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height)

        completion(RegionSelection(
            screen: screen,
            displayID: screen.displayID,
            rect: cgRect,
            scale: screen.backingScaleFactor))
    }
}

// MARK: - Overlay window / view

private final class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    init(screen: NSScreen, onResult: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false

        let view = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onResult = onResult
        contentView = view
        orderFrontRegardless()
    }
}

private final class OverlayView: NSView {
    var onResult: ((CGRect?) -> Void)?
    private var start: NSPoint?
    private var current: NSPoint?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var selectionRect: NSRect? {
        guard let start, let current else { return nil }
        let minX = Swift.min(start.x, current.x), maxX = Swift.max(start.x, current.x)
        let minY = Swift.min(start.y, current.y), maxY = Swift.max(start.y, current.y)
        var rect = NSRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        rect = rect.intersection(bounds)
        if rect.isNull || rect.width <= 0 || rect.height <= 0 { return nil }
        return rect
    }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.32)

        if let rect = selectionRect {
            dim.setFill()
            // Dim everything outside the selection.
            NSRect(x: 0, y: rect.maxY, width: bounds.width, height: bounds.height - rect.maxY).fill()
            NSRect(x: 0, y: 0, width: bounds.width, height: rect.minY).fill()
            NSRect(x: 0, y: rect.minY, width: rect.minX, height: rect.height).fill()
            NSRect(x: rect.maxX, y: rect.minY, width: bounds.width - rect.maxX, height: rect.height).fill()

            // Selection frame.
            NSColor.white.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()

            // Size badge.
            let text = "\(Int(rect.width)) × \(Int(rect.height)) pt"
            drawBadge(text, near: rect)
        } else {
            dim.setFill()
            bounds.fill()
            let text = "Drag to select a region — Esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            ]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2),
                      withAttributes: attrs)
        }
    }

    private func drawBadge(_ text: String, near rect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attrs)
        var origin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height > bounds.maxY {
            origin.y = rect.minY - size.height - 6
        }
        let bgRect = NSRect(x: origin.x - 4, y: origin.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.65).setFill()
        bgRect.fill()
        text.draw(at: origin, withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        start = convert(event.locationInWindow, from: nil)
        current = start
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        current = convert(event.locationInWindow, from: nil)   // release point
        let rect = selectionRect
        start = nil
        current = nil
        onResult?(rect)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onResult?(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onResult?(nil)
    }
}
