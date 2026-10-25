# Native candidate pipeline in TwilDiary-iOS

The repository-root `codemagic.yaml` is the complete pipeline. It generates
`ios/project.yml` using pinned XcodeGen, tests Core/native/UI/layouts, compiles
unsigned arm64 Release, verifies resources/privacy and retains IPA, logs,
xcresults and screenshots. Xcode26.6, iOS26.5 and M2are pinned; no signing or
Cloudflare secrets are needed. This is native iOS testing, not a PWA UI walkthrough.

## Connection and branch policy

1. Connect **Amit29533/TwilDiary-iOS** in the existing Codemagic account/team.
   The prior app6adcc927390bc3069c9e5490points to the original TwilDiary repository
   and is retained for historical evidence. Its existing GitHub integration
   currently lists only TwilDiary; destination access must be enabled before
   same-repository official checks can be posted.
2. Choose `main` (or the explicit candidate branch) and workflow
   `native-ios-regression`. Do not start a build until the owner's next-build
   hold is lifted and native62phone feedback is incorporated. No automatic
   triggers are configured in the YAML.
3. Require the newest official `TwilDiary native iOS — unsigned regression`
   GitHub check from `codemagic-ci-cd` to be complete/success for that exact SHA.
   Initial checks can remain pending while a newer final check is created;
   fetch all pages/filter=all and use the verifier in `ios/tools`.
4. Only then run this repository's `ios.yml` manually on that same branch/SHA,
   or fast-forward a verified commit onto `ios-native`. Its gate asks
   `$GITHUB_REPOSITORY`, so checks on the original repo cannot silently qualify it.
5. Only a completely successful independent regression publishes a stable IPA.
   `native-ios-device-diagnostic` is for owner-authorized phone checks, never
   promotion. The imported native62 prerelease retains its original provenance.

No subscription, paid instance, signing, SSH key or API token is configured by
this migration. Existing integration permissions must not be broadened silently.
GitHub Actions is enabled on the destination; the local Node/database/release-tool
checks can run without Codemagic. Historical setup notes are preserved in
`ios/docs/legacy-repository/CODEMAGIC-BEFORE-CONSOLIDATION.md`.
