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
        case saved(URL)
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
    private let hotkeyLabel = NSTextField(labelWithString: "Stop hotkey:")
    private let hotkeyButton = NSButton(title: "esc", target: nil, action: nil)
    private let recordButton = NSButton(title: "Record", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let openButton = NSButton(title: "Play", target: nil, action: nil)
    private lazy var savedRow = NSStackView(views: [revealButton, openButton])

    private var overlays: RecordingOverlays?
    private let recorder = ScreenRecorder()
    private let hotkeyCenter = HotkeyCenter()
    private var elapsedTimer: Timer?
    private var lastSavedURL: URL?
    private var stopInFlight = false

    // Stop-hotkey configuration (persisted in UserDefaults).
    private var stopHotkeyCode: UInt32 = HotkeyCenter.defaultKeyCode
    private var stopHotkeyModifiers: UInt32 = HotkeyCenter.defaultModifiers
    private var capturingHotkey = false
    private var captureMonitor: Any?

    private enum DefaultsKeys {
        static let keyCode = "stopHotkeyCode"
        static let modifiers = "stopHotkeyModifiers"
    }

    override init() {
        super.init()
        loadHotkey()
        hotkeyCenter.onTrigger = { [weak self] in self?.stopRecording() }
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

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 360),
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

        hotkeyLabel.font = .systemFont(ofSize: 12)
        hotkeyLabel.textColor = .secondaryLabelColor
        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.controlSize = .small
        hotkeyButton.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hotkeyButton.target = self
        hotkeyButton.action = #selector(hotkeyButtonClicked)
        updateHotkeyButtonTitle()

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

        let hotkeyRow = NSStackView(views: [hotkeyLabel, hotkeyButton])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        let stack = NSStackView(views: [
            titleLabel,
            subtitleLabel,
            regionRow,
            audioCheckbox,
            hotkeyRow,
            recordButton,
            statusLabel,
            savedRow,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 11
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
        cancelHotkeyCapture()

        var previous: RegionSelection?
        if case let .armed(sel) = mode { previous = sel }

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
        cancelHotkeyCapture()

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
                if !hotkeyCenter.register(keyCode: stopHotkeyCode, carbonModifiers: stopHotkeyModifiers) {
                    statusLabel.stringValue = "Stop hotkey unavailable — use the Stop button"
                }
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
        guard !stopInFlight, case let .recording(selection, _) = mode else { return }
        stopInFlight = true
        stopTimer()
        hotkeyCenter.unregister()
        cancelHotkeyCapture()

        Task { @MainActor in
            defer { stopInFlight = false }
            do {
                let url = try await recorder.stop()
                self.lastSavedURL = url
                // Recording finished: clear the on-screen region furniture.
                self.overlays?.dismiss()
                self.overlays = nil
                self.setMode(.saved(url))
            } catch {
                // Keep the region armed so the user can retry.
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

    // MARK: - Stop hotkey configuration

    @objc private func hotkeyButtonClicked() {
        capturingHotkey ? cancelHotkeyCapture() : beginHotkeyCapture()
    }

    private func beginHotkeyCapture() {
        capturingHotkey = true
        hotkeyButton.title = "Press keys…"
        captureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Wait for a real key; bare modifier presses don't count.
            if Self.isModifierKeyCode(event.keyCode) { return nil }

            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let carbonMods = HotkeyCenter.carbonFlags(from: mods)
            guard HotkeyCenter.isValidStopHotkey(keyCode: UInt32(event.keyCode),
                                                 carbonModifiers: carbonMods) else {
                return nil   // invalid combo — keep listening
            }
            self.setStopHotkey(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
            self.endHotkeyCapture()
            return nil
        }
    }

    private func endHotkeyCapture() {
        if let monitor = captureMonitor {
            NSEvent.removeMonitor(monitor)
            captureMonitor = nil
        }
        capturingHotkey = false
        updateHotkeyButtonTitle()
    }

    func cancelHotkeyCapture() {
        guard capturingHotkey else { return }
        endHotkeyCapture()
    }

    private func setStopHotkey(keyCode: UInt32, modifiers: UInt32) {
        stopHotkeyCode = keyCode
        stopHotkeyModifiers = modifiers
        UserDefaults.standard.set(Int(keyCode), forKey: DefaultsKeys.keyCode)
        UserDefaults.standard.set(Int(modifiers), forKey: DefaultsKeys.modifiers)
        if isRecording {
            // Apply the new hotkey to the active recording.
            hotkeyCenter.register(keyCode: keyCode, carbonModifiers: modifiers)
        }
    }

    private func loadHotkey() {
        let defaults = UserDefaults.standard
        if let code = defaults.object(forKey: DefaultsKeys.keyCode) as? Int,
           let mods = defaults.object(forKey: DefaultsKeys.modifiers) as? Int,
           code > 0, code <= 127,
           HotkeyCenter.isValidStopHotkey(keyCode: UInt32(code), carbonModifiers: UInt32(mods)) {
            stopHotkeyCode = UInt32(code)
            stopHotkeyModifiers = UInt32(mods)
        }
    }

    private func updateHotkeyButtonTitle() {
        hotkeyButton.title = HotkeyCenter.displayName(keyCode: stopHotkeyCode,
                                                      carbonModifiers: stopHotkeyModifiers)
    }

    private static func isModifierKeyCode(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    // MARK: - Self tests (development)

    /// Prints test output and mirrors it to $MAC_SCREEN_REC_TEST_LOG when set,
    /// so tests launched via `open` can report without a console.
    private static let testLogHandle: FileHandle? = {
        guard let path = ProcessInfo.processInfo.environment["MAC_SCREEN_REC_TEST_LOG"] else { return nil }
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func testLog(_ line: String) {
        print(line)
        if let handle = testLogHandle {
            handle.write((line + "\n").data(using: .utf8)!)
        }
    }

    /// The currently selected region, for tests/diagnostics.
    func regionForTesting() -> RegionSelection? {
        if case let .armed(sel) = mode { return sel }
        if case let .recording(sel, _) = mode { return sel }
        return nil
    }

    func stateForTesting() -> String {
        switch mode {
        case .idle: return "idle"
        case .selecting: return "selecting"
        case .armed: return "armed"
        case .recording: return "recording"
        case .saved(let url): return "saved:\(url.lastPathComponent)"
        }
    }

    /// Headless end-to-end test: records a fixed 480×360 region of the main
    /// display for 6 seconds with system audio and prints the file path.
    /// Run with: MacScreenRec --selftest
    func runSelfTest() {
        Task { @MainActor in
            Self.testLog("SELFTEST: waiting for Screen Recording permission…")
            let granted = await ScreenRecorder.requestPermission(timeout: 90)
            guard granted else {
                Self.testLog("SELFTEST: DENIED — grant Screen Recording permission and retry")
                exit(1)
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    Self.testLog("SELFTEST: main display not found")
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
                Self.testLog("SELFTEST: recording 6 s…")
                try await Task.sleep(nanoseconds: 6_000_000_000)
                let url = try await recorder.stop()
                Self.testLog("SELFTEST-DONE \(url.path)")
                exit(0)
            } catch {
                Self.testLog("SELFTEST-ERROR \(error.localizedDescription)")
                exit(1)
            }
        }
    }

    /// UI test: exercises the real region-selection flow (overlay, drag,
    /// dismissal, coordinate conversion), then records through the actual
    /// GUI start path and stops via the hotkey trigger. Run with:
    /// MacScreenRec --uitest-select
    func runSelectUITest() {
        showMainWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { exit(1) }
            self.selectRegionAction()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                guard let self, let screen = NSScreen.main else {
                    Self.testLog("UITEST: no main screen")
                    exit(1)
                }
                Self.testLog("UITEST: main=\(screen.frame) selecting=\(RegionSelector.isSelecting) overlayFrames=\(RegionSelector.debugOverlayFrames)")
                guard RegionSelector.simulateSelection(
                    from: CGPoint(x: 120, y: 140),
                    to: CGPoint(x: 600, y: 500),
                    screen: screen) else {
                    Self.testLog("UITEST: selection overlay was not available")
                    exit(1)
                }
                guard RegionSelector.isSelecting == false else {
                    Self.testLog("UITEST: overlay did not dismiss after mouseUp")
                    exit(1)
                }
                guard let sel = self.regionForTesting() else {
                    Self.testLog("UITEST: no region selected after drag")
                    exit(1)
                }
                // A drag from (120,140) to (600,500) in the display's top-left
                // space must produce exactly that rect in ScreenCaptureKit's
                // top-left sourceRect space.
                guard abs(sel.rect.minX - 120) < 0.01,
                      abs(sel.rect.minY - 140) < 0.01,
                      abs(sel.rect.width - 480) < 0.01,
                      abs(sel.rect.height - 360) < 0.01 else {
                    Self.testLog("UITEST: region mismatch — got \(sel.rect), expected (120, 140, 480, 360)")
                    exit(1)
                }
                Self.testLog("UITEST: selection OK — region=\(sel.rect)")

                // Wait for Screen Recording permission (a system prompt may
                // appear — grant it for this app), then record for real.
                Task { @MainActor in
                    Self.testLog("UITEST: waiting for Screen Recording permission — if it stalls, toggle Mac Screen Recorder OFF then ON in System Settings > Privacy & Security > Screen and System Audio Recording")
                    let wait = Double(ProcessInfo.processInfo.environment["MAC_SCREEN_REC_PERM_TIMEOUT"] ?? "") ?? 150
                    guard await ScreenRecorder.requestPermission(timeout: wait) else {
                        Self.testLog("UITEST: permission denied")
                        exit(1)
                    }
                    self.toggleRecordingAction()   // real GUI path (registers hotkey)

                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                        guard let self else { exit(1) }
                        guard self.isRecording else {
                            Self.testLog("UITEST: recording did not start — state=\(self.stateForTesting())")
                            exit(1)
                        }
                        Self.testLog("UITEST: recording active, stop hotkey registered=\(self.hotkeyCenter.isRegistered)")

                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                            guard let self else { exit(1) }
                            // Simulate the stop hotkey firing.
                            self.hotkeyCenter.onTrigger?()

                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                                guard let self else { exit(1) }
                                let state = self.stateForTesting()
                                Self.testLog("UITEST: state after hotkey stop = \(state)")
                                guard state.hasPrefix("saved:") else {
                                    Self.testLog("UITEST: hotkey did not stop the recording")
                                    exit(1)
                                }
                                guard self.overlays == nil else {
                                    Self.testLog("UITEST: region overlays were not dismissed after stop")
                                    exit(1)
                                }
                                Self.testLog("UITEST-DONE")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
    }

    private static func parseRegionSpec(_ s: String) -> CGRect? {
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
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
            recordButton.title = "Record"
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
        case .saved(let url):
            regionLabel.stringValue = "No region selected"
            recordButton.isEnabled = false
            recordButton.title = "Record"
            savedRow.isHidden = false
            statusLabel.stringValue = "Saved \(url.lastPathComponent)"
            statusLabel.toolTip = url.path
        }
    }

    // MARK: - Errors

    /// Presents alerts as a sheet on the main window instead of running a
    /// modal session — a modal alert blocks app termination, which breaks the
    /// "quit and reopen" flow macOS uses after permission changes.
    private func presentAlert(_ alert: NSAlert) {
        if let w = window, w.isVisible {
            alert.beginSheetModal(for: w, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func recordingEndedUnexpectedly(_ message: String) {
        guard isRecording else { return }
        let alert = NSAlert()
        alert.messageText = "Recording ended unexpectedly"
        alert.informativeText = "\(message)\n\nThe portion captured so far was saved to your Movies folder."
        stopRecording()   // finalizes whatever was captured
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.presentAlert(alert)
        }
    }

    private func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentError(_ error: Error) {
        Self.testLog("APPERROR: \(error.localizedDescription)")
        if let recError = error as? ScreenRecorder.RecorderError,
           case .permissionRequired = recError {
            let alert = NSAlert()
            alert.messageText = "Screen Recording permission required"
            alert.informativeText = """
                “Mac Screen Recorder” needs Screen & System Audio Recording access
                to record video and sound.

                Open System Settings → Privacy & Security → Screen & System Audio
                Recording and enable Mac Screen Recorder.

                If it already appears enabled, switch it off and back on — macOS
                needs the toggle refreshed after each app update (the app is
                unsigned, so each new version counts as a new app). Then click
                Record again.
                """
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "OK")
            if let w = window, w.isVisible {
                alert.beginSheetModal(for: w) { [weak self] response in
                    if response == .alertFirstButtonReturn { self?.openScreenRecordingSettings() }
                }
            } else {
                if alert.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Recording failed"
        alert.informativeText = error.localizedDescription
        presentAlert(alert)
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        let px = max(2, Int(value.rounded()))
        return px - px % 2
    }
}
