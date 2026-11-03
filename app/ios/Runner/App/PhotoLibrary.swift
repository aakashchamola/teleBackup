import Foundation
import Photos
import CryptoKit
import UniformTypeIdentifiers
import TeleCore

/// The iPhone's photo library as a `MediaSource`. An "album" is "smart:<name>" or "album:<localIdentifier>".
final class PhotoLibrarySource: MediaSource {
    static let smart: [(id: String, label: String, subtype: PHAssetCollectionSubtype, hint: String?)] = [
        ("smart:recents", "Camera Roll", .smartAlbumUserLibrary, nil),
        ("smart:screenshots", "Screenshots", .smartAlbumScreenshots, nil),
        ("smart:videos", "Videos", .smartAlbumVideos, nil),
        ("smart:selfies", "Selfies", .smartAlbumSelfPortraits, nil),
        ("smart:panoramas", "Panoramas", .smartAlbumPanoramas, nil),
    ]

    static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized }

    func collection(_ album: String) -> PHAssetCollection? {
        if album.hasPrefix("smart:") {
            guard let s = Self.smart.first(where: { $0.id == album }) else { return nil }
            return PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: s.subtype, options: nil).firstObject
        }
        if album.hasPrefix("album:") {
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [String(album.dropFirst(6))], options: nil).firstObject
        }
        return nil
    }

    func albumExists(_ album: String) -> Bool { collection(album) != nil }

    func assets(_ album: String, _ types: TeleCore.MediaTypes) -> PHFetchResult<PHAsset>? {
        guard let c = collection(album) else { return nil }
        let o = PHFetchOptions()
        switch types {
        case .photos: o.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        case .videos: o.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.video.rawValue)
        case .both: o.predicate = NSPredicate(format: "mediaType = %d OR mediaType = %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        }
        o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(in: c, options: o)
    }

    func count(_ album: String, _ types: TeleCore.MediaTypes = .both) -> Int { assets(album, types)?.count ?? 0 }

    /// The resource we back up: the edited version if the person edited the photo, else the original.
    static func primaryResource(_ asset: PHAsset) -> PHAssetResource? {
        let rs = PHAssetResource.assetResources(for: asset)
        let want: [PHAssetResourceType] = asset.mediaType == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        for t in want { if let r = rs.first(where: { $0.type == t }) { return r } }
        return rs.first
    }

    static func size(_ r: PHAssetResource) -> Int64 { (r.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0 }
    static func ms(_ d: Date?) -> Int64 { Int64((d ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000) }

    static func item(_ a: PHAsset) -> MediaItem? {
        guard let r = primaryResource(a) else { return nil }
        let original = PHAssetResource.assetResources(for: a).first(where: { $0.type == .photo || $0.type == .video })?.originalFilename ?? r.originalFilename
        let ext = (r.originalFilename as NSString).pathExtension
        let name = ((original as NSString).deletingPathExtension as String) + (ext.isEmpty ? "" : "." + ext)
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? (a.mediaType == .video ? "video/quicktime" : "image/jpeg")
        return MediaItem(path: a.localIdentifier, displayName: name, mimeType: mime, sizeBytes: size(r),
                         modifiedAt: ms(a.modificationDate ?? a.creationDate), takenAt: a.creationDate.map { ms($0) },
                         width: a.pixelWidth, height: a.pixelHeight, durationMs: a.mediaType == .video ? Int64(a.duration * 1000) : nil,
                         kind: a.mediaType == .video ? .video : .photo)
    }

    func list(album: String, types: TeleCore.MediaTypes) -> [MediaItem] {
        guard let res = assets(album, types) else { return [] }
        var out: [MediaItem] = []; out.reserveCapacity(res.count)
        res.enumerateObjects { a, _, _ in if let i = Self.item(a) { out.append(i) } }
        return out
    }

    func exists(_ path: String) -> Bool { PHAsset.fetchAssets(withLocalIdentifiers: [path], options: nil).count > 0 }

    /// Albums made by the person (WhatsApp keeps one if it is switched on).
    func userAlbums() -> [(id: String, title: String, count: Int)] {
        var out: [(String, String, Int)] = []
        let r = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        r.enumerateObjects { c, _, _ in
            let n = PHAsset.fetchAssets(in: c, options: nil).count
            if n > 0 { out.append(("album:" + c.localIdentifier, c.localizedTitle ?? "Album", n)) }
        }
        return out
    }
}

final class PhotoExporter: AssetExporter {
    let dir: URL
    init(dir: URL) { self.dir = dir; try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

    func facts(_ assetId: String) -> DiskFacts {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject, let r = PhotoLibrarySource.primaryResource(a) else {
            return DiskFacts(exists: false, sizeBytes: 0, modifiedAt: 0)
        }
        return DiskFacts(exists: true, sizeBytes: PhotoLibrarySource.size(r), modifiedAt: PhotoLibrarySource.ms(a.modificationDate ?? a.creationDate))
    }

    func export(_ assetId: String, displayName: String) async throws -> ExportedFile {
        guard let a = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil).firstObject, let r = PhotoLibrarySource.primaryResource(a) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let out = dir.appendingPathComponent(UUID().uuidString + "-" + displayName.replacingOccurrences(of: "/", with: "_"))
        let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true   // iCloud originals are downloaded first
        try await PHAssetResourceManager.default().writeData(for: r, toFile: out, options: o)
        let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ExportedFile(path: out.path, sizeBytes: size)
    }

    func clearScratch() {
        for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] { try? FileManager.default.removeItem(at: f) }
    }
}

/// One system prompt for the whole batch. The deleted items sit in "Recently Deleted" for 30 days.
final class PhotoBatchDeleter: PhotoDeleter {
    func deleteBatch(_ assetIds: [String]) async -> Set<String> {
        let found = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        var assets: [PHAsset] = []; found.enumerateObjects { a, _, _ in assets.append(a) }
        guard !assets.isEmpty else { return [] }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
            return Set(assetIds)
        } catch { return [] }   // the person tapped "Don't Allow"
    }
}

struct Sha256Hasher: TeleCore.Hasher {
    func sha256(path: String) throws -> String {
        let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? h.close() }
        var sha = SHA256()
        while true { let d = h.readData(ofLength: 1 << 20); if d.isEmpty { break }; sha.update(data: d) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
