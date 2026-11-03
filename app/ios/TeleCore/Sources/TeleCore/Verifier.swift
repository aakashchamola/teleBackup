import Foundation

public enum ReplyCheck: Equatable { case ok, mismatch(String) }

/// Checks Telegram's reply to a send against what we sent (docs/TELEGRAM.md "Reply checks").
public enum Verifier {
    public static let photoMinLongSide = 1280

    public static func checkReply(_ job: SendJob, _ sent: SentMessage) -> ReplyCheck {
        if sent.chatId != job.chatId { return .mismatch("wrong group") }
        if sent.threadId != job.threadId { return .mismatch("wrong topic") }
        if sent.messageId <= 0 { return .mismatch("no message id") }
        switch job.sendAs {
        case .document:
            return sent.size == job.sizeBytes ? .ok : .mismatch("size \(sent.size.map(String.init) ?? "none") instead of \(job.sizeBytes)")
        case .video: return checkVideo(job, sent)
        case .photo: return checkPhoto(job, sent)
        }
    }

    static func checkVideo(_ job: SendJob, _ sent: SentMessage) -> ReplyCheck {
        if let want = job.durationMs, let got = sent.durationMs, abs(want - got) > 1000 { return .mismatch("duration differs") }
        if let w = job.width, let h = job.height, let sw = sent.width, let sh = sent.height {
            if !((sw == w && sh == h) || (sw == h && sh == w)) { return .mismatch("video size differs") }
        }
        guard let size = sent.size, size > 0 else { return .mismatch("no size reported") }
        return .ok
    }

    static func checkPhoto(_ job: SendJob, _ sent: SentMessage) -> ReplyCheck {
        guard let gw = sent.width, let gh = sent.height, gw > 0, gh > 0 else { return .mismatch("no photo size reported") }
        if let w = job.width, let h = job.height, w > 0, h > 0 {
            let want = Double(w) / Double(h), got = Double(gw) / Double(gh), swapped = Double(h) / Double(w)
            let close = abs(got - want) / want <= 0.01 || abs(got - swapped) / swapped <= 0.01
            if !close { return .mismatch("photo shape differs") }
            if max(gw, gh) < min(max(w, h), photoMinLongSide) { return .mismatch("photo too small") }
        }
        return .ok
    }
}
