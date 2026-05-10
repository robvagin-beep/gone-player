import AppKit

final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()

    private let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 300
        return c
    }()

    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("GONE/artwork")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {
        DispatchQueue.global(qos: .background).async { [weak self] in self?.prune() }
    }

    func image(for id: UUID) -> NSImage? {
        let key = id.uuidString as NSString
        if let img = cache.object(forKey: key) { return img }
        let url = dir.appendingPathComponent(id.uuidString + ".jpg")
        guard let data = try? Data(contentsOf: url), let img = NSImage(data: data) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    func store(_ native: NSImage, for id: UUID) {
        let key = id.uuidString as NSString
        cache.setObject(native, forKey: key)
        let url = dir.appendingPathComponent(id.uuidString + ".jpg")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.writeToDisk(native, to: url)
        }
    }

    private func writeToDisk(_ image: NSImage, to url: URL) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return }
        let scale = min(1.0, min(256.0 / Double(w), 256.0 / Double(h)))
        let tw = max(1, Int((Double(w) * scale).rounded()))
        let th = max(1, Int((Double(h) * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: tw, height: th,
                                  bitsPerComponent: 8, bytesPerRow: tw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let thumb = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: thumb)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
        try? jpg.write(to: url, options: .atomic)
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in files {
            guard let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  date < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
