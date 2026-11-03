import Foundation
import AVFoundation
import TeleCore

/// Cuts a MOV/MP4 into parts with AVAssetReader and AVAssetWriter without re-encoding: the compressed frames are copied as they are,
/// and each part starts on a keyframe, so every part plays by itself. A new part starts at the first video keyframe after the
/// current one reached its share of the size. Only video and audio tracks are kept.
final class AVVideoSplitter: VideoSplitter {
    func split(source: String, maxPartBytes: Int64, outDir: String, onProgress: @escaping (Int64, Int64) -> Void) async -> SplitResult {
        let url = URL(fileURLWithPath: source)
        let total = ((try? FileManager.default.attributesOfItem(atPath: source)[.size]) as? NSNumber)?.int64Value ?? 0
        let parts = SplitPlan.partsNeeded(total, maxPart: maxPartBytes)
        if parts < 2 { return .parts([source]) }
        if parts > SplitPlan.maxParts { return .failed("it would need more than \(SplitPlan.maxParts) parts") }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let free = (try? URL(fileURLWithPath: outDir).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        if free < total + 200_000_000 { return .failed("not enough free space on the phone to cut it") }
        let target = SplitPlan.targetPartBytes(total, parts: parts, maxPart: maxPartBytes)
        let fileType: AVFileType = ["mp4", "m4v"].contains(url.pathExtension.lowercased()) ? .mp4 : .mov

        let asset = AVURLAsset(url: url)
        guard let vTrack = try? await asset.loadTracks(withMediaType: .video).first else { return .failed("it has no video track") }
        let aTrack = try? await asset.loadTracks(withMediaType: .audio).first
        guard let reader = try? AVAssetReader(asset: asset) else { return .failed("it could not be opened") }
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil); vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        var aOut: AVAssetReaderTrackOutput?
        if let a = aTrack { let o = AVAssetReaderTrackOutput(track: a, outputSettings: nil); o.alwaysCopiesSampleData = false; reader.add(o); aOut = o }
        let vFormat = (try? await vTrack.load(.formatDescriptions))?.first
        let aFormat = aTrack == nil ? nil : (try? await aTrack!.load(.formatDescriptions))?.first
        let transform = (try? await vTrack.load(.preferredTransform)) ?? .identity
        guard reader.startReading() else { return .failed("it could not be read") }

        var made: [String] = []
        var writer: AVAssetWriter?, vIn: AVAssetWriterInput?, aIn: AVAssetWriterInput?
        var partBytes: Int64 = 0, read: Int64 = 0

        func closePart() async {
            guard let w = writer else { return }
            vIn?.markAsFinished(); aIn?.markAsFinished()
            await w.finishWriting()
            writer = nil
        }
        func openPart(at time: CMTime) -> Bool {
            let path = outDir + "/part\(made.count + 1).\(fileType == .mp4 ? "mp4" : "mov")"
            try? FileManager.default.removeItem(atPath: path)
            guard let w = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: fileType) else { return false }
            let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
            vi.expectsMediaDataInRealTime = false; vi.transform = transform
            guard w.canAdd(vi) else { return false }
            w.add(vi); vIn = vi
            if aOut != nil {
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: aFormat)
                ai.expectsMediaDataInRealTime = false
                if w.canAdd(ai) { w.add(ai); aIn = ai }
            }
            guard w.startWriting() else { return false }
            w.startSession(atSourceTime: time)
            writer = w; made.append(path); partBytes = 0
            return true
        }
        func isKeyframe(_ s: CMSampleBuffer) -> Bool {
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(s, createIfNecessary: false) as? [[CFString: Any]], let a = atts.first else { return true }
            return (a[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        }
        func dts(_ s: CMSampleBuffer) -> Double {
            let d = CMSampleBufferGetDecodeTimeStamp(s); return CMTimeGetSeconds(d.isValid ? d : CMSampleBufferGetPresentationTimeStamp(s))
        }

        var nextV = vOut.copyNextSampleBuffer(), nextA = aOut?.copyNextSampleBuffer()
        while nextV != nil || nextA != nil {
            if Task.isCancelled { reader.cancelReading(); await closePart(); return .failed("cancelled") }
            // interleave audio and video by time
            let takeVideo: Bool
            if let v = nextV, let a = nextA { takeVideo = dts(v) <= dts(a) } else { takeVideo = nextV != nil }
            let sample = takeVideo ? nextV! : nextA!
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if takeVideo && isKeyframe(sample) && (writer == nil || (partBytes >= target && made.count < parts)) {
                await closePart()
                if !openPart(at: pts) { reader.cancelReading(); return .failed("a part could not be written") }
            }
            if writer == nil { // audio before the first video keyframe: start the first part at the first sample's time
                if !openPart(at: pts) { reader.cancelReading(); return .failed("a part could not be written") }
            }
            let input = takeVideo ? vIn : aIn
            if let input = input {
                while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 2_000_000) }
                if !input.append(sample) { reader.cancelReading(); await closePart(); return .failed(writer?.error?.localizedDescription ?? "a part could not be written") }
            }
            let n = Int64(CMSampleBufferGetTotalSampleSize(sample)); partBytes += n; read += n
            onProgress(min(read, total), total)
            if takeVideo { nextV = vOut.copyNextSampleBuffer() } else { nextA = aOut?.copyNextSampleBuffer() }
        }
        await closePart()
        if reader.status == .failed { return .failed(reader.error?.localizedDescription ?? "it could not be read") }
        for p in made {
            let size = ((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? 0
            if size == 0 || size > 2_000_000_000 { return .failed("a part came out too big for Telegram") }
        }
        return made.count < 2 ? .failed("it could not be cut into parts") : .parts(made)
    }
}
