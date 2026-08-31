# Security Policy

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private security advisory feature for this repository so the report can be reviewed before details are disclosed.

Include the affected Cadence version, macOS version, reproduction steps, and potential impact. Do not include real dictated content, recordings, credentials, or other personal data in the report.

## Update security

Cadence uses Sparkle 2 over HTTPS. Both the appcast feed and application archives must have valid Ed25519 signatures before an update is accepted. The signing private key is kept outside the repository.
