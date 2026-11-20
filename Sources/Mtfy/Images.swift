import AppKit
import SwiftUI

/// Loads attachment images and icons. Images come only from the configured servers unless the
/// user allows other hosts; a server's credentials and headers are only ever sent to that server.
@MainActor
final class ImageLoader {
    static let shared = ImageLoader()

    weak var store: Store?
    var endpoint: (@MainActor (String) async -> Endpoint?)?  // server ID → how to reach it

    private let cache = NSCache<NSURL, NSImage>()
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private var failed: [URL: Date] = [:]  // retried after a while, e.g. once back online

    func allowed(_ url: URL) -> Bool {
        guard url.host() != nil, url.user == nil, url.password == nil else { return false }
        if store?.config.server(containing: url) != nil { return true }  // http only for an http server
        return url.scheme?.lowercased() == "https" && store?.config.loadExternalImages == true
    }

    func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> NSImage? {
        if let image = cached(url) { return image }
        guard allowed(url) else { return nil }
        if let failedAt = failed[url], Date().timeIntervalSince(failedAt) < 300 { return nil }
        if let task = inflight[url] { return await task.value }

        let server = store?.config.server(containing: url)?.id
        let task = Task { () -> NSImage? in
            var endpoint: Endpoint?
            if let server { endpoint = await self.endpoint?(server) }
            do {
                let cg = try await Net.image(url: url, endpoint: endpoint)
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            } catch {
                Log.network.notice("Image from \(url.host() ?? "?", privacy: .public) failed: \(NtfyError.describe(error), privacy: .public)")
                return nil
            }
        }
        inflight[url] = task
        let image = await task.value
        inflight[url] = nil
        if let image {
            cache.setObject(image, forKey: url as NSURL)
            failed[url] = nil
        } else {
            failed[url] = Date()
        }
        return image
    }
}

struct RemoteImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var done = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if !done {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            done = false
            image = ImageLoader.shared.cached(url)
            if image == nil { image = await ImageLoader.shared.load(url) }
            done = true
        }
    }
}
