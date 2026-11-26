import SwiftUI
import WebKit

/// Cines' one video player: YouTube's own embedded player (the IFrame API) in a web view, as
/// YouTube's terms allow; nothing is downloaded. Set up as YouTubePlayerKit 2.0.5 sets its player
/// up: the page is loaded with `https://<bundle id>` as its address and that same `origin` given to
/// the player (YouTube refuses embeds that don't say which app they're in), inline playback, and no
/// tap needed to start. One web view serves the whole feed: the page on screen holds it and a swipe
/// loads the next video into it, rather than a web view per clip.
///
/// No YouTube controls or buttons over the video (owner's call, 25 Nov 2026), done the way
/// youtube_player_flutter 4.0.0 does it on iOS (`PlayerHost.swift`, `frame_script.dart`,
/// `element.dart`): YouTube's controls are off and taps don't reach its player ("custom controls":
/// the page's own tap pauses and plays), and a style sheet injected into YouTube's embed frame at
/// document start (a WKUserScript in every frame, so it never flashes) hides YouTube's own parts:
/// its logo, title, channel, Share, Watch later, "More videos", related videos, end screen and info
/// cards (youtube_player_flutter's list), plus the controls bars, big play button and spinner
/// (added here; not in its list). YouTube doesn't document these names, so one may stop matching
/// when YouTube changes its player, and hiding them is outside YouTube's terms (a personal app).
@MainActor @Observable final class CinesPlayer {
    /// The video playing (or about to).
    private(set) var current: String?
    private(set) var progress: Double = 0
    /// The clip's length in seconds (0 until YouTube says).
    private(set) var duration: Double = 0
    private(set) var playing = false
    /// Paused (a tap, or leaving the page).
    private(set) var paused = false
    /// The clips the player refused (embedding switched off, removed).
    private(set) var refused = Set<String>()
    var muted = true { didSet { if muted != oldValue { run(muted ? "player.mute()" : "player.unMute()") } } }
    /// Starts again at its end, as a reel does (Cines); off for a title's trailer, which then ends.
    var loops = true
    /// Played to its end (with `loops` off).
    private(set) var ended = false
    /// Sound on as soon as it plays (YouTube's player often won't start unmuted on its own, so it
    /// starts muted and turns the sound on once it's playing).
    var unmutesOnStart = false
    /// Asks YouTube to play again whenever it holds the video loaded but unstarted or cued (a title's
    /// trailer sometimes loaded and then sat waiting for a tap inside the video).
    var keepsStarting = false

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
    /// The video's picture is up: playing for a moment already (YouTube reports playing a little
    /// before its first frames, black until then).
    var pictureShowing: Bool { playing && progress * duration > 0.3 }
    func play(_ id: String) {
        guard id != current else { if !away { resume() }; return }
        current = id
        progress = 0
        duration = 0
        playing = false
        paused = false
        ended = false
        guard ready else { start(); return }
        load(id)
    }
    /// The page and YouTube's player loaded ahead, nothing played (a title page with a trailer
    /// gets it ready, so a tap starts the video at once).
    func prepare() { start() }
    /// The clip loaded again from the start and asked to play (a start YouTube didn't take).
    func reload() {
        guard let current else { return }
        ended = false
        load(current)
        run("player.playVideo()")
    }
    /// To this point of the clip (0 to 1): the bar at the bottom, dragged.
    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let value = min(1, max(0, fraction))
        progress = value
        run("player.seekTo(\(value * duration), true)")
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
            if state == 1 { // playing
                playing = true; paused = false
                if unmutesOnStart { unmutesOnStart = false; muted = false }
            }
            if state == 2 { paused = true } // paused (YouTube's own button, or leaving the page)
            // Loaded but not started (-1) or cued (5): asked to play at once, not at the next retry.
            if keepsStarting, state == -1 || state == 5, current != nil, !away { run("player.playVideo()") }
            if state == 0 {
                // Ended: again from the start, as a reel does; a trailer just ends.
                if loops { run("player.seekTo(0, true);player.playVideo()") } else { ended = true; playing = false }
            }
        case "time":
            guard let time = message["t"] as? Double, let duration = message["d"] as? Double, duration > 0 else { return }
            if self.duration != duration { self.duration = duration }
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
        configuration.userContentController.addUserScript(WKUserScript(source: Self.frameScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        // Clear, so the title's picture shows round the video where YouTube leaves it bare.
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        // Taps and swipes belong to the feed (a tap pauses), not to YouTube's player.
        web.isUserInteractionEnabled = false
        web.accessibilityElementsHidden = true
        return web
    }

    /// YouTube's parts to hide, as youtube_player_flutter names them (`element.dart`): logo, watch on
    /// YouTube, title, channel, Share, Watch later, Copy link, "More videos", related videos, end
    /// screen, info cards, context menu. Then ours: the controls bars and their shading, the big play
    /// button, the play/pause flash, YouTube's spinner, the "paid promotion" and branding marks.
    private static let hidden = [
        ".ytp-youtube-button", ".ytp-watermark", ".ytp-small-redirect",
        ".ytp-impression-link", ".watch-on-youtube-button-wrapper",
        ".ytp-title-text", ".ytp-title-link", ".ytmVideoInfoVideoTitle", ".ytwPlayerFullscreenTopControlsFullscreenControlsVideoTitle",
        ".ytp-title-channel", ".ytp-title-channel-logo", ".ytmVideoInfoChannelTitle", ".ytmVideoInfoChannelContainer",
        ".ytp-share-button", ".ytp-watch-later-button", ".ytp-copylink-button", ".fullscreen-action-menu .icon-link",
        ".ytp-pause-overlay", ".ytp-pause-overlay-container", ".fullscreen-watch-next-entrypoint-wrapper",
        "ytm-fullscreen-related-videos-entry-point-view-model", ".ytFullscreenVideoRecommendationsHost",
        ".ytp-videowall-still", ".ytp-modern-videowall-still", ".ytp-suggestion-link", ".ytp-ce-video", ".ytp-ce-playlist",
        ".ytFullscreenVideoRecommendationsRecommendation",
        ".ytp-endscreen-content", ".ytp-ce-element", ".ytp-cards-button", ".ytp-cards-teaser", ".ytp-contextmenu",
        // Not in youtube_player_flutter's list:
        ".ytp-chrome-top", ".ytp-chrome-bottom", ".ytp-gradient-top", ".ytp-gradient-bottom", ".ytp-title",
        ".ytp-large-play-button", ".ytp-bezel", ".ytp-bezel-text-wrapper", ".ytp-spinner", ".ytp-cued-thumbnail-overlay",
        ".ytp-paid-content-overlay", ".iv-branding", ".branding-img-container", ".ytp-overflow-button",
    ]

    /// Runs in every frame from its start; does anything only in YouTube's embed frame, where it adds
    /// the style sheet (and adds it again if the page replaces it). As youtube_player_flutter's
    /// `frame_script.dart`, with the video filling its frame.
    private static var frameScript: String {
        let selectors = hidden.joined(separator: ",")
        return #"""
        (function(){
          var w=window;
          if(w===w.top||w.__cinesFrame||!/^\/embed\//.test(location.pathname)||!/^www\.youtube(-nocookie)?\.com$/.test(location.hostname))return;
          w.__cinesFrame=true;
          var css='SELECTORS{display:none!important}'+
            '.html5-video-player>:not(.html5-video-container){display:none!important}'+
            // Whatever the player is made of (iPhones get YouTube's mobile player, whose play/pause
            // and Share have other names, so they still showed): nothing in the frame is drawn but
            // the video itself (a hidden box's child can still be shown, so the video stays).
            'body *{visibility:hidden!important}video{visibility:visible!important}'+
            '.html5-video-container{width:100%!important;height:100%!important}'+
            'video.html5-main-video{width:100%!important;height:100%!important;left:0!important;top:0!important;object-fit:contain!important}';
          function add(){
            var d=document;if(d.getElementById('__cines'))return;
            var s=d.createElement('style');s.id='__cines';s.textContent=css;
            (d.head||d.documentElement).appendChild(s);
          }
          add();
          document.addEventListener('DOMContentLoaded',add);
          w.addEventListener('load',add);
          if(w.MutationObserver){new MutationObserver(add).observe(document.documentElement,{childList:true});}
        })();
        """#.replacingOccurrences(of: "SELECTORS", with: selectors)
    }

    /// The page: YouTube's player, its events sent to the app, and its place in the video every
    /// 0.4 s while it plays (only then: the timer ran all the time, also in the trailer player kept
    /// loaded behind every title page).
    private static var html: String {
        """
        <!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
        <style>html,body{margin:0;padding:0;background:transparent;width:100%;height:100%;overflow:hidden}#player{position:absolute;top:0;left:0;width:100%;height:100%}</style>
        </head><body><div id="player"></div><script>
        var player,ready=false,tick=null;
        function send(m){try{window.webkit.messageHandlers.cines.postMessage(m)}catch(e){}}
        var tag=document.createElement('script');tag.src="https://www.youtube.com/iframe_api";tag.onerror=function(){send({e:'apiFailed'})};document.head.appendChild(tag);
        function onYouTubeIframeAPIReady(){
          player=new YT.Player('player',{width:'100%',height:'100%',
            playerVars:{playsinline:1,controls:0,rel:0,fs:0,iv_load_policy:3,disablekb:1,enablejsapi:1,autoplay:1,mute:1,origin:'\(origin)'},
            events:{onReady:function(){ready=true;send({e:'ready'})},
                    onStateChange:function(ev){send({e:'state',v:ev.data});if(ev.data==1){if(!tick)tick=setInterval(report,400)}else if(tick){clearInterval(tick);tick=null}},
                    onError:function(ev){send({e:'error',v:ev.data})}}});
        }
        function report(){if(ready&&player.getDuration&&player.getPlayerState()==1){var d=player.getDuration();if(d>0)send({e:'time',t:player.getCurrentTime(),d:d})}}
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
