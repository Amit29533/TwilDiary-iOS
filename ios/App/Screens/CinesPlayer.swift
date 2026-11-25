import SwiftUI
import WebKit

/// Cines' one video player: YouTube's own embedded player (the IFrame API) in a web view, as
/// YouTube's terms allow; nothing is downloaded. Set up as YouTubePlayerKit 2.0.5 sets its player
/// up: the page is loaded with `https://<bundle id>` as its address and that same `origin` given to
/// the player (YouTube refuses embeds that don't say which app they're in), inline playback, and no
/// tap needed to start. One web view serves the whole feed: the page on screen holds it and a swipe
/// loads the next video into it, rather than a web view per clip.
@MainActor @Observable final class CinesPlayer {
    /// The video playing (or about to).
    private(set) var current: String?
    private(set) var progress: Double = 0
    private(set) var playing = false
    private(set) var paused = false
    /// The clips the player refused (embedding switched off, removed).
    private(set) var refused = Set<String>()
    var muted = true { didSet { if muted != oldValue { run(muted ? "player.mute()" : "player.unMute()") } } }

    @ObservationIgnored private var ready = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var away = false
    @ObservationIgnored private var made: WKWebView?
    /// Made on first use, then kept for the whole feed.
    var web: WKWebView {
        if let made { return made }
        let web = makeWeb()
        made = web
        return web
    }

    static var origin: String { "https://" + (Bundle.main.bundleIdentifier?.lowercased() ?? "twildiary") }

    /// Plays a clip (muted until Sound is turned on).
    func play(_ id: String) {
        guard id != current else { if !away { resume() }; return }
        current = id
        progress = 0
        playing = false
        paused = false
        guard ready else { start(); return }
        load(id)
    }
    func toggle() {
        guard current != nil else { return }
        if paused { resume() } else { paused = true; run("player.pauseVideo()") }
    }
    /// Leaving the page (a title's page pushed over it, or back to Home).
    func leave() {
        away = true
        run("player.pauseVideo()")
    }
    func back() {
        away = false
        resume()
    }
    func stop() {
        run("player.stopVideo()")
        current = nil
        progress = 0
        playing = false
    }
    private func resume() {
        paused = false
        run("player.playVideo()")
    }
    private func load(_ id: String) {
        // The id was checked against YouTube's id characters when the feed read it.
        run("player.loadVideoById('\(id)');" + (muted ? "player.mute();" : "player.unMute();"))
        if away { run("player.pauseVideo()") }
    }
    private func run(_ script: String) {
        guard ready else { return }
        web.evaluateJavaScript("try{" + script + "}catch(e){}", completionHandler: nil)
    }

    // MARK: The page

    private func start() {
        guard !started else { return }
        started = true
        web.loadHTMLString(Self.html, baseURL: URL(string: Self.origin))
    }
    fileprivate func received(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["e"] as? String else { return }
        switch event {
        case "ready":
            ready = true
            if let current { load(current) }
        case "state":
            let state = message["v"] as? Int ?? -1
            if state == 1 { playing = true } // playing
            if state == 0 { run("player.seekTo(0, true);player.playVideo()") } // ended: loop, as a reel does
        case "time":
            guard let time = message["t"] as? Double, let duration = message["d"] as? Double, duration > 0 else { return }
            let value = min(1, max(0, time / duration))
            if abs(value - progress) > 0.002 { progress = value }
        case "error":
            if let current { refused.insert(current); CinesFeed.markFailed(current) }
        case "apiFailed":
            started = false
            if let current { refused.insert(current) }
        default: break
        }
    }

    private func makeWeb() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = false
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.preferences.isTextInteractionEnabled = false
        configuration.userContentController.add(CinesMessages(owner: self), name: "cines")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        // Clear, so the title's picture shows round the video where YouTube leaves it bare.
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        // Taps and swipes belong to the feed (a tap pauses), not to YouTube's page.
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true
        return web
    }

    private static var html: String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;overflow:hidden}#player{position:absolute;top:0;left:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div><script>
        var player,ready=false;
        function send(m){try{window.webkit.messageHandlers.cines.postMessage(m)}catch(e){}}
        var tag=document.createElement('script');tag.src="https://www.youtube.com/iframe_api";tag.onerror=function(){send({e:'apiFailed'})};document.head.appendChild(tag);
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{width:'100%',height:'100%',
            playerVars:{playsinline:1,controls:0,rel:0,fs:0,iv_load_policy:3,disablekb:1,enablejsapi:1,autoplay:1,mute:1,origin:'\(origin)'},
            events:{onReady:function(){ready=true;send({e:'ready'})},
                    onStateChange:function(ev){send({e:'state',v:ev.data})},
                    onError:function(ev){send({e:'error',v:ev.data})}}});
        }
        setInterval(function(){if(ready&&player.getDuration&&player.getPlayerState()==1){var d=player.getDuration();if(d>0)send({e:'time',t:player.getCurrentTime(),d:d})}},400);
        </script></body></html>
        """
    }
}

/// The page's messages, held weakly: the web view's content controller keeps its handlers.
@MainActor private final class CinesMessages: NSObject, WKScriptMessageHandler {
    weak var owner: CinesPlayer?
    init(owner: CinesPlayer) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.received(message.body)
    }
}

/// Where the player shows: the page on screen holds the one web view.
struct CinesPlayerHost: UIViewRepresentable {
    let player: CinesPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        attach(to: view)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { attach(to: view) }
    private func attach(to view: UIView) {
        let web = player.web
        guard web.superview !== view else { return }
        web.removeFromSuperview()
        web.frame = view.bounds
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(web)
    }
}
