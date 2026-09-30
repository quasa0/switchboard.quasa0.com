# Contributing

Small, focused changes are easiest to review. For new provider support or changes to credential storage, open an issue that describes the behavior and constraints first. Never include tokens, cookies, login files, or screenshots with real account data.

## Project map

| Path | Owns |
| --- | --- |
| `Sources/Switchboard` | SwiftUI app, dashboard model, and provider coordination |
| `Sources/SwitchboardCore` | Account storage, switching, CLI protocols, and usage models |
| `Tests/SwitchboardCoreTests` | Synthetic protocol, cookie-decryption, persistence, and recovery tests |
| `scripts` | Build, packaging, and verification tools |
| `site` | Static landing page, agent instructions, and release manifest |
| `docs` | User guide, architecture, and release procedure |

## Local checks

Use macOS 14+, Swift 5.10+, Node 20+, and Python 3. Run `swift test`, `node scripts/test-billing-reader.mjs`, and `python3 scripts/check-site.py`. Changes to the native UI also need `SWITCHBOARD_SIGNING_IDENTITY=- ./scripts/build.sh` and `./scripts/ui-smoke.sh dist/Switchboard.app` in a logged-in macOS desktop session.

Never test account switching against someone’s actual login. Use injected stores and temporary fixture files. Keep fixture addresses under reserved `.example` or `.test` domains. UI preview flags construct synthetic models before account engines can start.

Updater changes also need `SWITCHBOARD_SPARKLE_TOOLS=$(bash scripts/sparkle-tools.sh) python3 scripts/test-updater.py`. It exercises signed installation and relaunch on isolated demo bundles through a loopback feed, without real account credentials.

Use SwiftUI for UI changes. Preserve native keyboard behavior and accessibility labels. Keep absent, stale, failed, and zero usage distinct. Do not infer billing dates from quota resets or token expiry. A successful switch must preserve unrelated settings and recover from interrupted writes.

## Site

The website is plain HTML, CSS, and JavaScript. It needs no package install or build step. Run `python3 -m http.server 4173 --bind 127.0.0.1 --directory site` in the foreground, then open `http://127.0.0.1:4173`. Stop the server with Ctrl-C when finished.

Check desktop and mobile widths, light and dark appearances, keyboard focus, FAQ disclosure, copy success/failure, and reduced motion. Screenshots must come from `--demo` or the UI smoke fixtures. Preserve the Geist license beside the font.

## Pull requests

Describe the problem, changed behavior, and verification. Include a sample-account screenshot for visible changes. Avoid broad reformatting or unrelated cleanup. Credentials and account data must stay outside Git. Local operational notes belong in the ignored `worklog.md`; they are not publication artifacts.
