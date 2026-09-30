# Release procedure

## Build locally on macOS

1. Update `scripts/version.sh`, `CHANGELOG.md`, and versioned links in `README.md`, `site/index.html`, and `site/install.md`.
2. Run `swift test` and `node scripts/test-billing-reader.mjs`.
3. Set `SWITCHBOARD_UPDATE_SIGNING_KEY` to the owner-only private seed matching `config/update-public-key.txt` (defaults to `~/.config/switchboard/update-signing-key`). Run `./scripts/package-release.sh`. This builds both Mac architectures, signs ad hoc, verifies nested signatures, runs the credential-free UI smoke, and packages DMG and ZIP files. It verifies the archive's Ed25519 signature and prepares `site/appcast.xml`. It does not install or publish.
4. Inspect `dist/releases/<version>/`. `release-manifest.py` generates checksums and copies `release.json` into `site/` from the actual artifact bytes. The manifest truthfully marks these releases as not notarized. Do not use this script for notarized releases until its signing, stapling, and manifest handling are updated together.
5. Extract the ZIP to a temporary directory. Verify the extracted app and run `scripts/ui-smoke.sh` against it. Mount the DMG read-only, check its app and Applications link, then detach it. Check both architectures' minimum OS, bundle metadata, and absence of private paths or development certificates.

Never publish a personal Apple Development certificate in a public package. Developer ID signing and notarization are separate distribution work; do not label an ad hoc build as notarized. Intel is cross-built; record separately whether an Intel Mac was used for runtime verification.

Sparkle and its signing tools are pinned to 2.10.0; the tool download is SHA-256 verified. Ad hoc builds disable library validation because they have no Team ID for an embedded framework. Development-signed builds keep library validation. Both the feed and archives require signatures matching the public key pinned in the installed app; invalid feed signatures never expire into acceptance. Keep the private seed outside the checkout and back it up securely. Do not replace the public key in a shipped feed without a tested key-rotation migration. Follow [Sparkle's signing documentation](https://sparkle-project.org/documentation/#signing-feeds-optional).

Before the first updater release, run `SWITCHBOARD_SPARKLE_TOOLS=$(bash scripts/sparkle-tools.sh) python3 scripts/test-updater.py`. This checks the current-version response, malformed feed, unsigned feed, unsupported macOS version, bad archive signature, ordinary quit without installation, and confirmed replacement/relaunch through real Sparkle helpers. Each fixture has an ephemeral key, distinct bundle ID, loopback feed, and credential-free demo model. It stops the HTTP server and fixture apps on completion.

## Publish

After authorization, commit the source and public assets. Tag that exact commit `v<version>`. Create a GitHub release with the DMG, ZIP, `SHA256SUMS.txt`, `release.json`, and `appcast.xml`. Publish the archives before deploying the feed that advertises them. Do not overwrite assets for an existing release: publish a new version when bytes change. Builds before 0.6.0 require one manual install to gain the updater.

Verify the remote release metadata, download both artifacts, and compare their hashes with the manifest. At least one extracted release download must pass the UI smoke on a Mac. Keep credentials and local artifacts outside Git.

The Mac deployment script also runs `scripts/test-published-updater.py`. It fetches the exact deployed signed feed and mirrors its unchanged bytes over loopback to a demo fixture with the shipped public key and an older build number. Sparkle downloads the actual GitHub archive and verifies that it becomes ready. The fixture cancels installation and cleans up its helpers/preferences/cache. It never constructs account engines or accesses credentials.

## Website

`site/` is a standalone static Vercel project. Deploy **only that directory**. It contains no auth, backend API, analytics, or package dependencies. Never deploy the repository root or local `artifacts/`.

Run `python3 scripts/check-site.py` before deployment. Link the directory to the intended Vercel project, then run `./scripts/deploy-site.sh`. That script deploys, checks the new deployment's canonical alias, and automatically runs `scripts/smoke-site.py` against the public domain. Generated deployment URLs can require Vercel login; their protection stays enabled. Configure `switchboard.quasa0.com` as a production domain before using it.

The smoke fetches the page, CSS, JavaScript, font, screenshot, agent docs, manifest, and every published download. It verifies nonempty assets and SHA-256 checksums. There is no authenticated site API or realtime connection to test. Also inspect desktop/mobile and light/dark browser views, copy-prompt behavior, navigation, and downloads. A health response alone is not a successful release.

Keep deployment credentials out of Git. `.vercel/` is ignored. The website's Geist font uses SIL OFL; keep `site/fonts/OFL.txt` published.
