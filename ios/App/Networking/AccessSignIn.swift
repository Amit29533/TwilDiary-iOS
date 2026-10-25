import SwiftUI
import WebKit

enum SignInNavigationPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == "https" { return url.host?.isEmpty == false && url.user == nil && url.password == nil }
        return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
    }
}

/// A browser is used only for the existing Cloudflare login, never app screens.
@MainActor struct AccessSignIn: View {
    let completion: @MainActor (AccessCredential) -> Void
    @State private var state = AccessSignInState()
    @State private var browserID = UUID()
    var body: some View {
        VStack(spacing: 0) {
            AccessAuthenticationBrowser(state: state, completion: completion).id(browserID)
            if let error = state.error {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error).font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sign-in-browser-error")
                    Button("Try again") { state.restart(); browserID = UUID() }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).accessibilityIdentifier("sign-in-browser-retry")
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.regularMaterial)
            }
        }
    }
}

@MainActor private struct AccessAuthenticationBrowser: UIViewRepresentable {
    let state: AccessSignInState
    let completion: @MainActor (AccessCredential) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(state: state, completion: completion) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        context.coordinator.attach(web)
        web.load(URLRequest(url: AppConfiguration.backend.appendingPathComponent("api/session")))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.stop(); web.navigationDelegate = nil; web.uiDelegate = nil; web.stopLoading()
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
        private let state: AccessSignInState
        private let ticket: UUID
        private let completion: @MainActor (AccessCredential) -> Void
        private weak var web: WKWebView?
        private var cookieStore: WKHTTPCookieStore?
        private var checking: Task<Void, Never>?
        private var reading = false
        private var readAgain = false
        init(state: AccessSignInState, completion: @escaping @MainActor (AccessCredential) -> Void) {
            self.state = state; self.ticket = state.begin(); self.completion = completion
        }
        func attach(_ web: WKWebView) {
            self.web = web; web.navigationDelegate = self; web.uiDelegate = self
            cookieStore = web.configuration.websiteDataStore.httpCookieStore
            cookieStore?.add(self)
        }
        func stop() {
            state.stop(ticket); checking?.cancel(); checking = nil
            cookieStore?.remove(self); cookieStore = nil; web = nil
        }
        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) { inspectCookies() }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            SignInNavigationPolicy.allows(navigationAction.request.url) ? .allow : .cancel
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil, SignInNavigationPolicy.allows(navigationAction.request.url) { webView.load(navigationAction.request) }
            return nil
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            checking?.cancel(); checking = nil; state.started(ticket)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            inspectCookies()
            // Bound only post-session cookie propagation, never user-driven 2FA.
            guard state.active(ticket), AccessCookiePolicy.isSessionFinish(webView.url), checking == nil else { return }
            checking = Task { @MainActor [weak self] in
                for _ in 0..<6 {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard let self, self.state.active(self.ticket), AccessCookiePolicy.isSessionFinish(self.web?.url) else { return }
                    self.inspectCookies()
                }
                guard let self, !Task.isCancelled else { return }
                self.state.missingCredential(self.ticket); self.checking = nil
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { state.failed(error, ticket: ticket) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { state.failed(error, ticket: ticket) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { state.interrupted(ticket) }
        private func inspectCookies() {
            guard state.active(ticket), AccessCookiePolicy.trusted(web?.url), let cookieStore else { return }
            if reading { readAgain = true; return }
            reading = true
            cookieStore.getAllCookies { [weak self] cookies in
                guard let self else { return }
                self.reading = false
                guard self.state.active(self.ticket) else { return }
                if let value = self.state.consume(cookies, at: self.web?.url, ticket: self.ticket) {
                    self.checking?.cancel(); self.checking = nil
                    self.completion(value)
                } else if self.readAgain {
                    self.readAgain = false; self.inspectCookies()
                }
            }
        }
    }
}
