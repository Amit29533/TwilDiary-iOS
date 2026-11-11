import SwiftUI
import AuthenticationServices
import WebKit
import TwilDiaryCore

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
        case cloudflare = "Google or email"
        case passcode = "Owner passcode"
        case token = "Access token"
        case trakt = "Trakt"
        var id: String { rawValue }
        /// One line under the picker, so the choice explains itself.
        var hint: String {
            switch self {
            case .cloudflare: "Your server’s usual sign-in page (Cloudflare Access): Google, or a one-time code by email."
            case .passcode: "Owner email and passcode."
            case .token: "A private access token made for this diary."
            case .trakt: "Your Trakt app ID and access token."
            }
        }
    }
    let completion: @MainActor (AccessCredential) -> Void
    /// Trakt signed in, but your server didn't give a diary session (Cloudflare Access in front of
    /// it): open the app on Trakt alone. nil where that isn't offered (connecting a server later).
    var phoneOnly: (@MainActor (MainTracker) -> Void)? = nil
    /// "On this phone": no account; nil where it isn't offered.
    var onThisPhone: (@MainActor () -> Void)? = nil
    @Environment(DiaryStore.self) private var store
    @State private var serviceSigningIn: MainTracker?
    @State private var mode: SignInMode = .passcode
    @State private var showOtherWays = false
    @State private var traktSigningIn = false
    @State private var webSigningIn = false
    @State private var webError: String?
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var personalToken = ""
    @State private var ownerEmail = ""
    @State private var ownerPasscode = ""
    @State private var traktClientId = ""
    @State private var traktAccessToken = ""
    @State private var submitting = false
    @State private var formError: String?
    var body: some View {
        ScrollView {
            // The mark, the heading, the ways in (Trakt, then Google or email), then Other ways.
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    BrandMark().fill(HomeStyle.chipText).frame(width: 36, height: 36).accessibilityHidden(true)
                    Text(phoneOnly == nil ? "Sign in to your diary" : "How should we keep your library?").font(.system(size: 28, weight: .bold)).tracking(-0.5).foregroundStyle(HomeStyle.primary)
                    Text(phoneOnly == nil ? "Sign in to your TwilDiary server." : "Pick where your library lives. You can connect more services and your TwilDiary server any time.")
                        .font(.system(size: 15)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // The ways in, as rows (as Cinopsys lists them): Trakt first, then your server's own
                // sign-in page. Both open in Apple's sign-in sheet and come straight back.
                VStack(alignment: .leading, spacing: 10) {
                    // Trakt's own sign-in page; your server checks it's the Trakt account linked to
                    // your diary, and this iPhone stays signed in to Trakt as well.
                    optionRow(busy: traktSigningIn, id: "sign-in-trakt", title: "Trakt", detail: "Syncs to your Trakt account") {
                        BrandLogo(service: .trakt, size: 40)
                    } action: {
                        Task {
                            if let traktApp = await traktAppID() { await traktSignIn(traktApp) }
                            else { webError = "Your server hasn’t shared its Trakt app yet. Use Google or email this once; Trakt is offered from then on." }
                        }
                    }
                    // Simkl, MDBList and WeTrakr: the app opens on that service alone.
                    if phoneOnly != nil {
                        ForEach([MainTracker.simkl, .mdblist, .wetrakr], id: \.self) { tracker in
                            optionRow(busy: serviceSigningIn == tracker, id: "sign-in-" + tracker.rawValue, title: tracker.name,
                                      detail: "Syncs to your \(tracker.name) account") {
                                BrandLogo(service: tracker.brand, size: 40)
                            } action: { Task { await serviceSignIn(tracker) } }
                        }
                    }
                    if let onThisPhone {
                        optionRow(busy: false, id: "sign-in-local", title: "On this phone", detail: "Stays on this phone. No account") {
                            Image(systemName: "iphone").font(.system(size: 19, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                                .frame(width: 40, height: 40).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 9))
                        } action: { onThisPhone() }
                    }
                    optionRow(busy: webSigningIn, id: "sign-in-web", title: phoneOnly == nil ? "Google or email" : "Your TwilDiary server",
                              detail: phoneOnly == nil ? "Your TwilDiary server’s sign-in page" : "Google or email, for backups") {
                        Image(systemName: "globe").font(.system(size: 19, weight: .semibold)).foregroundStyle(HomeStyle.chipText)
                            .frame(width: 40, height: 40).background(HomeStyle.chip, in: RoundedRectangle(cornerRadius: 9))
                    } action: { Task { await webSignIn() } }
                    Text("Opens the sign-in page and comes straight back.")
                        .font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
                    if let webError {
                        Text(webError).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sign-in-browser-error")
                    }
                }
                Button { withAnimation(Motion.smooth) { showOtherWays.toggle() } } label: {
                    HStack {
                        Text("Other ways to sign in").font(.system(size: 15, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(HomeStyle.secondary)
                            .rotationEffect(.degrees(showOtherWays ? 180 : 0))
                    }.padding(.horizontal, 16).frame(minHeight: 52).contentShape(Rectangle()).modifier(SettingsCard())
                }.buttonStyle(.plain).accessibilityIdentifier("sign-in-other-ways")
                if showOtherWays {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Other ways").font(.system(size: 17, weight: .bold)).foregroundStyle(HomeStyle.primary)
                        Spacer(minLength: 8)
                        Menu {
                            Picker("Sign in with", selection: $mode) {
                                ForEach(SignInMode.allCases.filter { $0 != .cloudflare }) { item in Text(item.rawValue).tag(item) }
                            }
                        } label: {
                            HStack(spacing: 6) { Text(mode.rawValue); Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(HomeStyle.chipText)
                                .padding(.horizontal, 12).frame(height: 32).background(HomeStyle.chip, in: Capsule())
                        }.accessibilityLabel("Sign in with").accessibilityValue(mode.rawValue).accessibilityIdentifier("sign-in-method-picker")
                    }
                    Text(mode.hint).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).fixedSize(horizontal: false, vertical: true)
                    alternativeForm
                }.padding(16).modifier(SettingsCard())
                }
            }.padding(20)
        }.scrollDismissesKeyboard(.interactively)
            .onChange(of: mode) { _, _ in formError = nil }
    }

    private var alternativeForm: some View {
            VStack(alignment: .leading, spacing: 16) {
                if mode == .token {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Personal Access Token").font(.headline)
                        Text("Use the private access token provided for your diary.")
                            .font(.caption).foregroundStyle(.secondary)
                        SecureField("Paste access token", text: $personalToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField()
                            .accessibilityIdentifier("sign-in-token-field")
                    }
                } else if mode == .passcode {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Owner email", text: $ownerEmail)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                            .settingsField()
                            .accessibilityIdentifier("sign-in-email-field")
                        SecureField("Passcode", text: $ownerPasscode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField()
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
                            .settingsField()
                        SecureField("Trakt OAuth Access Token", text: $traktAccessToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .settingsField()
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
                .buttonStyle(SettingsWideButtonStyle())
                .disabled(submitting)
                .accessibilityIdentifier("sign-in-submit-button")
            }
    }

    /// Your server's sign-in page in Apple's sign-in sheet; `/api/session/app` hands the session back
    /// to `twildiary://auth/diary?token=…` once Cloudflare Access has signed you in.
    private func webSignIn() async {
        webError = nil; webSigningIn = true
        defer { webSigningIn = false }
        do {
            let start = AppConfiguration.backend.appendingPathComponent("api/session/app")
            let callback = try await webAuthenticationSession.authenticate(using: start, callbackURLScheme: ProviderWebSignIn.callbackScheme)
            let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
            guard parts?.host == "auth", parts?.path == "/diary",
                  let token = parts?.queryItems?.first(where: { $0.name == "token" })?.value, AccessCookiePolicy.validToken(token) else {
                webError = "Sign-in finished without a usable diary session. Please try again."; return
            }
            completion(AccessCredential(token: token, expires: nil))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // Closing the sheet is not an error.
        } catch {
            webError = "The sign-in page couldn’t finish: " + error.localizedDescription
        }
    }

    private func optionRow<Icon: View>(busy: Bool, id: String, title: String, detail: String, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(busy ? "Signing in…" : title).font(.system(size: 16, weight: .semibold)).foregroundStyle(HomeStyle.primary).lineLimit(1)
                    Text(detail).font(.system(size: 13)).foregroundStyle(HomeStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) } else { SettingsChevron() }
            }.padding(.horizontal, 15).frame(minHeight: 68).contentShape(Rectangle()).modifier(SettingsCard())
        }.buttonStyle(.plain).disabled(webSigningIn || traktSigningIn || serviceSigningIn != nil || submitting).accessibilityIdentifier(id)
    }
    /// Simkl, MDBList or WeTrakr: its own sign-in page, then the app opens on that service.
    private func serviceSignIn(_ tracker: MainTracker) async {
        webError = nil; serviceSigningIn = tracker
        defer { serviceSigningIn = nil }
        do {
            if case .signedIn = try await ServiceSignIn.run(tracker.provider, store: store, using: webAuthenticationSession) { phoneOnly?(tracker) }
        } catch { webError = error.localizedDescription }
    }
    /// TwilDiary's Trakt app ID: built in, remembered, or from your server's public sign-in check.
    private func traktAppID() async -> String? {
        if let known = ProviderAppIDs.id(for: .trakt) { return known }
        struct Check: Decodable { let traktClientId: String? }
        var request = URLRequest(url: AppConfiguration.backend.appendingPathComponent("api/auth"), timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let id = (try? JSONDecoder().decode(Check.self, from: data))?.traktClientId else { return nil }
        ProviderAppIDs.remember([.trakt: id])
        return ProviderAppIDs.id(for: .trakt)
    }
    /// Continue with Trakt: Trakt's page in Apple's sheet (PKCE), then your server signs you in once
    /// that Trakt account is the one linked to your diary. The same sign-in becomes this iPhone's
    /// Trakt connection, so Trakt needs no second sign-in.
    private func traktSignIn(_ clientId: String) async {
        webError = nil; traktSigningIn = true
        defer { traktSigningIn = false }
        do {
            guard let tokens = try await ServiceSignIn.tokens(.trakt, clientId: clientId, using: webAuthenticationSession, client: DirectProviderClient()) else { return }
            let authURL = AppConfiguration.backend.appendingPathComponent("api/auth")
            var request = URLRequest(url: authURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let host = authURL.host { request.setValue("\(authURL.scheme ?? "https")://\(host)", forHTTPHeaderField: "Origin") }
            request.httpBody = try JSONSerialization.data(withJSONObject: ["method": "provider", "provider": "trakt", "accessToken": tokens.accessToken, "clientId": clientId])
            let reply = try? await URLSession.shared.data(for: request)
            let json = reply.flatMap { (try? JSONSerialization.jsonObject(with: $0.0)) as? [String: Any] }
            guard let http = reply?.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let issued = json?["token"] as? String, AccessCookiePolicy.validToken(issued) else {
                PendingTraktSignIn.waiting = (clientId, tokens)
                // No diary session from your server (it sits behind Cloudflare Access, or is
                // offline): Trakt alone opens the app; the server can be connected later.
                if let phoneOnly { phoneOnly(.trakt); return }
                PendingTraktSignIn.waiting = nil
                let message = (json?["error"] as? [String: Any])?["message"] as? String
                webError = message ?? "Your server didn’t accept this Trakt account. Use the Trakt account linked to your diary, or Continue with Google or email."
                return
            }
            PendingTraktSignIn.waiting = (clientId, tokens)
            completion(AccessCredential(token: issued, expires: (json?["expiresAt"] as? String).flatMap(DiaryDate.parse)))
        } catch {
            webError = "Trakt sign-in couldn’t finish: " + error.localizedDescription
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
                    expiry = DiaryDate.parse(expStr)
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
