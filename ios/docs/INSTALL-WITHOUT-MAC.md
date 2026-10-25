# Install without a Mac

CI publishes an unsigned arm64 iPhone IPA. It is not an App Store or TestFlight build. Download the TwilDiary-unsigned-IPA artifact from the successful GitHub Actions run, extract the archive and keep its SHA-256 file with the IPA.

For your existing LiveContainer setup, import the IPA through LiveContainer's app management and use the signing/JIT workflow required by your installed LiveContainer version. The app uses Keychain for its Cloudflare session; verify login persistence on the physical phone because container isolation can affect credential storage.

On Windows, Sideloadly or AltStore Classic can sign/install an app using your own Apple ID. Follow the tool's current official Windows installation instructions; signing, device trust, Developer Mode and renewal rules depend on your account and iOS version. No Apple ID or signing credential is included in this repository or entered into CI.

- Sideloadly: https://sideloadly.io/
- AltStore Windows: https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows
- LiveContainer: https://github.com/LiveContainer/LiveContainer#installing-apps

For TestFlight, an Apple Developer Program membership, registered bundle ID, signing/distribution configuration and App Store Connect access would be needed. Those are not configured. All current IPAs are unsigned, and no certificates or provisioning profiles are committed.

Build source: ios/project.yml. Actions generates the Xcode project, builds with Xcode 26.6, runs simulator tests and packages the physical-device Release application in Payload/TwilDiary.app. Minimum supported version is iOS 26; your iOS 27 phone is within that deployment range, subject to physical-device verification.
