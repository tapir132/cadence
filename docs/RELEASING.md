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

Run the **Release Cadence** workflow with the new semantic version. The workflow creates a GitHub Release containing:

- `Cadence-X.Y.Z.zip`
- `appcast.xml`

Installed copies read the appcast from the latest GitHub Release. Sparkle verifies the signed feed and archive, downloads the update, swaps the application atomically, and relaunches it.

## Versioning rules

- Use `X.Y.Z` semantic versions for `CFBundleShortVersionString`.
- The release scripts derive a monotonically increasing numeric `CFBundleVersion`.
- Never reuse a published version or replace a published archive with different bytes.
- Keep the public key stable. Losing the private key prevents existing installations from accepting future updates.
