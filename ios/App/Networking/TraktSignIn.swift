import SwiftUI
import WebKit

/// Auth-only browser. The existing server owns PKCE, state validation and provider tokens.
struct TraktSignIn: UIViewRepresentable {
    let credential: AccessCredential
    let completion: (Result<Void, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config); web.navigationDelegate = context.coordinator
        guard let host = AppConfiguration.backend.host,
              let cookie = HTTPCookie(properties: [.domain: host, .path: "/", .name: "CF_Authorization", .value: credential.token, .secure: "TRUE", .expires: credential.expires ?? Date.now.addingTimeInterval(600)]) else { return web }
        Task { @MainActor in
            await config.websiteDataStore.httpCookieStore.setCookie(cookie)
            var request = URLRequest(url: AppConfiguration.backend.appendingPathComponent("api/trakt/connect"))
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(AppConfiguration.backend.absoluteString, forHTTPHeaderField: "Origin")
            web.load(request)
        }
        return web
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate {
        let completion: (Result<Void, Error>) -> Void
        private var finished = false
        init(completion: @escaping (Result<Void, Error>) -> Void) { self.completion = completion }
        private func finish(_ result: Result<Void, Error>) { guard !finished else { return }; finished = true; completion(result) }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url, url.scheme == "https", url.host == AppConfiguration.backend.host, url.path == "/preview/more/trakt",
               let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, let outcome = items.first(where: { $0.name == "trakt" })?.value {
                decisionHandler(.cancel)
                if outcome == "connected" { finish(.success(())) }
                else { finish(.failure(APIError.message("Trakt sign-in was not completed. Check the account and registered callback, then try again."))) }
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished, let url = webView.url, url.scheme == "https", url.host == AppConfiguration.backend.host, url.path == "/api/trakt/connect" else { return }
            Task { @MainActor in
                do {
                    let raw = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
                    struct Response: Decodable { let url: URL }
                    let target = try JSONDecoder().decode(Response.self, from: Data(raw.utf8)).url
                    guard target.scheme == "https", target.host == "auth.trakt.tv", target.port == nil, target.user == nil, target.password == nil else { throw APIError.message("Trakt returned an invalid sign-in destination.") }
                    webView.load(URLRequest(url: target))
                } catch { finish(.failure(APIError.message("Could not start Trakt sign-in. Refresh your diary session and try again."))) }
            }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { finish(.failure(error)) }
        }
    }
}
