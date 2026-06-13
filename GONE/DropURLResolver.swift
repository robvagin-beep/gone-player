import Foundation
import UniformTypeIdentifiers

// Robust file-URL resolution for drag-and-drop.
//
// Why this exists: dropping a SINGLE audio file used to fail intermittently while
// 2–4 files worked. When `.onDrop(of:)` lists a content type (UTType.audio),
// SwiftUI may match a lone audio file's provider on the audio UTI, and asking that
// provider for "public.file-url" via loadItem can come back nil. `loadObject(ofClass:
// URL.self)` uses the provider's URL bridging and resolves the file URL whenever one
// is present — single or multiple. The loadItem chain stays as a fallback.
extension NSItemProvider {
    /// Resolve a file URL from this provider, preferring the URL-bridging path.
    /// `completion` is always called exactly once (with nil when nothing resolves).
    func resolveFileURL(_ completion: @escaping (URL?) -> Void) {
        if ProcessInfo.processInfo.environment["GONE_DEBUG_DROP"] != nil {
            NSLog("[GONE drop] provider types=%@ canLoadURL=%d",
                  registeredTypeIdentifiers.description, canLoadObject(ofClass: URL.self) ? 1 : 0)
        }
        let report: (URL?) -> Void = { url in
            if ProcessInfo.processInfo.environment["GONE_DEBUG_DROP"] != nil {
                NSLog("[GONE drop] resolved=%@", url?.path ?? "nil")
            }
            completion(url)
        }
        if canLoadObject(ofClass: URL.self) {
            _ = loadObject(ofClass: URL.self) { url, _ in
                if let url { report(url); return }
                self.resolveViaItem(report)
            }
        } else {
            resolveViaItem(report)
        }
    }

    private func resolveViaItem(_ completion: @escaping (URL?) -> Void) {
        loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var resolved: URL?
            if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                resolved = url
            } else if let nsURL = item as? NSURL {
                resolved = nsURL as URL
            } else if let str = item as? String {
                resolved = URL(string: str)
            }
            completion(resolved)
        }
    }
}
