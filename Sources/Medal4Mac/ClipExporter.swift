import AVFoundation
import CoreMedia
import Foundation

/// Stitches replay segments + buffered audio into one clip file.
enum ClipExporter {
    static func export(
        segments: [ReplaySegment],
        audio: [CMSampleBuffer],
        clipStart: CMTime,
        clipEnd: CMTime,
        outputURL: URL,
        tempDir: URL
    ) async throws -> URL {
        guard let base = segments.first?.start else { throw ReplayError.nothingRecorded }

        // 1. Video: put all segments back to back.
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ReplayError.exportFailed("could not create video track") }

        var cursor = CMTime.zero
        for segment in segments {
            let asset = AVURLAsset(url: segment.url)
            let duration = try await asset.load(.duration)
            guard duration > .zero,
                  let track = try await asset.loadTracks(withMediaType: .video).first
            else { continue }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: cursor)
            cursor = cursor + duration
        }
        guard cursor > .zero else { throw ReplayError.nothingRecorded }

        // Composition time 0 corresponds to host time `base`.
        var startOffset = clipStart - base
        if startOffset < .zero { startOffset = .zero }
        var duration = clipEnd - clipStart
        if startOffset + duration > cursor { duration = cursor - startOffset }
        if duration <= .zero {
            startOffset = .zero
            duration = cursor
        }

        // 2. Audio: encode the buffered system audio to AAC and line it up.
        var audioURL: URL?
        if !audio.isEmpty {
            let url = tempDir.appendingPathComponent("audio-\(UUID().uuidString).m4a")
            audioURL = url
            do {
                let audioStart = try await writeAudio(audio, to: url)
                let audioAsset = AVURLAsset(url: url)
                let audioDuration = try await audioAsset.load(.duration)
                if let sourceTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
                   let audioTrack = composition.addMutableTrack(
                       withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let offset = audioStart - base
                    var sourceStart = CMTime.zero
                    var insertAt = offset
                    if offset < .zero {
                        sourceStart = CMTime.zero - offset
                        insertAt = .zero
                    }
                    let length = audioDuration - sourceStart
                    if length > .zero {
                        try audioTrack.insertTimeRange(
                            CMTimeRange(start: sourceStart, duration: length), of: sourceTrack, at: insertAt)
                    }
                }
            } catch {
                NSLog("Medal4Mac: audio skipped: \(error.localizedDescription)")
            }
        }

        // 3. Export without re-encoding (fast). Fall back to .mov if .mp4 is refused.
        let range = CMTimeRange(start: startOffset, duration: duration)
        let result: URL
        do {
            try await runExport(composition, range: range, to: outputURL, fileType: .mp4)
            result = outputURL
        } catch {
            NSLog("Medal4Mac: mp4 export failed (\(error.localizedDescription)), trying mov")
            let movURL = outputURL.deletingPathExtension().appendingPathExtension("mov")
            try await runExport(composition, range: range, to: movURL, fileType: .mov)
            result = movURL
        }

        if let audioURL = audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        return result
    }

    private static func runExport(_ asset: AVAsset, range: CMTimeRange, to url: URL, fileType: AVFileType) async throws {
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ReplayError.exportFailed("could not create export session")
        }
        session.outputURL = url
        session.outputFileType = fileType
        session.timeRange = range
        session.shouldOptimizeForNetworkUse = true

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { cont.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw ReplayError.exportFailed(session.error?.localizedDescription ?? "unknown error")
        }
    }

    private final class AppendState {
        var index = 0
        var done = false
    }

    /// Writes raw audio sample buffers to an AAC .m4a. Returns the host time of the first sample.
    private static func writeAudio(_ buffers: [CMSampleBuffer], to url: URL) async throws -> CMTime {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw ReplayError.writerFailed("cannot add audio input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "audio writer failed")
        }

        let start = buffers[0].presentationTimeStamp
        writer.startSession(atSourceTime: start)

        let state = AppendState()
        let queue = DispatchQueue(label: "Medal4Mac.audioExport")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !state.done else { return }
                while input.isReadyForMoreMediaData {
                    if state.index >= buffers.count || writer.status != .writing {
                        state.done = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    input.append(buffers[state.index])
                    state.index += 1
                }
            }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }
        guard writer.status == .completed else {
            throw ReplayError.writerFailed(writer.error?.localizedDescription ?? "audio writer failed")
        }
        return start
    }
}
