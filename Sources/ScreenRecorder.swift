import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOKit.pwr_mgt
import ScreenCaptureKit

/// The region of a display to record: a display-local rect in points with a
/// top-left origin (ScreenCaptureKit's `sourceRect` space), plus the output
/// pixel dimensions for the recorded video.
struct RegionSpec {
    let displayID: CGDirectDisplayID
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

/// ScreenCaptureKit-based recorder: captures a region of one display together
/// with system audio (loopback) and writes an H.264/AAC MP4 with AVAssetWriter.
///
/// ScreenCaptureKit only delivers a video frame when on-screen content
/// changes, so a pacing engine re-appends the most recent frame on a
/// host-clock-anchored cadence (30 fps while content is changing, throttled
/// while idle) to keep the video track complete and smooth.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    enum RecorderError: LocalizedError {
        case permissionRequired
        case captureUnavailable(String)
        case displayNotFound
        case notRecording
        case nothingCaptured
        case writerFailed(String)

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Screen Recording permission is required to capture video and system audio."
            case .captureUnavailable(let why):
                return "Screen capture could not be started: \(why)"
            case .displayNotFound:
                return "The display containing the selected region is no longer available."
            case .notRecording:
                return "No recording is in progress."
            case .nothingCaptured:
                return "Nothing was captured — the recording was empty."
            case .writerFailed(let why):
                return "Failed to write the movie file: \(why)"
            }
        }
    }

    /// Fired when the capture stream stops unexpectedly (e.g. display removed).
    var onStreamError: ((String) -> Void)?

    private enum State { case idle, recording, stopping }
    private var state: State = .idle
    private let lock = NSLock()

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var fileURL: URL?

    private let videoQueue = DispatchQueue(label: "com.robtandy.mac-screen-rec.video")
    private let audioQueue = DispatchQueue(label: "com.robtandy.mac-screen-rec.audio")
    private let pacingQueue = DispatchQueue(label: "com.robtandy.mac-screen-rec.pacing")

    // Session/timing state. Shared fields are guarded by `lock`; queue-owned
    // fields are only touched from their own queue.
    private var sessionStarted = false
    private var sessionStartPTS: CMTime?

    // Pacing engine (pacingQueue only).
    private var isPacing = false
    private var latestFrame: CVPixelBuffer?
    private var hasNewContent = false
    private var ticksSinceContent = 0
    private var lastAppendedVideoPTS = CMTime.invalid

    // Audio timing (audioQueue only).
    private var audioConfigured = false
    private var audioTrusted = true
    private var audioSyntheticAnchor = CMTime.invalid
    private var audioSyntheticSamples: Int64 = 0
    private var audioRate: Double = 48_000
    private var lastAudioEnd = CMTime.invalid

    private var powerAssertion: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)

    private static let activeFrameInterval: TimeInterval = 1.0 / 30.0
    private static let idleFrameInterval: TimeInterval = 0.2
    private static let idleThresholdTicks = 45   // ~1.5 s without changes

    /// Runs `body` while holding `lock`. Never hold the lock across an await.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Permission

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts once and then waits up to `timeout` seconds for the user to
    /// grant Screen Recording permission. Returns true once granted.
    static func requestPermission(timeout: TimeInterval) async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if CGPreflightScreenCaptureAccess() { return true }
        }
        return CGPreflightScreenCaptureAccess()
    }

    // MARK: - Start / stop

    /// Starts capturing. Throws `RecorderError.permissionRequired` (after
    /// triggering the system prompt) if Screen Recording access is missing.
    func start(region: RegionSpec, includeSystemAudio: Bool, showsCursor: Bool = true) async throws {
        let canStart = withLock { () -> Bool in
            guard state == .idle else { return false }
            state = .recording
            resetTimingStateLocked()
            return true
        }
        guard canStart else { return }

        do {
            try await beginCapture(region: region, includeSystemAudio: includeSystemAudio, showsCursor: showsCursor)
        } catch {
            await cleanupAfterFailure()
            throw error
        }
    }

    private func resetTimingStateLocked() {
        sessionStarted = false
        sessionStartPTS = nil
        audioConfigured = false
        audioTrusted = true
        audioSyntheticAnchor = .invalid
        audioSyntheticSamples = 0
        audioRate = 48_000
        lastAudioEnd = .invalid
        isPacing = false
        latestFrame = nil
        hasNewContent = false
        ticksSinceContent = 0
        lastAppendedVideoPTS = .invalid
    }

    private func beginCapture(region: RegionSpec, includeSystemAudio: Bool, showsCursor: Bool) async throws {
        // Screen Recording permission covers both video and system audio.
        guard Self.hasPermission() else {
            CGRequestScreenCaptureAccess()   // triggers the system prompt
            throw RecorderError.permissionRequired
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw RecorderError.permissionRequired
        }

        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }

        // Exclude our own windows (region frame, control bar, main window) so
        // the app's on-screen furniture never appears in the recording.
        let pid = getpid()
        let ownApp = content.applications.first(where: { $0.processID == pid })
            ?? content.applications.first(where: { $0.bundleIdentifier == Bundle.main.bundleIdentifier })
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApp.map { [$0] } ?? [],
            exceptingWindows: [])

        // Stream configuration: crop the display to the region, 30 fps.
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = region.sourceRect
        cfg.width = region.pixelWidth
        cfg.height = region.pixelHeight
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        cfg.showsCursor = showsCursor
        cfg.pixelFormat = OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        if includeSystemAudio {
            cfg.capturesAudio = true
            cfg.sampleRate = 48_000
            cfg.channelCount = 2
        }

        // Output file + writer.
        let url = Self.nextFileURL()
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let pixels = Double(region.pixelWidth * region.pixelHeight)
        let bitrate = min(40_000_000, max(2_000_000, Int(pixels * 30.0 * 0.10)))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: region.pixelWidth,
            AVVideoHeightKey: region.pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoMaxKeyFrameIntervalKey: 90,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vi.expectsMediaDataInRealTime = true
        guard w.canAdd(vi) else { throw RecorderError.writerFailed("video input was rejected") }
        w.add(vi)

        let pixelAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: OSType(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferWidthKey as String: region.pixelWidth,
            kCVPixelBufferHeightKey as String: region.pixelHeight,
        ]
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: pixelAttributes)

        var ai: AVAssetWriterInput?
        if includeSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 160_000,
            ]
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) {
                w.add(a)
                ai = a
            }
        }
        guard w.startWriting() else {
            throw RecorderError.writerFailed(w.error?.localizedDescription ?? "could not create output file")
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        withLock {
            fileURL = url
            writer = w
            videoInput = vi
            audioInput = ai
            adaptor = ad
            stream = s
        }

        do {
            try await s.startCapture()
        } catch {
            throw RecorderError.captureUnavailable(error.localizedDescription)
        }

        withLock {
            powerAssertion = Self.acquirePowerAssertion()
        }
    }

    /// Stops the capture, finalizes the MP4 and returns its file URL.
    func stop() async throws -> URL {
        let wasRecording = withLock { () -> Bool in
            guard state == .recording else { return false }
            state = .stopping
            return true
        }
        guard wasRecording else { throw RecorderError.notRecording }

        if let s = stream { try? await s.stopCapture() }
        // Stop the pacing engine and let in-flight sample callbacks drain.
        stopPacing()
        videoQueue.sync { }
        audioQueue.sync { }

        let prepared = withLock { () -> (writer: AVAssetWriter, url: URL, started: Bool)? in
            guard let w = writer, let url = fileURL else { return nil }
            let started = sessionStarted
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            stream = nil
            Self.releasePowerAssertion(powerAssertion)
            powerAssertion = IOPMAssertionID(kIOPMNullAssertionID)
            return (w, url, started)
        }
        guard let p = prepared else {
            withLock { state = .idle }
            throw RecorderError.notRecording
        }

        if !p.started {
            p.writer.cancelWriting()
            try? FileManager.default.removeItem(at: p.url)
            withLock { state = .idle }
            throw RecorderError.nothingCaptured
        }

        await p.writer.finishWriting()
        withLock { state = .idle }

        if p.writer.status == .completed {
            return p.url
        }
        try? FileManager.default.removeItem(at: p.url)
        throw RecorderError.writerFailed(p.writer.error?.localizedDescription ?? "unknown writer error")
    }

    private func cleanupAfterFailure() async {
        stopPacing()
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        if let w = writer, w.status == .writing { w.cancelWriting() }
        writer = nil
        videoInput = nil
        audioInput = nil
        adaptor = nil
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        fileURL = nil
        Self.releasePowerAssertion(powerAssertion)
        powerAssertion = IOPMAssertionID(kIOPMNullAssertionID)
        withLock { state = .idle }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock()
        let active = state == .recording
        lock.unlock()
        guard active else { return }

        switch type {
        case .screen: adoptVideo(sampleBuffer)
        case .audio: appendAudio(sampleBuffer)
        default: break   // e.g. .microphone (not captured)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onStreamError?(error.localizedDescription)
        }
    }

    // MARK: - Video pacing engine

    /// ScreenCaptureKit only produces frames when content changes, so adopt
    /// every new frame into `latestFrame` (on pacingQueue) and let the pacing
    /// loop emit a continuous timeline.
    private func adoptVideo(_ sb: CMSampleBuffer) {
        guard let w = writer, w.status == .writing else { return }
        // Gate on the frame status attachment when the system provides it
        // (macOS 13–15). macOS 26+ delivers buffers without it; those are
        // accepted as long as they carry a pixel buffer.
        if let status = frameStatus(of: sb), status != .complete { return }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }

        pacingQueue.async { [weak self] in
            guard let self else { return }
            if self.latestFrame == nil {
                self.isPacing = true
                self.schedulePacingTick(after: ScreenRecorder.activeFrameInterval)
            }
            self.latestFrame = pb
            self.hasNewContent = true
        }
    }

    private func schedulePacingTick(after delay: TimeInterval) {
        pacingQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isPacing else { return }
            let next = self.pacingTick()
            self.schedulePacingTick(after: next)
        }
    }

    /// Appends the newest frame (or a duplicate of the last one) at the current
    /// host time. Returns the delay until the next tick.
    private func pacingTick() -> TimeInterval {
        defer {
            if hasNewContent {
                ticksSinceContent = 0
                hasNewContent = false
            } else {
                ticksSinceContent += 1
            }
        }
        guard let w = writer, w.status == .writing,
              let vi = videoInput, vi.isReadyForMoreMediaData,
              let frame = latestFrame, let ad = adaptor else {
            return ScreenRecorder.activeFrameInterval
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if lastAppendedVideoPTS.isValid, CMTimeCompare(now, lastAppendedVideoPTS) <= 0 {
            return ScreenRecorder.activeFrameInterval
        }

        beginSessionIfNeeded(at: now)
        if let sessionStart = currentSessionStart(), CMTimeCompare(now, sessionStart) < 0 {
            return ScreenRecorder.activeFrameInterval
        }
        if ad.append(frame, withPresentationTime: now) {
            lastAppendedVideoPTS = now
        }
        return ticksSinceContent > ScreenRecorder.idleThresholdTicks
            ? ScreenRecorder.idleFrameInterval
            : ScreenRecorder.activeFrameInterval
    }

    private func stopPacing() {
        pacingQueue.async { [weak self] in self?.isPacing = false }
        pacingQueue.sync { }
    }

    // MARK: - Audio

    private func appendAudio(_ sb: CMSampleBuffer) {
        guard let w = writer, let ai = audioInput, w.status == .writing else { return }
        let numSamples = CMSampleBufferGetNumSamples(sb)
        guard numSamples > 0 else { return }

        if let fmt = sb.formatDescription,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) {
            let rate = Double(asbd.pointee.mSampleRate)
            if rate > 0 { audioRate = rate }
        }

        if !audioConfigured {
            audioConfigured = true
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            // Trust the delivered timestamps unless they look unusable (e.g.
            // zero or earlier than an already-started video session).
            var trusted = pts.isValid && pts.isNumeric && pts.value > 0
            if let sessionStart = currentSessionStart(), CMTimeCompare(pts, sessionStart) < 0 {
                trusted = false
            }
            audioTrusted = trusted
            if !trusted {
                let anchor: CMTime
                if let sessionStart = currentSessionStart() {
                    anchor = sessionStart
                } else {
                    anchor = CMClockGetTime(CMClockGetHostTimeClock())
                    beginSessionIfNeeded(at: anchor)
                }
                audioSyntheticAnchor = anchor
                audioSyntheticSamples = 0
            }
        }

        var buffer = sb
        if !audioTrusted {
            // Rebuild timestamps on a synthetic timeline.
            let rate = max(1, CMTimeScale(audioRate))
            let pts = CMTimeAdd(audioSyntheticAnchor, CMTime(value: audioSyntheticSamples, timescale: rate))
            let dur = CMTime(value: CMTimeValue(numSamples), timescale: rate)
            guard let retimed = Self.retimed(sb, pts: pts, duration: dur) else { return }
            buffer = retimed
        }

        var eff = CMSampleBufferGetPresentationTimeStamp(buffer)
        let dur = duration(of: buffer)

        // Keep the audio timeline strictly monotonic.
        if lastAudioEnd.isValid, CMTimeCompare(eff, lastAudioEnd) < 0 {
            if CMTimeCompare(CMTimeAdd(eff, dur), lastAudioEnd) <= 0 {
                audioSyntheticSamples += Int64(numSamples)
                return   // fully overlapped, drop
            }
            guard let bumped = Self.retimed(buffer, pts: lastAudioEnd, duration: dur) else { return }
            buffer = bumped
            eff = lastAudioEnd
        }

        beginSessionIfNeeded(at: eff)

        // Never append audio that predates the session start.
        if let sessionStart = currentSessionStart(), CMTimeCompare(eff, sessionStart) < 0 {
            audioSyntheticSamples += Int64(numSamples)
            return
        }

        if ai.isReadyForMoreMediaData, w.status == .writing {
            if ai.append(buffer) {
                lastAudioEnd = CMTimeAdd(eff, dur)
                audioSyntheticSamples += Int64(numSamples)
            }
        } else {
            audioSyntheticSamples += Int64(numSamples)
        }
    }

    // MARK: - Session helpers

    private func beginSessionIfNeeded(at t: CMTime) {
        guard let w = writer else { return }
        lock.lock()
        defer { lock.unlock() }
        if !sessionStarted, w.status == .writing {
            w.startSession(atSourceTime: t)
            sessionStarted = true
            sessionStartPTS = t
        }
    }

    private func currentSessionStart() -> CMTime? {
        lock.lock()
        defer { lock.unlock() }
        return sessionStartPTS
    }

    private func frameStatus(of sb: CMSampleBuffer) -> SCFrameStatus? {
        if let value = CMGetAttachment(sb, key: SCStreamFrameInfo.status.rawValue as CFString, attachmentModeOut: nil),
           let number = value as? NSNumber {
            return SCFrameStatus(rawValue: number.intValue)
        }
        return nil
    }

    private func duration(of sb: CMSampleBuffer) -> CMTime {
        let d = CMSampleBufferGetDuration(sb)
        if d.isValid, d.value > 0 { return d }
        let rate = max(1, CMTimeScale(audioRate))
        return CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sb)), timescale: rate)
    }

    private static func retimed(_ sb: CMSampleBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var timing = [CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)]
        var out: CMSampleBuffer?
        let err = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sb,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out)
        return err == noErr ? out : nil
    }

    // MARK: - File helpers

    private static func nextFileURL() -> URL {
        let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Screen Recording \(df.string(from: Date()))"
        var url = dir.appendingPathComponent("\(base).mp4")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) \(i).mp4")
            i += 1
        }
        return url
    }

    // Keep the display awake while recording.
    private static func acquirePowerAssertion() -> IOPMAssertionID {
        var id: IOPMAssertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Recording the screen" as CFString,
            &id)
        return result == kIOReturnSuccess ? id : IOPMAssertionID(kIOPMNullAssertionID)
    }

    private static func releasePowerAssertion(_ id: IOPMAssertionID) {
        if id != IOPMAssertionID(kIOPMNullAssertionID) {
            IOPMAssertionRelease(id)
        }
    }
}
