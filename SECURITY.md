# Security

Switchboard handles subscription login credentials. Treat its local account files, Keychain snapshots, and isolated CLI profiles as sensitive.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/quasa0/switchboard/security/advisories/new). Do not post working tokens, cookies, account stores, or private account details in a public issue. If private reporting is unavailable, open an issue that asks for a private contact route without disclosing the vulnerability.

Include the affected version, a synthetic reproduction, impact, and relevant environment settings with values redacted. Reports about authentication, account mix-ups, unsafe storage, and unintended credential disclosure are especially useful.

## Security model

Saved snapshots use macOS Keychain. Metadata uses owner-only files. Codex and isolated CLI profiles can also hold token-bearing `auth.json` files. Optional Claude billing sessions use separate persistent WebKit stores. An explicit Desktop sign-in import reads only its first-party session cookie, decrypts in memory through Keychain, and verifies the account in an ephemeral store before persistence. Automatic polling never imports Desktop or browser profiles. The app does not provide a credential server or send telemetry.

Switchboard changes authentication for new CLI sessions. It cannot stop another running client from refreshing a login it already holds. Close the provider’s sessions before switching. Review [architecture and compatibility](docs/architecture.md) for current constraints.

The current downloadable build is ad hoc signed and **not notarized**. Checksums detect corruption or mismatched artifacts; they do not provide independent publisher authentication. Install only from the repository’s releases or build from reviewed source. Do not disable Gatekeeper globally or remove quarantine attributes as an installation shortcut.

Starting with 0.6.0, native updates require both a signed feed and a signed archive matching the Ed25519 public key pinned in the app. Archives are verified before extraction. This protects updates after the initial installation; it does not authenticate an untrusted initial download. The updater sends no account metadata or system profile. Public ad hoc builds retain hardened runtime with a library-validation exception for the embedded framework. Development-signed builds keep library validation.

Only the latest release receives fixes. Provider CLI internals can change independently of Switchboard. There is no guaranteed response time or support contract.
