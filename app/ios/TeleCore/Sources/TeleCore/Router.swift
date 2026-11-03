import Foundation

public enum RouteDecision: Equatable {
    case go(Route, SendAs, note: String? = nil, parts: Int = 1)
    case skip(String)
}

public struct RouterLimits {
    public var botMaxBytes: Int64 = 52_428_800
    public var botPhotoMaxBytes: Int64 = 10_485_760
    public var accountMaxBytes: Int64 = 2_000_000_000
    public init() {}
}

/// Picks the Telegram route and the send form for one file (docs/TELEGRAM.md section 1).
public enum Router {
    static let oddPhotoTypes: Set<String> = ["heic", "heif", "dng", "gif", "webp"]

    public static func decide(sizeBytes: Int64, kind: FileKind, uploadAs: UploadAs, displayName: String,
                              width: Int?, height: Int?, limits: RouterLimits = RouterLimits()) -> RouteDecision {
        if sizeBytes >= limits.accountMaxBytes {
            // a video over 2 GB is cut into parts at keyframes and sent together; anything else that big cannot go
            let parts = SplitPlan.partsNeeded(sizeBytes)
            if kind == .video && SplitPlan.canSplit(displayName) && parts <= SplitPlan.maxParts {
                return .go(.account, uploadAs == .original ? .document : .video, note: "cut into \(parts) parts", parts: parts)
            }
            return .skip("Too big for Telegram (over 2 GB)")
        }
        let route: Route = sizeBytes < limits.botMaxBytes ? .bot : .account
        if uploadAs == .original { return .go(route, .document) }
        switch kind {
        case .video: return .go(route, .video)
        case .photo:
            let ext = (displayName as NSString).pathExtension.lowercased()
            if oddPhotoTypes.contains(ext) { return .go(route, .document, note: "odd photo type") }
            if sizeBytes > limits.botPhotoMaxBytes { return .go(route, .document, note: "too big for a photo") }
            if !photoShapeOk(width, height) { return .go(route, .document, note: "photo shape not allowed") }
            return .go(route, .photo)
        }
    }

    static func photoShapeOk(_ w: Int?, _ h: Int?) -> Bool {
        guard let w = w, let h = h, w > 0, h > 0 else { return true }
        if w + h > 10_000 { return false }
        return Double(max(w, h)) / Double(min(w, h)) <= 20.0
    }
}
