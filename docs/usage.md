# Using Switchboard

Switchboard checks for app updates after startup and every four minutes. When one is available, click **Update** in the footer to download it. Click **Restart to update**, then confirm **Update and restart**. The archive signature is verified before installation. Restart waits until account operations finish and keeps saved accounts on this Mac. Closing the app without confirmation does not install the prepared update. Use **Switchboard → Check for Updates…** to check manually. Versions before 0.6.0 need one manual install to gain this updater.

## Use it

1. Open **Switchboard** from `~/Applications`.
2. Compare the **Claude** and **ChatGPT** sections. Each marks its active account.
3. Click **Add account**, choose a provider, then **Save current login** to save that CLI's current subscription login. Give it a name such as Personal. If no login is available, choose **Sign in to Claude Code** or **Sign in to Codex**.
4. To add another account, click **Add account → Sign in another account**. Complete the official browser sign-in, return to Switchboard, and click **Save new login**.
5. Quit open sessions for that provider. Click the saved account you want, then restart Claude Code or Codex. The other provider’s selected account stays unchanged.

For Claude, if your browser returns a login code, expand **Browser gave you a code?** and paste it. Codex returns through its local browser callback; it has no code-paste field in Switchboard. Finish or cancel any other Codex sign-in before starting one here.

Browser sessions can automatically choose the account already signed in. Check the saved email before switching. macOS can ask for Keychain access when Switchboard saves or reads an account.

Account tiers include their reported multiplier: Claude Pro · 1× or Max · 5×/20×; ChatGPT uses the provider’s reported plan name. Codex’s `prolite` identifier appears as Pro Lite. Switchboard does not infer a current Codex allowance multiplier from a plan ID or an older saved label. Unknown plans keep their name. Claude multipliers are provider-specific.

ChatGPT subscription periods are read automatically from the saved Codex ID token during the normal account refresh. **Period ends** is the provider-reported boundary; the token does not confirm that the plan will renew. The original observation time stays in the tooltip. An elapsed period is not rolled forward and does not mean that the CLI login expired.

Claude reset grants refresh through each saved Claude Code login automatically. The request identifies the installed CLI version and Switchboard. All unexpired, unused grants show their count and expiry. Paused grants and future start dates remain visible with their conditions. Claude Code can report an ineligible surface with an empty grant list even when Claude's website offers a reset; this shows **Not confirmed**, not zero. Connect billing to read the website's account-specific grants in that case. A surface-restricted response cannot replace a confirmed web inventory. Use **… → Manual reset details** for all grants and their conditions. Missing grants stay unavailable. A failed read preserves saved grants and marks them stale. Switchboard never applies a reset.

Billing dates use a separate web connection. Choose **… → Connect billing**, sign into the embedded Claude page, then click **Read details**. Google sign-in opens a separate popup. Use **Retry sign-in** if a page fails. If Claude Desktop is installed and signed in, **Use Claude Desktop sign-in** can connect its existing first-party session. macOS can request access to Claude Desktop's encryption key. Switchboard verifies the saved account and organization in a temporary session before connecting; a different Desktop account is rejected. This action reads only the Claude session cookie and does not alter Desktop's sign-in. Later refreshes use the account's isolated WebKit session. Gift subscriptions show **Gift covers through**; date-only coverage never gets an invented time. Failed or expired web sessions preserve the last date and show a billing warning.

**… → Set renewal date** remains an optional manual override. Clearing it restores the automatic date. Billing dates are never inferred from token expiry, subscription creation, or quota resets. Editing an override or account name changes display metadata without reading credentials.

You can also sign in manually with `claude auth login --claudeai`, then save that current login. **Save each account before signing into the next. Do not run `claude auth logout` between them:** current Claude Code revokes refresh tokens on logout. For additional ChatGPT accounts, use Switchboard’s isolated sign-in so Codex does not replace or revoke the existing local login. Removing an account from Switchboard deletes its saved copy and leaves the active CLI login intact.

Usage refreshes automatically every five minutes while Switchboard runs. A refresh skips a tick during a sign-in, switch, or another refresh. Quitting the app stops the timer and its CLI children. The next check appears in the wide header. Reset countdowns update locally once a minute.

**Use / Stay on**, or **Most % left** when plans differ, identifies the fresh account with the largest remaining percentage in its tightest reported general window. Ties favor the earlier reset. Failed checks, data older than ten minutes, elapsed reset times, and incompatible window sets cannot support this comparison. This compares percentages, not task capacity across plans. Named model limits and usage credits remain separate; check the model you intend to use.

**Usage credits** shows the balances reported by Codex, separately from manual resets. Zero, no reported balance, and unlimited credits have distinct labels. Grant history and credit expiry are not exposed by this interface. Manual resets list every available reset and its reported expiry directly in the row. Account options also retain the full detail list.

Switchboard retains the primary Codex login, an account-specific usage profile, and up to three backup login copies in Keychain. The first save creates a redundant copy before any usage check. After an authentication failure, it tries distinct matching copies through its private profile. It does not restore or replace the desktop app’s selected login automatically. A desktop logout does not delete Switchboard’s vault, but provider revocation can invalidate all saved copies. In that case, sign in to that account again through Switchboard. To create a session independently of the desktop app, use **Add account → Sign in another account** and choose the same account. Saving the current desktop login only copies that existing session.

Claude shows **Weekly → Five-hour → Fable** in fixed columns. Fable starts hidden, leaving its cells empty. Enable **Show Fable usage** in the Claude header to reveal it; the checkbox is remembered. Hiding Fable preserves column widths and alignment with Codex. This does not change usage collection or limits. Click an account row to switch. The active account has a highlighted surface and left edge; its state remains available to assistive technology. During switching, blocked controls keep their normal appearance but cannot be clicked. Only the destination row shows switching progress in a fixed slot.

## Usage errors
- **Claude credential files:** Switchboard supports both Keychain and an existing `.credentials.json` fallback. Keep the file intact. If Keychain is locked, unlock it before refreshing; Switchboard still saves account snapshots there.
- **Codex HTTP 401:** Switchboard tries one token refresh across account discovery and usage, then tries saved login copies. If all copies fail, use **Add account → Sign in another account → Save new login** for that account. Avoid `/logout` in the shared CLI when repairing another saved account.
- **Codex workspace check failures:** Network and timeout errors do not trigger backup retries or require logout. A workspace-discovery authentication rejection follows the HTTP 401 recovery path.
- **Codex HTTP 403:** Check that the selected workspace allows Codex. A forbidden response does not prove the login expired.
- **Codex HTTP 429 or 5xx:** Wait before refreshing. These are service errors, not quota percentages.
- **Codex RPC errors:** The message identifies the failed account method and error code. Update the CLI when requested. For a bug report, include the error and CLI versions (`claude --version`, `codex --version`), never credential files or tokens.
