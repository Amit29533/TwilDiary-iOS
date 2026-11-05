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
            case .passcode: "The owner email and passcode set on your server."
            case .token: "A private access token made for this diary."
            case .trakt: "Your Trakt app ID and access token."
            }
        }
    }
    let completion: @MainActor (AccessCredential) -> Void
    @State private var mode: SignInMode = .passcode
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
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    BrandMark().fill(Color(webHex: "#8E5CF0")).frame(width: 40, height: 40).accessibilityHidden(true)
                    Text("Sign in to your diary").font(.title2.bold())
                    Text("Your diary lives on your own TwilDiary server. Sign in the way you set it up.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                // The usual way: your server's sign-in page in Apple's sign-in sheet (Safari), so
                // Google, email codes, passkeys and saved passwords all work.
                VStack(alignment: .leading, spacing: 8) {
                    Button { Task { await webSignIn() } } label: {
                        HStack(spacing: 8) {
                            if webSigningIn { ProgressView().controlSize(.small) } else { Image(systemName: "globe") }
                            Text(webSigningIn ? "Signing in…" : "Continue with Google or email").font(.system(size: 16, weight: .semibold))
                        }.frame(maxWidth: .infinity).frame(minHeight: 30)
                    }.buttonStyle(.glassProminent).controlSize(.large).disabled(webSigningIn || submitting)
                        .accessibilityIdentifier("sign-in-web")
                    Text("Opens your server’s sign-in page (Cloudflare Access) and comes straight back.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let webError {
                        Text(webError).font(.footnote).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("sign-in-browser-error")
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Other ways").font(.headline)
                        Spacer(minLength: 8)
                        Picker("Sign in with", selection: $mode) {
                            ForEach(SignInMode.allCases.filter { $0 != .cloudflare }) { item in Text(item.rawValue).tag(item) }
                        }.pickerStyle(.menu).accessibilityIdentifier("sign-in-method-picker")
                    }
                    Text(mode.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    alternativeForm
                }.padding(16).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.08)))
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
                            .padding(12)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("sign-in-token-field")
                    }
                } else if mode == .passcode {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Owner Email & Passcode").font(.headline)
                        Text("Use the email and passcode set for this diary.")
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
