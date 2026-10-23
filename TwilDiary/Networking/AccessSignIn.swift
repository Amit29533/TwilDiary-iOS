import SwiftUI
import WebKit

/// A browser is used only for the existing Cloudflare login, never for app screens.
struct AccessSignIn: UIViewRepresentable {
    let completion: (AccessCredential) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: AppConfiguration.backend.appendingPathComponent("api/session")))
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let completion: (AccessCredential) -> Void
        var completed = false
        init(completion: @escaping (AccessCredential) -> Void) { self.completion = completion }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !completed, let url = webView.url, url.scheme == "https", url.host == AppConfiguration.backend.host,
                  url.path == "/api/session" else { return }
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self, !self.completed, let host = AppConfiguration.backend.host else { return }
                guard let cookie = cookies.first(where: {
                    let domain = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return $0.name == "CF_Authorization" && $0.isSecure && (host == domain || host.hasSuffix("." + domain)) && ($0.expiresDate.map { $0 > .now } ?? true)
                }) else { return }
                self.completed = true
                self.completion(AccessCredential(token: cookie.value, expires: cookie.expiresDate))
            }
        }
    }
}
