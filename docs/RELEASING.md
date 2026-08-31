# Releasing Cadence

This guide is for project maintainers. Users do not need these steps to receive updates.

## Update trust

Cadence's `Info.plist` contains only the public Ed25519 key. The matching private key must remain in a maintainer's login Keychain or the encrypted GitHub Actions secret `SPARKLE_PRIVATE_KEY`. Never add an exported key, `.env` file, certificate, or signing password to the repository.

The local Keychain account label is `app.cadence.updates`.

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

Nothing is uploaded automatically. Inspect the ignored `release/` directory before publishing.

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
- `appcast.xml`

Installed copies read the appcast from the latest GitHub Release. Sparkle verifies the signed feed and archive, downloads the update, swaps the application atomically, and relaunches it.

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
