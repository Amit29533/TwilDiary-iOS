import Foundation
import WebKit

/// Reads the video advertised by a signed-out reel page. All browser state is ephemeral.
enum PublicReel {
    struct Lookup {
        var caption: String?
        var reading: ClipFrames.Reading?
    }

    static func shortcode(_ url: URL) -> String? {
        guard ClipLinks.isInstagramPost(url) else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        guard let marker = path.firstIndex(where: { ["reel", "reels", "p"].contains($0) }),
              marker < 2, path.first != "share", path.indices.contains(marker + 1) else { return nil }
        let code = path[marker + 1]
        return code.wholeMatch(of: #/[A-Za-z0-9_-]{1,80}/#) == nil ? nil : code
    }

    static func mediaURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              ["cdninstagram.com", "fbcdn.net", "instagram.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return url
    }

    /// Prefer metadata for this specific post over players on a scrolling page.
    static let playerScript = #"""
    return await (async () => {
      const player = document.querySelector('meta[property="og:video:secure_url"],meta[property="og:video:url"],meta[property="og:video"]');
      const urls = player ? [player.content] : [];
      const caption = document.querySelector('meta[property="og:title"]')?.content || '';
      const code = location.pathname.match(/\/(?:reel|reels|p)\/([\w-]+)/)?.[1];
      if (!code || !/^https:$/.test(location.protocol) || !/(^|\.)instagram\.com$/.test(location.hostname)) return [];
      if (code !== expectedCode) return [];
      for (const script of document.querySelectorAll('script[type="application/json"],script[type="application/ld+json"]')) {
        if (!script.textContent.includes(code) || script.textContent.length > 3000000) continue;
        try {
          const inspect = (text, depth) => JSON.parse(text, (_, item) => {
            if (depth === 0 && typeof item === 'string' && item.startsWith('{') && item.includes(code)) {
              try { inspect(item, depth + 1); } catch {}
            }
            if (item && typeof item === 'object' && (item.shortcode === code || item.code === code)) {
              urls.push(item.video_url, item.video_versions?.[0]?.url);
            }
            return item;
          });
          inspect(script.textContent, 0);
        } catch {}
      }
      const advertised = new Set(urls.filter(value => typeof value === 'string' && value.startsWith('https://')));
      const players = [...document.querySelectorAll('video')];
      const confirmed = players.find(v => [v.currentSrc, v.src, v.querySelector('source')?.src].some(src => advertised.has(src)));
      const scoped = [...document.querySelectorAll('article')].find(article => {
        const links = [...article.querySelectorAll('a[href]')].filter(a => a.closest('article') === article)
          .map(a => new URL(a.href)).filter(u => /(^|\.)instagram\.com$/.test(u.hostname))
          .map(u => u.pathname.match(/^\/(?:[\w.]+\/)?(?:reels?|p)\/([\w-]+)\/?$/)?.[1]).filter(Boolean);
        return links.includes(code) && links.every(id => id === code);
      });
      const scopedPlayers = scoped ? players.filter(v => v.closest('article') === scoped) : [];
      const video = confirmed || (scopedPlayers.length === 1 ? scopedPlayers[0] : null);
      if (video) urls.push(video.currentSrc, video.src, video.querySelector('source')?.src);
      const sources = [...new Set(urls.filter(value => typeof value === 'string' && value.startsWith('https://')))];
      const result = [caption.slice(0, 4000), ...sources];
      if (!video || video.mediaKeys || (!tryPlayer && sources.length)) return result;
      const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
      const frames = [];
      try {
        video.muted = true;
        video.playsInline = true;
        await Promise.race([video.play(), wait(800)]);
        if (video.readyState < 2 || !video.videoWidth) return result;
        video.pause();
        const canvas = document.createElement('canvas');
        const scale = Math.min(1, 768 / Math.max(video.videoWidth, video.videoHeight));
        canvas.width = Math.max(1, Math.round(scale * video.videoWidth));
        canvas.height = Math.max(1, Math.round(scale * video.videoHeight));
        const context = canvas.getContext('2d');
        const capture = () => {
          context.drawImage(video, 0, 0, canvas.width, canvas.height);
          frames.push(canvas.toDataURL('image/jpeg', 0.7));
        };
        capture();
        if (Number.isFinite(video.duration)) {
          for (const fraction of [0.35, 0.62, 0.90]) {
            video.currentTime = video.duration * fraction;
            for (let i = 0; i < 10 && (video.seeking || video.readyState < 2); i++) await wait(70);
            if (!video.seeking && video.readyState >= 2) capture();
          }
        }
      } catch {} finally { video.pause(); }
      return result.concat(frames);
    })()
    """#

    @MainActor static func read(_ shared: URL) async -> Lookup {
        var result = Lookup()
        guard ClipLinks.isInstagramPost(shared) else { return result }
        let expected = shortcode(shared)
        let sharedAlias = shared.path.hasPrefix("/share/reel/") || shared.path.hasPrefix("/share/r/")
        guard expected != nil || sharedAlias else { return result }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        defer { web.stopLoading() }
        var pages = [shared], tried = Set<URL>()
        while !pages.isEmpty && !Task.isCancelled {
            let page = pages.removeFirst()
            web.load(URLRequest(url: page, timeoutInterval: 8))
            for _ in 0..<12 {
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return result }
                guard let current = web.url, let code = shortcode(current), expected == nil || code == expected else { continue }
                if !page.path.hasSuffix("/embed/"), pages.isEmpty,
                   let embed = URL(string: "https://www.instagram.com/reel/\(code)/embed/") { pages.append(embed) }
                let raw = try? await web.callAsyncJavaScript(playerScript,
                    arguments: ["expectedCode": code, "tryPlayer": !tried.isEmpty], in: nil, contentWorld: .defaultClient)
                guard let values = raw as? [String], let caption = values.first else { continue }
                if result.caption == nil, !caption.isEmpty, !["instagram", "login instagram"].contains(ClipText.comparable(caption)) {
                    result.caption = caption
                }
                let prefix = "data:image/jpeg;base64,"
                let images = values.dropFirst().filter { $0.hasPrefix(prefix) && $0.count < 1_500_000 }
                    .prefix(4).compactMap { Data(base64Encoded: String($0.dropFirst(prefix.count))) }
                if !images.isEmpty {
                    result.reading = await ClipFrames.recognize(images)
                    return result
                }
                for candidate in values.dropFirst().compactMap({ mediaURL($0) }) {
                    guard tried.count < 3, tried.insert(candidate).inserted else { continue }
                    if let reading = await sample(candidate) { result.reading = reading; return result }
                }
            }
        }
        return result
    }

    private static func sample(_ media: URL) async -> ClipFrames.Reading? {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 15
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let limit = 32 * 1024 * 1024
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let (bytes, response) = try await session.bytes(from: media)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Int64(limit),
                  let final = response.url, mediaURL(final.absoluteString) != nil,
                  let mime = response.mimeType, mime.hasPrefix("video/") || mime == "application/octet-stream" else { return nil }
            try Data().write(to: file)
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            var count = 0, buffer = Data()
            for try await byte in bytes {
                count += 1
                guard count <= limit else { return nil }
                buffer.append(byte)
                if buffer.count == 65536 {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            try handle.write(contentsOf: buffer)
            try Task.checkCancellation()
            let reading = await ClipFrames.read(file, video: true)
            return reading.frames.isEmpty ? nil : reading
        } catch { return nil }
    }
}
