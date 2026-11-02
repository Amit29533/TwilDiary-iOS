import SwiftUI
import WebKit

enum SignInNavigationPolicy {
    static func allows(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.scheme?.lowercased() == "https" { return url.host?.isEmpty == false && url.user == nil && url.password == nil }
        return url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
    }
}

/// Supports Cloudflare Access SSO, Personal Access Token, Email & Passcode, and Trakt OAuth sign-in.
@MainActor struct AccessSignIn: View {
    enum SignInMode: String, CaseIterable, Identifiable {
        case cloudflare = "Cloudflare SSO"
        case token = "Access Token"
        case passcode = "Passcode"
        case trakt = "Trakt OAuth"
        var id: String { rawValue }
    }
    let completion: @MainActor (AccessCredential) -> Void
    @State private var mode: SignInMode = .cloudflare
    @State private var state = AccessSignInState()
    @State private var browserID = UUID()
    @State private var personalToken = ""
    @State private var ownerEmail = ""
    @State private var ownerPasscode = ""
    @State private var traktClientId = ""
    @State private var traktAccessToken = ""
    @State private var submitting = false
    @State private var formError: String?
    var body: some View {
        VStack(spacing: 0) {
            Picker("Sign-in method", selection: $mode) {
                ForEach(SignInMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("sign-in-method-picker")
            .onChange(of: mode) { _, _ in formError = nil }

            if mode == .cloudflare {
                AccessAuthenticationBrowser(state: state, completion: completion).id(browserID)
                if let error = state.error {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(.subheadline).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sign-in-browser-error")
                        Button("Try again") { state.restart(); browserID = UUID() }
                            .buttonStyle(.glassProminent).buttonBorderShape(.capsule).accessibilityIdentifier("sign-in-browser-retry")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16).background(.regularMaterial)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if mode == .token {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Personal Access Token").font(.headline)
                                Text("Sign in directly using your server’s DIARY_ACCESS_TOKEN or a signed session token without Cloudflare Access.")
                                    .font(.caption).foregroundStyle(.secondary)
                                SecureField("Paste access token", text: $personalToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityIdentifier("sign-in-token-field")
                            }
                        } else if mode == .passcode {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Owner Email & Passcode").font(.headline)
                                Text("Authenticate with your configured DIARY_OWNER_EMAIL and DIARY_OWNER_PASSCODE.")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("Owner email", text: $ownerEmail)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityIdentifier("sign-in-email-field")
                                SecureField("Passcode", text: $ownerPasscode)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityIdentifier("sign-in-passcode-field")
                            }
                        } else if mode == .trakt {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Sign in with Trakt").font(.headline)
                                Text("Verify ownership using your connected Trakt account’s OAuth token.")
                                    .font(.caption).foregroundStyle(.secondary)
                                TextField("Trakt Client ID (optional if set on server)", text: $traktClientId)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                SecureField("Trakt OAuth Access Token", text: $traktAccessToken)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .padding(12)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                                    .accessibilityIdentifier("sign-in-trakt-token-field")
                            }
                        }

                        if let formError {
                            Text(formError)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("sign-in-form-error")
                        }

                        Button {
                            Task { await submitAlternativeSignIn() }
                        } label: {
                            HStack {
                                if submitting { ProgressView().controlSize(.small) }
                                Text(submitting ? "Signing in…" : "Sign in")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(submitting)
                        .accessibilityIdentifier("sign-in-submit-button")
                    }
                    .padding(20)
                }
            }
        }
    }

    private func submitAlternativeSignIn() async {
        formError = nil
        submitting = true
        defer { submitting = false }

        var payload: [String: String] = [:]
        switch mode {
        case .cloudflare:
            return
        case .token:
            let trimmed = personalToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard AccessCookiePolicy.validToken(trimmed) else {
                formError = "Enter a valid access token."
                return
            }
            payload = ["method": "token", "token": trimmed]
        case .passcode:
            let email = ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            let code = ownerPasscode.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !email.isEmpty, !code.isEmpty else {
                formError = "Enter both your owner email and passcode."
                return
            }
            payload = ["method": "passcode", "email": email, "passcode": code]
        case .trakt:
            let token = traktAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                formError = "Enter your Trakt OAuth access token."
                return
            }
            payload = [
                "method": "provider",
                "provider": "trakt",
                "accessToken": token,
                "clientId": traktClientId.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }

        do {
            let authURL = AppConfiguration.backend.appendingPathComponent("api/auth")
            var request = URLRequest(url: authURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let origin = URL(string: "\(authURL.scheme ?? "https")://\(authURL.host ?? "")") {
                request.setValue(origin.absoluteString, forHTTPHeaderField: "Origin")
            }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                formError = "Could not reach the diary server."
                return
            }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (200..<300).contains(http.statusCode),
               let issuedToken = json?["token"] as? String,
               AccessCookiePolicy.validToken(issuedToken) {
                var expiry: Date?
                if let expStr = json?["expiresAt"] as? String {
                    expiry = ISO8601DateFormatter().date(from: expStr)
                }
                completion(AccessCredential(token: issuedToken, expires: expiry))
            } else if mode == .token, let rawToken = payload["token"], AccessCookiePolicy.validToken(rawToken) {
                // Allow direct bearer/cookie validation through DiaryAPI.authenticate if /api/auth is not used
                completion(AccessCredential(token: rawToken, expires: nil))
            } else {
                let errObj = json?["error"] as? [String: Any]
                formError = (errObj?["message"] as? String) ?? "Sign-in failed (HTTP \(http.statusCode))."
            }
        } catch {
            if mode == .token, let rawToken = payload["token"], AccessCookiePolicy.validToken(rawToken) {
                completion(AccessCredential(token: rawToken, expires: nil))
            } else {
                formError = "Could not connect to sign in. Check your network and try again."
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
