import Foundation

/// Telegram takes 2 GB a file. Parts stay well under it, and a video is cut only when it does not fit in one.
public enum SplitPlan {
    public static let partMaxBytes: Int64 = 1_900_000_000
    /// An album holds 10 items, so a video that would need more than 10 parts is left alone.
    public static let maxParts = 10
    static let splittable: Set<String> = ["mp4", "m4v", "mov", "3gp"]

    public static func canSplit(_ displayName: String) -> Bool { splittable.contains((displayName as NSString).pathExtension.lowercased()) }
    public static func partsNeeded(_ sizeBytes: Int64, maxPart: Int64 = partMaxBytes) -> Int { Swift.max(1, Int((sizeBytes + maxPart - 1) / maxPart)) }
    /// A part ends at the first keyframe after it reaches this size, so all parts come out about equal.
    public static func targetPartBytes(_ sizeBytes: Int64, parts: Int, maxPart: Int64 = partMaxBytes) -> Int64 {
        Swift.max(1, Swift.min(sizeBytes / Int64(Swift.max(parts, 1)), maxPart - Swift.min(30_000_000, maxPart / 10)))
    }
    public static func partName(_ displayName: String, index: Int, parts: Int) -> String {
        let ns = displayName as NSString
        let ext = ns.pathExtension.isEmpty ? "mp4" : ns.pathExtension
        return "\(ns.deletingPathExtension) (part \(index + 1) of \(parts)).\(ext)"
    }
}

public enum SplitResult: Equatable { case parts([String]), failed(String) }

/// Cuts a video into parts at keyframes, without re-encoding, so nothing is lost in quality.
public protocol VideoSplitter {
    /// Writes the parts into `outDir` and returns their paths in order. `onProgress` gets bytes read so far and the total.
    func split(source: String, maxPartBytes: Int64, outDir: String, onProgress: @escaping (Int64, Int64) -> Void) async -> SplitResult
}

/// Telegram answers an album as one: every file went, or none did. `messages` are in the order the jobs were given.
public enum AlbumResult: Equatable {
    case sent([SentMessage])
    case failed(TgError)
    case unsupported
}
