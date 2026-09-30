# Changelog

## 0.6.1

- Identify the installed Claude Code version on reset reads. Keep surface eligibility separate from owned grants; an empty ineligible response does not establish zero or erase confirmed grants. Retain saved grants when the provider returns an in-band unavailable status.
- Show every unused, unexpired Claude reset grant with its expiry and use conditions.
- Remove the large Active badge and Remaining allowance header text. Preserve the active row highlight, accessibility state, and layout during switching.

## 0.6.0

- Check for desktop updates after startup and every four minutes. Download on click, verify the archive signature, and confirm before installing and restarting. Match T3 Code’s interaction with Sparkle’s native installer.
- Draw Show Fable usage with a neutral checkbox in light and dark modes.
- Show Claude Full and 5-hour manual reset grants through saved Claude Code OAuth. Keep failed reset reads separate from successful usage reads. Never apply a reset.
- Connect billing through an optional Claude Desktop sign-in. Verify account identity before importing its session. Preserve Google sign-in popups and add retry/error feedback.
- List every available Codex reset expiry directly in the account row.

- Keep Fable's hidden cells empty in a fixed three-column grid. Align Claude/Codex weekly meters and preserve control appearance while switching, with interaction guards intact.
- Recover Codex workspace-discovery authentication failures during account/read; distinguish workspace network failures from expired logins and direct reconnection through isolated Switchboard sign-in.
- Order Claude columns weekly, five-hour, then optional Fable. Add a remembered Show Fable usage checkbox, hidden by default. Remove duplicate Switch actions and preserve the row layout during switching.
- Keep up to three historical Codex login copies in Keychain. Retry authentication failures with matching saved copies in private profiles. Preserve desktop logout/account changes and rotated tokens; revoked sessions can still require sign-in.
- Refresh usage automatically every five minutes without overlapping sign-in, switching, or refresh operations.
- Show Codex usage credits separately from manual resets. Use reported plan names without inferred allowance multipliers.
- Add fresh general-limit recommendations, readiness labels, larger percentages, a neutral palette, and all available reset expiries with full details in account options.

## 0.5.2

- Support existing Claude file credential stores, with Keychain precedence and the correct secure-storage directory. Stale fallback files no longer block Keychain logins.
- Preserve unrelated credentials, owner-only file permissions, rollback, and interrupted-switch recovery for file-based logins. Refuse detected concurrent login changes.
- Retry Codex usage once after an HTTP 401 through the CLI’s token refresh. Preserve rotated credentials on failed usage reads.
- Show sanitized Codex HTTP/RPC errors instead of suggesting every failure is an expired login.

## 0.5.1

First downloadable public release.

- Universal macOS app for Apple silicon and Intel, with DMG, ZIP, and SHA-256 checksums.
- Public landing page, agent installation guide, and machine-readable release metadata.
- Focused setup documentation, contributor guide, security policy, and automated checks.
- Explicit ad hoc signing now stays ad hoc instead of selecting a personal development certificate.

The account-switching and dashboard behavior is unchanged from 0.5.0. This release is not Apple-notarized.

## 0.5.0

- Automatic subscription period metadata from saved Codex ID-token claims.
- Optional per-account Claude billing connections, with account and organization verification.
- Distinct charge dates, period ends, and gift coverage; manual date overrides.

## Earlier source releases

- Combined Claude Code and Codex dashboard with separate active accounts.
- Saved login switching, rollback, and interrupted-switch recovery.
- Remaining quotas, tiers, reset countdowns, exact local dates, and Codex manual reset credits.
