import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Owns the main window UI and drives the RegionSelector / ScreenRecorder.
final class AppController: NSObject {

    enum Mode {
        case idle
        case selecting
        case armed(RegionSelection)
        case recording(RegionSelection, startedAt: Date)
        case saved(RegionSelection, url: URL)
    }

    private var mode: Mode = .idle
    var isRecording: Bool {
        if case .recording = mode { return true }
        return false
    }

    private var window: NSWindow?
    private let regionLabel = NSTextField(labelWithString: "No region selected")
    private let selectButton = NSButton(title: "Select Region…", target: nil, action: nil)
    private let audioCheckbox = NSButton(checkboxWithTitle: "Include system audio", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let openButton = NSButton(title: "Play", target: nil, action: nil)
    private lazy var savedRow = NSStackView(views: [revealButton, openButton])

    private var overlays: RecordingOverlays?
    private let recorder = ScreenRecorder()
    private var elapsedTimer: Timer?
    private var lastSavedURL: URL?

    override init() {
        super.init()
        recorder.onStreamError = { [weak self] message in
            self?.recordingEndedUnexpectedly(message)
        }
    }

    // MARK: - UI

    func showMainWindow() {
        if let window {
            window.makeKeyAndOrderFront(self)
            return
        }

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 330),
                         styleMask: [.titled, .closable, .miniaturizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Mac Screen Recorder"
        w.isRestorable = false
        w.center()
        window = w

        let titleLabel = NSTextField(labelWithString: "Mac Screen Recorder")
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)
        let subtitleLabel = NSTextField(labelWithString: "Record a region of your screen with system audio.")
        subtitleLabel.font = .systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        regionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        regionLabel.textColor = .secondaryLabelColor

        selectButton.bezelStyle = .rounded
        selectButton.target = self
        selectButton.action = #selector(selectRegionAction)

        audioCheckbox.state = .on

        recordButton.bezelStyle = .rounded
        recordButton.font = .systemFont(ofSize: 13, weight: .semibold)
        recordButton.keyEquivalent = "\r"
        recordButton.keyEquivalentModifierMask = [.command]
        recordButton.target = self
        recordButton.action = #selector(toggleRecordingAction)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1

        for button in [revealButton, openButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        revealButton.target = self
        revealButton.action = #selector(revealAction)
        openButton.target = self
        openButton.action = #selector(openAction)

        savedRow.orientation = .horizontal
        savedRow.spacing = 8

        let regionRow = NSStackView(views: [selectButton, regionLabel])
        regionRow.orientation = .horizontal
        regionRow.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            regionRow,
            audioCheckbox,
            recordButton,
            statusLabel,
            savedRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        if let content = w.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                stack.topAnchor.constraint(equalTo: content.topAnchor),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }

        w.makeKeyAndOrderFront(self)
        render()
    }

    @objc func showMainWindowAction() {
        showMainWindow()
    }

    // MARK: - Actions

    @objc func selectRegionAction() {
        guard !isRecording else { return }

        var previous: RegionSelection?
        if case let .armed(sel) = mode { previous = sel }
        if case let .saved(sel, _) = mode { previous = sel }

        setMode(.selecting)
        overlays?.dismiss()
        overlays = nil

        RegionSelector.begin { [weak self] selection in
            guard let self else { return }
            if let selection {
                self.setMode(.armed(selection))
                self.showOverlays(for: selection, recording: false)
            } else if let prev = previous {
                self.setMode(.armed(prev))
                self.showOverlays(for: prev, recording: false)
            } else {
                self.setMode(.idle)
            }
        }
    }

    @objc func toggleRecordingAction() {
        if isRecording {
            stopRecording()
            return
        }
        guard case let .armed(selection) = mode else { return }

        let scale = selection.scale
        let spec = RegionSpec(
            displayID: selection.displayID,
            sourceRect: selection.rect,
            pixelWidth: Self.evenPixels(selection.rect.width * scale),
            pixelHeight: Self.evenPixels(selection.rect.height * scale))

        let includeAudio = audioCheckbox.state == .on

        Task { @MainActor in
            do {
                try await recorder.start(region: spec, includeSystemAudio: includeAudio)
                self.setMode(.recording(selection, startedAt: Date()))
                self.overlays?.update(recording: true)
                self.startTimer()
            } catch {
                self.setMode(.armed(selection))
                self.presentError(error)
            }
        }
    }

    func stopRecording() {
        guard case let .recording(selection, _) = mode else { return }
        stopTimer()

        Task { @MainActor in
            do {
                let url = try await recorder.stop()
                self.lastSavedURL = url
                self.setMode(.saved(selection, url: url))
                self.overlays?.update(recording: false)
            } catch {
                self.setMode(.armed(selection))
                self.overlays?.update(recording: false)
                self.presentError(error)
            }
        }
    }

    @objc private func revealAction() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openAction() {
        guard let url = lastSavedURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Called from applicationShouldTerminate while a recording is active.
    func finishForTermination() {
        stopTimer()
        Task { @MainActor in
            _ = try? await recorder.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    // MARK: - Self test (development)

    /// The currently selected region, for tests/diagnostics.
    func regionForTesting() -> RegionSelection? {
        if case let .armed(sel) = mode { return sel }
        if case let .recording(sel, _) = mode { return sel }
        if case let .saved(sel, _) = mode { return sel }
        return nil
    }

    /// UI test: exercises the real region-selection flow (overlay, drag,
    /// dismissal, coordinate conversion) and then records 3 seconds through
    /// the GUI-produced region. Run with: MacScreenRec --uitest-select
    func runSelectUITest() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { exit(1) }
            self.selectRegionAction()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, let screen = NSScreen.main else {
                    print("UITEST: no main screen")
                    exit(1)
                }
                let ok = RegionSelector.simulateSelection(
                    from: CGPoint(x: 120, y: 140),
                    to: CGPoint(x: 600, y: 500),
                    screen: screen)
                guard ok else {
                    print("UITEST: selection overlay was not available")
                    exit(1)
                }
                guard RegionSelector.isSelecting == false else {
                    print("UITEST: overlay did not dismiss after mouseUp")
                    exit(1)
                }
                guard let sel = self.regionForTesting() else {
                    print("UITEST: no region selected after drag")
                    exit(1)
                }
                // A drag from (120,140) to (600,500) in the display's top-left
                // space must produce exactly that rect in ScreenCaptureKit's
                // top-left sourceRect space.
                guard abs(sel.rect.minX - 120) < 0.01,
                      abs(sel.rect.minY - 140) < 0.01,
                      abs(sel.rect.width - 480) < 0.01,
                      abs(sel.rect.height - 360) < 0.01 else {
                    print("UITEST: region mismatch — got \(sel.rect), expected (120, 140, 480, 360)")
                    exit(1)
                }
                print("UITEST: selection OK — overlays dismissed, region=\(sel.rect)")

                Task { @MainActor in
                    do {
                        let spec = RegionSpec(
                            displayID: sel.displayID,
                            sourceRect: sel.rect,
                            pixelWidth: Self.evenPixels(sel.rect.width * sel.scale),
                            pixelHeight: Self.evenPixels(sel.rect.height * sel.scale))
                        try await self.recorder.start(region: spec, includeSystemAudio: true)
                        print("UITEST: recording 3 s…")
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        let url = try await self.recorder.stop()
                        print("UITEST-DONE \(url.path)")
                        exit(0)
                    } catch {
                        print("UITEST-ERROR \(error.localizedDescription)")
                        exit(1)
                    }
                }
            }
        }
    }

    /// Headless end-to-end test: records a fixed 480×360 region of the main
    /// display for 6 seconds with system audio and prints the file path.
    /// Run with: MacScreenRec --selftest
    func runSelfTest() {
        Task { @MainActor in
            print("SELFTEST: waiting for Screen Recording permission…")
            let granted = await ScreenRecorder.requestPermission(timeout: 90)
            guard granted else {
                print("SELFTEST: DENIED — grant Screen Recording permission and retry")
                exit(1)
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    print("SELFTEST: main display not found")
                    exit(1)
                }
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                var rect = CGRect(x: 120, y: 140, width: 480, height: 360)
                if let spec = ProcessInfo.processInfo.environment["MAC_SCREEN_REC_TEST_REGION"],
                   let parsed = Self.parseRegionSpec(spec) {
                    rect = parsed
                }
                let spec = RegionSpec(
                    displayID: display.displayID,
                    sourceRect: rect,
                    pixelWidth: Self.evenPixels(rect.width * scale),
                    pixelHeight: Self.evenPixels(rect.height * scale))

                try await recorder.start(region: spec, includeSystemAudio: true)
                print("SELFTEST: recording 6 s…")
                try await Task.sleep(nanoseconds: 6_000_000_000)
                let url = try await recorder.stop()
                print("SELFTEST-DONE \(url.path)")
                exit(0)
            } catch {
                print("SELFTEST-ERROR \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, case let .recording(_, startedAt) = self.mode else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            self.overlays?.setElapsed(elapsed)
            self.recordButton.title = "Stop  \(RecordingOverlays.elapsedString(elapsed))"
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func stopTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    // MARK: - State / rendering

    private func setMode(_ newMode: Mode) {
        mode = newMode
        render()
    }

    private func showOverlays(for selection: RegionSelection, recording: Bool) {
        overlays?.dismiss()
        let o = RecordingOverlays(region: selection)
        o.onStop = { [weak self] in self?.stopRecording() }
        o.update(recording: recording)
        overlays = o
    }

    private func render() {
        switch mode {
        case .idle:
            regionLabel.stringValue = "No region selected"
            recordButton.isEnabled = false
            recordButton.title = "Record"
            savedRow.isHidden = true
            statusLabel.stringValue = ""
        case .selecting:
            recordButton.isEnabled = false
            savedRow.isHidden = true
        case .armed(let sel):
            regionLabel.stringValue = "\(Int(sel.rect.width)) × \(Int(sel.rect.height)) pt — \(sel.screen.localizedName)"
            recordButton.isEnabled = true
            recordButton.title = "Record"
            savedRow.isHidden = true
            statusLabel.stringValue = ""
        case .recording:
            recordButton.isEnabled = true
            recordButton.title = "Stop  00:00"
            savedRow.isHidden = true
        case .saved(let sel, let url):
            regionLabel.stringValue = "\(Int(sel.rect.width)) × \(Int(sel.rect.height)) pt — \(sel.screen.localizedName)"
            recordButton.isEnabled = true
            recordButton.title = "Record again"
            savedRow.isHidden = false
            statusLabel.stringValue = url.lastPathComponent
            statusLabel.toolTip = url.path
        }
    }

    // MARK: - Errors

    private func recordingEndedUnexpectedly(_ message: String) {
        guard isRecording else { return }
        stopTimer()

        var previous: RegionSelection?
        if case let .recording(sel, _) = mode { previous = sel }
        if let sel = previous {
            setMode(.armed(sel))
            overlays?.update(recording: false)
        }

        let alert = NSAlert()
        alert.messageText = "Recording ended unexpectedly"
        alert.informativeText = message
        alert.runModal()
    }

    private func presentError(_ error: Error) {
        if let recError = error as? ScreenRecorder.RecorderError,
           case .permissionRequired = recError {
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = """
                “Mac Screen Recorder” needs Screen Recording access to capture \
                video and system audio.

                Open System Settings → Privacy & Security → Screen & System Audio \
                Recording (on some versions: Screen Recording), enable it for this \
                app, then click Record again.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private static func parseRegionSpec(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        let px = max(2, Int(value.rounded()))
        return px - px % 2
    }
}
