# Releasing Cadence

This guide is for project maintainers. Users do not need these steps to receive updates.

## Update trust

Cadence's `Info.plist` contains only the public Ed25519 key. The matching private key must remain in a maintainer's login Keychain or the encrypted GitHub Actions secret `SPARKLE_PRIVATE_KEY`. Never add an exported key, `.env` file, certificate, or signing password to the repository.

The local Keychain account label is `app.cadence.updates`.

## Code signing identity

macOS ties privacy grants such as Accessibility and Microphone to the app's code-signing identity. An ad-hoc signature has no identity beyond the binary's own hash, so every rebuild or update silently revoked those grants while System Settings still showed them enabled.

Cadence is therefore signed with a self-signed certificate named `Cadence Signing`. It costs nothing and keeps grants stable across updates. It does not satisfy Gatekeeper, so first launches of a downloaded build still require right-click → Open, exactly as with an ad-hoc build. Only a paid Apple Developer ID with notarization removes that step.

- The identity lives in a maintainer's login Keychain; its `.p12` export password is stored there under the service `app.cadence.signing`.
- GitHub Actions reads the base64-encoded `.p12` from the secret `CADENCE_SIGNING_P12` and its password from `CADENCE_SIGNING_P12_PASSWORD`; `scripts/import-signing-identity.sh` installs it into a temporary keychain.
- `scripts/build-app.sh` uses the identity when present and falls back to an ad-hoc signature otherwise, so contributors can build without it. The Edge and Release workflows refuse to publish a build that is not signed with it.
- `scripts/build-app.sh` stamps ordinary local bundles with the current time and a `-local.<commit>` display suffix so an older Edge feed cannot replace a smoke-test build. Distribution workflows set `CADENCE_DISTRIBUTION_BUILD=1` only after configuring their immutable version.
- Never replace the certificate casually: a new certificate is a new identity, and every user must re-grant Accessibility once. Keep the `.p12` backed up with the Sparkle key.

To export the identity for a new maintainer or a new secret, open Keychain Access, select `Cadence Signing` under My Certificates, export it as `.p12`, then `base64 -i Cadence.p12 | gh secret set CADENCE_SIGNING_P12`.

## Prepare locally

```sh
./scripts/prepare-release.sh X.Y.Z
```

The script:

1. Validates the semantic version.
2. Updates the marketing and numeric bundle versions.
3. Builds and signs `Cadence.app`.
4. Creates a symlink-preserving ZIP archive.
5. Generates a signed Sparkle appcast and fast LZFSE delta updates when older archives are available.
6. Creates and mount-tests a DMG containing `Cadence.app` and an Applications shortcut.

Apple supports distribution-signing a disk image only with a Developer ID Application identity. `scripts/build-dmg.sh` uses one automatically when available (or the identity named by `CADENCE_DMG_SIGNING_IDENTITY`); it intentionally leaves the DMG unsigned when the project has only its self-signed `Cadence Signing` app identity. That identity still seals the app and preserves privacy grants, but it does not replace Developer ID or notarization.

Nothing is uploaded automatically. Inspect the ignored `release/` directory before publishing.

## Required validation before Stable

Do not promote the first Stable (`1.0.0` or later) until the published Edge artifact passes this model-storage smoke test:

- [ ] On a disposable macOS user account with no FluidAudio cache, launch Cadence and confirm first-time setup downloads both Fast and Accurate encoders plus Silero VAD into Application Support.
- [ ] Update that exact installation to a newer Edge artifact and confirm the cached model file modification dates do not change, startup is labeled **Loading local model**, and neither encoder is downloaded again.
- [ ] With Mac speakers available, run `CADENCE_RUN_LIVE_MIC_TEST=1 swift test -Xswiftc -warnings-as-errors --filter liveMicrophonePreservesContextualWordsAndQuestionTag`, then dictate once with Fast and once with Accurate in the published app.
- [ ] Run the built-in editor smoke test against the signed build while no other Cadence instance is dictating:

  ```sh
  CADENCE_SMOKE_TEST=1 dist/Cadence.app/Contents/MacOS/Cadence
  ```

  It waits for the model, opens a scratch TextEdit document, starts dictation without the hot key, speaks “I like this better”, pauses three seconds, speaks “than that”, and exits 0 only when Accessibility confirms the editor holds exactly `I like this better than that.` (the pause's automatic period retracted). The build needs the Microphone and Accessibility grants that the `Cadence Signing` identity already carries.

`CADENCE_MEASURE_MODEL_LOAD=1 dist/Cadence.app/Contents/MacOS/Cadence` prints how long the launch path takes to make the selected model ready. A warm launch is well under a second; 20-60 seconds means Core ML recompiled, which macOS forces when free disk space is low enough to purge `~/Library/Caches/app.cadence.mac`.

The offline integration test proves that complete cached models load without network access, but it does not replace this first-install, updater, and physical-microphone check of the exact release artifact.

## Configure GitHub Actions

Export the private key to a temporary file:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account app.cadence.updates \
  -x /tmp/cadence-sparkle-private-key
```

Copy the file contents into the repository Actions secret named `SPARKLE_PRIVATE_KEY`, then securely delete the temporary file. Do not print the key in logs or pass it as a command-line argument.

After the exact Edge build passes the manual smoke test, run the **Release Cadence** workflow with:

- The new semantic version
- The commit SHA shown in that Edge build's version
- The smoke-test confirmation enabled

The workflow refuses to publish if the commit is not on `main`, is no longer the current Edge build, or lacks the explicit smoke-test confirmation. It creates a GitHub Release containing:

- `Cadence-X.Y.Z.zip`
- `Cadence-X.Y.Z.dmg`
- `appcast.xml`

People installing Cadence open the DMG and drag the app onto its Applications shortcut. Installed copies continue to read the appcast from the latest GitHub Release. Sparkle verifies the signed feed and ZIP archive, downloads the update, swaps the application atomically, and relaunches it.

## Release maturity and update channels

- **Release** is the default update channel. It reads only intentional, versioned GitHub Releases created by the manual release workflow.
- **Edge** is opt-in under Developer update settings. Every successful commit on `main` replaces the assets on the single `edge` prerelease.

Every versioned release below `1.0.0` is a Public Beta milestone and is titled accordingly. These remain normal GitHub releases—not GitHub prereleases—so Sparkle's default latest-release feed can deliver them. Cadence becomes Stable at `1.0.0`.

Edge does not create a permanent release per commit. Its bundle build number uses the commit timestamp so Sparkle can order builds, while Release builds from newer commits can supersede older Edge builds.

## Versioning rules

- Use `X.Y.Z` semantic versions for `CFBundleShortVersionString`.
- Use `0.Y.Z` for Public Beta milestones and begin Stable releases at `1.0.0`.
- The release scripts derive a monotonically increasing numeric `CFBundleVersion`.
- Never reuse a published version or replace a published archive with different bytes.
- Keep the public key stable. Losing the private key prevents existing installations from accepting future updates.
