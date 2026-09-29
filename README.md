# Usage Rings

A small native macOS menu bar app that shows your Claude Code, Codex, and
Cursor plan usage as concentric rings (Apple-Health style). Everything runs
locally on your Mac — there is no server, no cloud, no account to create.

The menu bar icon is a miniature of the ring stack; clicking it opens a
popover with one ring per connected provider:

- **Outer, lavender** — Claude Code. By default (configurable in Settings)
  shows the higher of the 5-hour and weekly windows; the other window is
  the row's secondary line.
- **Middle, teal** — Codex. By default (configurable in Settings) shows
  the higher of the primary and secondary windows; the other window is
  the row's secondary line.
- **Inner, amber** — Cursor. Included plan usage for the billing cycle;
  on-demand spend is shown as a secondary line when enabled on your plan.

The menu bar icon uses the same ring colours; a small dot beside the rings
turns amber when any ring reaches 80 % and red at 95 %. Every row shows the
time until reset, and clicking a row opens that provider's usage page in your
default browser. Refresh happens every 5 minutes by default (configurable
1–5 min), plus on wake, on popover open (if data is older than 60 seconds),
and when you click the Refresh button or the centre of the ring stack.

## Requirements

- macOS 14 (Sonoma) or later
- An active internet connection — there is no offline mode; without a
  connection each ring goes empty and the row reads "No internet connection"
  rather than showing stale data
- One or more of: Claude Code CLI signed in, Codex CLI signed in with a plan
  (API-key-only Codex installs have no plan limits and are hidden), Cursor
  editor signed in. A provider you do not use is hidden automatically.

## Download

Get the latest `UsageRings-<version>.dmg` from the
[Releases page](https://github.com/garvitkhandelwal/usage-rings/releases/latest),
open it, and drag **UsageRings** into **Applications**. Then follow the
one-time Gatekeeper step below.

## Install from the dmg (unsigned)

The dmg itself is **unsigned**. The `UsageRings.app` inside it is ad-hoc
signed (`codesign -s -`) — it is not notarised, has no Developer ID, and
is not on the App Store. Gatekeeper will refuse to open it on the first
attempt. Choose one of the following, in order of what still works on
recent macOS releases:

- **System Settings → Privacy & Security → Open Anyway** (works on all
  supported macOS releases): mount the dmg, drag `UsageRings.app` to
  `/Applications`, double-click it — you will see a "cannot be opened"
  dialog — then open System Settings → Privacy & Security, scroll to the
  security section, and click **Open Anyway** next to the Usage Rings
  entry. Confirm in the follow-up dialog.
- **Strip the quarantine attribute** (fastest for a re-install; works on
  all supported macOS releases):
  ```sh
  xattr -dr com.apple.quarantine /Applications/UsageRings.app
  ```
- **Right-click → Open** — macOS 14 only. Since macOS 15 the
  right-click-Open shortcut no longer bypasses Gatekeeper for unnotarised
  apps; on macOS 14 you can still right-click (or Control-click) the app
  in Finder and choose **Open**, then confirm the dialog. On newer
  macOS releases, use one of the two options above instead.

After launch, the app has no Dock icon (`LSUIElement = YES`) and no menu bar
window until you click its icon.

## Build from source

You need Xcode 26 or a Swift 6 toolchain and macOS 14+.

```sh
git clone https://github.com/garvitkhandelwal/usage-rings.git
cd usage-rings
scripts/build-app.sh          # produces dist/UsageRings.app (universal, ad-hoc signed)
open dist/UsageRings.app
```

`scripts/make-dmg.sh` builds the app and packages it into
`dist/UsageRings-<version>.dmg` for handing to someone else.

`swift build` and `swift test` also work directly. Tests use bundled JSON
fixtures — no real network, no real Keychain, no real Cursor DB is touched
by the test suite.

## Privacy

- The three provider tokens are read directly from the sources the vendor
  tools already use:
  - Claude Code — Keychain item `Claude Code-credentials`, read via
    `/usr/bin/security find-generic-password`.
  - Codex — `~/.codex/auth.json`, read-only.
  - Cursor — `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`,
    opened SQLite read-only (`SQLITE_OPEN_READONLY` plus `mode=ro` URI).
- Tokens are never written to disk, never logged, never included in any
  error message, and never sent anywhere but the vendor's own endpoint they
  came from. Each token is held in memory only for the duration of one
  request.
- The app never refreshes, rotates, or rewrites any vendor token. When a
  Codex or Cursor token has expired the app shows the signed-out row and
  asks you to reopen the tool that owns it — the tool refreshes its own
  token next time it runs.
- Claude Code delegated renewal (default on, one setting to turn off).
  Claude Code's Keychain token is only renewed when the `claude` CLI runs.
  Working in the Claude desktop app never renews it, so the Claude ring
  would otherwise get stuck on "Open Claude Code to refresh" for users
  who never open a terminal. To keep the ring working, on a 401 from
  Claude's usage endpoint the app runs the user's own `claude` CLI once
  in the background so the CLI renews its own Keychain token; it then
  re-reads the Keychain and retries the usage call once.
  - The exact command (no shell): `<claude> -p "Reply with OK" --model
    haiku --no-session-persistence --tools "" --strict-mcp-config`.
  - Working directory: a fresh temporary directory deleted after each
    attempt. Environment: only `HOME`, `USER`, `LOGNAME`, `PATH`
    (`/usr/bin:/bin:/usr/sbin:/sbin` plus the directory containing
    `claude`), and `LANG` — nothing else, in particular no
    `CLAUDE_*` / `ANTHROPIC_*` variables from your shell profile.
  - The `claude` binary is located from the first existing candidate of:
    `~/.local/bin/claude`, `~/.claude/local/claude`,
    `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`. If none exists,
    no renewal is attempted.
  - At most one attempt per 30 minutes (cooldown applies to both
    successes and failures) and at most one attempt in flight.
  - Uses a tiny amount of your Claude usage (the one short prompt above)
    per renewal.
  - `--no-session-persistence` means no session log is saved for this
    prompt. The CLI's own output is discarded — the app never writes it
    to disk or logs it anywhere.
  - The app itself never writes the Keychain; only the CLI does.
  - To turn it off: Settings → Claude Code → "Renew Claude login
    automatically". With the toggle off the Claude ring falls back to
    the signed-out row ("Open Claude Code to refresh") whenever the
    token expires.
- Network traffic is limited to HTTPS calls to:
  - `api.anthropic.com`
  - `chatgpt.com`
  - `cursor.com`
- The only local storage is preferences (which providers are enabled, which
  ring window, refresh interval, icon style) in `UserDefaults`. No history,
  no logs, no usage cache, no analytics.
- Launch at login is handled by `SMAppService.mainApp` — a system service —
  and is not stored by this app.

## Tested setup

- Apple Silicon Mac (M-series), macOS 26.
- The author's own Claude Code, Codex, and Cursor accounts.

Other configurations (Intel Mac, older macOS 14.x releases, other plan
tiers) are expected to work — the app is a universal binary and the parsers
are tolerant — but have not been exercised by the author.

## Unofficial endpoints — use at your own risk

None of the three provider endpoints are publicly documented. This app calls
them the way each vendor's own client currently does. A vendor changing a
field name, moving the endpoint, or introducing a new authentication step
will make the corresponding ring turn into an error state until the app is
updated. If that happens, the other two rings continue to work; the app
never crashes because of a broken endpoint.

There is no automatic update mechanism, no Sparkle feed, and no telemetry
that would tell the author when something breaks. Report an issue upstream
or rebuild from source with a fix.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Garvit Khandelwal.
