import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

/// What the user picked in the menu, turned into capture parameters.
struct CaptureOptions {
    var maxHeight: Int?        // nil = native resolution
    var fps: Int
    var bitsPerPixel: Double   // bitrate = width * height * fps * bitsPerPixel
    var captureAudio: Bool
}

enum ReplayError: LocalizedError {
    case noDisplay
    case nothingRecorded
    case writerFailed(String)
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found to record."
        case .nothingRecorded: return "Nothing has been recorded yet."
        case .writerFailed(let msg): return "Could not write video: \(msg)"
        case .exportFailed(let msg): return "Could not save clip: \(msg)"
        }
    }
}

/// One finished chunk of the replay buffer on disk. Times are host-clock times.
struct ReplaySegment {
    let url: URL
    let start: CMTime
    let end: CMTime
}

/// Records the main display (and system audio) into a rolling replay buffer.
///
/// Video is encoded in hardware into short segment files on disk, so memory use
/// stays low. System audio is kept in memory as raw sample buffers (~80 MB for
/// a few minutes) so it can be written gapless when a clip is saved.
final class ReplayEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Longest clip the user can ask for, in seconds.
    static let maxClipSeconds: Double = 180

    /// Called (on a background queue) when the stream stops unexpectedly.
    var onStop: ((Error?) -> Void)?

    private let segmentLength: Double = 10
    private let tempDir: URL

    private var stream: SCStream?

    private let videoQueue = DispatchQueue(label: "Medal4Mac.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "Medal4Mac.audio", qos: .userInteractive)

    private let exportLock = NSLock()
    private var activeExports = 0

    // Only touched on videoQueue.
    private var videoSettings: [String: Any] = [:]
    private var frameDuration = CMTime(value: 1, timescale: 60)
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var currentURL: URL?
    private var currentStart = CMTime.invalid
    private var lastVideoPTS = CMTime.invalid
    private var segments: [ReplaySegment] = []
    private let finishGroup = DispatchGroup()

    // Only touched on audioQueue.
    private var audioBuffers: [CMSampleBuffer] = []
    private var lastAudioPrune = CMTime.zero

    override init() {
        tempDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Medal4Mac/Segments", isDirectory: true)
        super.init()
    }

    // MARK: - Start / stop

    /// Starts recording. Returns a short description like "1920×1080 @ 60 fps".
    func start(options: CaptureOptions) async throws -> String {
        await stop()

        try? FileManager.default.removeItem(at: tempDir)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw ReplayError.noDisplay
        }

        // Work out the output size in pixels (Retina displays report points).
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeWidth = mode?.pixelWidth ?? display.width
        let nativeHeight = mode?.pixelHeight ?? display.height
        var width = nativeWidth
        var height = nativeHeight
        if let maxHeight = options.maxHeight, nativeHeight > maxHeight {
            height = maxHeight
            width = Int((Double(nativeWidth) * Double(maxHeight) / Double(nativeHeight)).rounded())
        }
        width &= ~1
        height &= ~1

        let fps = options.fps
        let bitrate = Int(Double(width * height * fps) * options.bitsPerPixel)
        // H.264 tops out around 4096 wide; use HEVC for bigger (e.g. 5K) displays.
        let codec: AVVideoCodecType = (width > 4096 || height > 2304) ? .hevc : .h264
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoMaxKeyFrameIntervalKey: fps,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]

        videoQueue.sync {
            self.videoSettings = settings
            self.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            self.lastVideoPTS = .invalid
        }
        audioQueue.sync {
            self.audioBuffers.removeAll()
            self.lastAudioPrune = .zero
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let excluded = content.applications.filter { $0.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        if options.captureAudio {
            config.capturesAudio = true
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.captureAudio {
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await newStream.startCapture()
        stream = newStream

        return "\(width)×\(height) @ \(fps) fps"
    }

    func stop() async {
        if let current = stream {
            stream = nil
            try? await current.stopCapture()
        }
        videoQueue.sync {
            if self.writer != nil {
                self.finishCurrentSegment(at: self.lastVideoPTS + self.frameDuration)
            }
        }
        let group = finishGroup
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            group.notify(queue: .global()) { cont.resume() }
        }
        videoQueue.sync {
            self.segments.removeAll()
            self.lastVideoPTS = .invalid
        }
        audioQueue.sync { self.audioBuffers.removeAll() }
    }

    // MARK: - SCStream callbacks

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            handleVideo(sampleBuffer)
        case .audio:
            handleAudio(sampleBuffer)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Medal4Mac: stream stopped: \(error.localizedDescription)")
        if stream === self.stream {
            self.stream = nil
            onStop?(error)
        }
    }

    // MARK: - Video (videoQueue)

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // ScreenCaptureKit also sends "idle" frames when nothing changed; skip those.
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
            let info = attachments.first,
            let rawStatus = info[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status == .complete
        else { return }

        let pts = sampleBuffer.presentationTimeStamp

        if writer != nil, (pts - currentStart).seconds >= segmentLength {
            finishCurrentSegment(at: pts)
        }
        if writer == nil {
            startSegment(at: pts)
        }
        if let input = writerInput, input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
        lastVideoPTS = pts
        pruneSegments(now: pts)
    }

    private func startSegment(at pts: CMTime) {
        let url = tempDir.appendingPathComponent("segment-\(UUID().uuidString).mov")
        do {
            let newWriter = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard newWriter.canAdd(input) else {
                NSLog("Medal4Mac: cannot add video input")
                return
            }
            newWriter.add(input)
            guard newWriter.startWriting() else {
                NSLog("Medal4Mac: startWriting failed: \(newWriter.error?.localizedDescription ?? "unknown")")
                return
            }
            newWriter.startSession(atSourceTime: pts)
            writer = newWriter
            writerInput = input
            currentURL = url
            currentStart = pts
        } catch {
            NSLog("Medal4Mac: could not create writer: \(error.localizedDescription)")
        }
    }

    /// Closes the segment being written so it can be used in a clip. Must run on videoQueue.
    private func finishCurrentSegment(at end: CMTime) {
        guard let oldWriter = writer, let input = writerInput, let url = currentURL else { return }
        writer = nil
        writerInput = nil
        currentURL = nil

        input.markAsFinished()
        oldWriter.endSession(atSourceTime: end)
        segments.append(ReplaySegment(url: url, start: currentStart, end: end))

        let group = finishGroup
        let queue = videoQueue
        group.enter()
        oldWriter.finishWriting { [weak self] in
            if oldWriter.status != .completed {
                NSLog("Medal4Mac: segment failed: \(oldWriter.error?.localizedDescription ?? "unknown")")
                // Queued before group.leave(), so it runs before any waiting export reads `segments`.
                queue.async {
                    self?.segments.removeAll { $0.url == url }
                    try? FileManager.default.removeItem(at: url)
                }
            }
            group.leave()
        }
    }

    private func pruneSegments(now: CMTime) {
        exportLock.lock()
        let busy = activeExports > 0
        exportLock.unlock()
        guard !busy else { return }

        let keepAfter = now.seconds - (Self.maxClipSeconds + segmentLength + 5)
        while let first = segments.first, first.end.seconds < keepAfter {
            segments.removeFirst()
            try? FileManager.default.removeItem(at: first.url)
        }
    }

    // MARK: - Audio (audioQueue)

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        audioBuffers.append(sampleBuffer)

        let pts = sampleBuffer.presentationTimeStamp
        if (pts - lastAudioPrune).seconds > 1 {
            lastAudioPrune = pts
            let cutoff = pts.seconds - (Self.maxClipSeconds + 15)
            if let index = audioBuffers.firstIndex(where: { $0.presentationTimeStamp.seconds >= cutoff }), index > 0 {
                audioBuffers.removeFirst(index)
            }
        }
    }

    // MARK: - Saving clips

    /// Saves the last `seconds` of the buffer. `outputURL` should end in .mp4;
    /// the completion receives the file actually written.
    func saveClip(seconds: Double, to outputURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        videoQueue.async {
            guard self.writer != nil || !self.segments.isEmpty else {
                completion(.failure(ReplayError.nothingRecorded))
                return
            }

            var end: CMTime
            if self.writer != nil {
                end = self.lastVideoPTS + self.frameDuration
                // If the screen has been static, extend the clip up to "now" so audio isn't cut off.
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let gap = (now - end).seconds
                if gap > 0 && gap < 10 {
                    end = now
                }
                self.finishCurrentSegment(at: end)
            } else {
                end = self.segments.last!.end
            }

            self.exportLock.lock()
            self.activeExports += 1
            self.exportLock.unlock()

            self.finishGroup.notify(queue: self.videoQueue) {
                let start = end - CMTime(seconds: seconds, preferredTimescale: 600)
                let clipSegments = self.segments.filter { $0.end > start && $0.start < end }
                let audio: [CMSampleBuffer] = self.audioQueue.sync {
                    self.audioBuffers.filter {
                        let t = $0.presentationTimeStamp
                        return t + $0.duration > start && t < end
                    }
                }
                let tempDir = self.tempDir

                Task {
                    do {
                        let url = try await ClipExporter.export(
                            segments: clipSegments,
                            audio: audio,
                            clipStart: start,
                            clipEnd: end,
                            outputURL: outputURL,
                            tempDir: tempDir
                        )
                        completion(.success(url))
                    } catch {
                        completion(.failure(error))
                    }
                    self.exportLock.lock()
                    self.activeExports -= 1
                    self.exportLock.unlock()
                }
            }
        }
    }
}
