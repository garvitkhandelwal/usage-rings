#!/usr/bin/env python3
"""Show how much of your Claude Code, Codex and Cursor plan usage is used.

Part of the plan-usage skill (https://github.com/garvitkhandelwal/usage-rings).
Python standard library only. Run with --explain to see exactly what it reads
and where it sends it, without reading or sending anything.

Security model
--------------
* Each tool's stored sign-in is read locally and read-only. It is never
  refreshed, written, copied, logged, or passed in a command-line argument.
* A token is sent to exactly one hard-coded HTTPS URL owned by the provider
  that issued it. The host is pinned twice (URL table + host table), TLS
  certificates are verified, and redirects are refused rather than followed.
* Output contains only usage numbers, plan names and reset times. Errors are
  fixed sentences; exception text and response bodies are never printed.
  As a last line of defence, every token is scrubbed from the output.
* No telemetry, no other network calls, no third-party packages.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import platform
import re
import sqlite3
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

PROVIDERS = ("claude", "codex", "cursor")
NAMES = {"claude": "Claude Code", "codex": "Codex", "cursor": "Cursor"}

# The only places a token is ever sent. Pinned twice on purpose: send()
# refuses a request unless the URL matches ENDPOINTS *and* its host matches
# EXPECTED_HOST for the provider whose token it carries.
ENDPOINTS = {
    "claude": "https://api.anthropic.com/api/oauth/usage",
    "codex": "https://chatgpt.com/backend-api/wham/usage",
    "cursor": "https://cursor.com/api/usage-summary",
}
EXPECTED_HOST = {
    "claude": "api.anthropic.com",
    "codex": "chatgpt.com",
    "cursor": "cursor.com",
}

# Claude's endpoint answers 429 instead of the real status without a
# claude-code User-Agent (observed 2026-09-29).
CLAUDE_USER_AGENT = "claude-code/2.1.0"
TIMEOUT_SECONDS = 10
MAX_BODY_BYTES = 1_000_000

REFRESH_HINT = {
    "claude": "Sign-in expired. Run `claude` in a terminal to refresh it, then ask again.",
    "codex": "Sign-in expired. Run `codex` in a terminal to refresh it, then ask again.",
    "cursor": "Sign-in expired. Open Cursor to refresh it, then ask again.",
}


class ProviderError(Exception):
    """A fixed, user-facing sentence. Never built from tokens or response bodies."""


class NotSignedIn(Exception):
    """The tool isn't installed or isn't signed in; listed, not treated as an error."""


class RedirectRefused(ProviderError):
    pass


@dataclass
class Window:
    label: str
    percent: float | None
    resets_at: dt.datetime | None = None
    note: str | None = None


@dataclass
class Usage:
    plan: str | None
    windows: list = field(default_factory=list)


# --------------------------------------------------------------------------
# Output scrubbing
# --------------------------------------------------------------------------

_SECRETS: set = set()


def register_secret(value) -> None:
    if isinstance(value, str) and len(value) >= 8:
        _SECRETS.add(value)


def scrub(text: str) -> str:
    for secret in sorted(_SECRETS, key=len, reverse=True):
        text = text.replace(secret, "[redacted]")
    return text


# --------------------------------------------------------------------------
# Network
# --------------------------------------------------------------------------

class RefuseRedirects(urllib.request.HTTPRedirectHandler):
    """A redirect could carry the Authorization header somewhere else. Refuse."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RedirectRefused("The usage service tried to redirect the request; refused for safety.")


def tls_context() -> ssl.SSLContext:
    return ssl.create_default_context()  # verifies certificates and hostnames


def _retry_after(value) -> int | None:
    try:
        return max(0, int(str(value).strip()))
    except (TypeError, ValueError):
        return None


def https_transport(url: str, headers: dict):
    """GET url. Returns (status, body, retry_after_seconds)."""
    opener = urllib.request.build_opener(
        urllib.request.HTTPSHandler(context=tls_context()), RefuseRedirects()
    )
    request = urllib.request.Request(url, headers=headers, method="GET")
    host = urllib.parse.urlsplit(url).hostname
    try:
        with opener.open(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, response.read(MAX_BODY_BYTES), None
    except urllib.error.HTTPError as error:
        body = error.read(MAX_BODY_BYTES) if error.fp else b""
        return error.code, body, _retry_after(error.headers.get("Retry-After"))
    except urllib.error.URLError as error:
        if isinstance(error.reason, ssl.SSLCertVerificationError):
            raise ProviderError(
                f"Couldn't verify {host}'s HTTPS certificate. If Python came from the "
                "python.org installer, run its 'Install Certificates.command' once."
            ) from None
        raise ProviderError(f"Couldn't reach {host}. Check your internet connection.") from None
    except (TimeoutError, OSError):
        raise ProviderError(f"{host} didn't answer in time. Try again in a moment.") from None


def provider_for_url(url: str) -> str | None:
    for provider, endpoint in ENDPOINTS.items():
        if endpoint == url:
            return provider
    return None


def send(provider: str, url: str, headers: dict, transport):
    """The single choke point every credentialed request goes through."""
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError:
        parts, port = None, -1
    if (
        parts is None
        or url != ENDPOINTS[provider]
        or parts.scheme != "https"
        or parts.hostname != EXPECTED_HOST[provider]
        or port not in (None, 443)
        or parts.username
        or parts.password
    ):
        raise ProviderError("Refused to send credentials to an unexpected address.")
    return transport(url, headers)


def check_status(provider: str, status: int, retry_after) -> None:
    if 200 <= status < 300:
        return
    if status in (401, 403):
        raise ProviderError(REFRESH_HINT[provider])
    if status == 429:
        wait = f" Try again in {fmt_duration(retry_after)}." if retry_after else " Try again later."
        raise ProviderError("Rate limited by the usage service." + wait)
    raise ProviderError(f"{NAMES[provider]}'s usage service returned HTTP {status}. Try again later.")


# --------------------------------------------------------------------------
# Parsing helpers
# --------------------------------------------------------------------------

def changed(provider: str) -> ProviderError:
    return ProviderError(
        f"{NAMES[provider]}'s usage response has changed shape, so this skill may need an update."
    )


def num(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


def parse_iso(value) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)


def load_json(provider: str, body: bytes):
    try:
        return json.loads(body)
    except (ValueError, UnicodeDecodeError):
        raise changed(provider) from None


def window_label(seconds) -> str:
    seconds = num(seconds)
    if seconds is None or seconds <= 0:
        return "Window"
    s = int(round(seconds))
    known = {18_000: "5-hour", 604_800: "Weekly", 2_592_000: "Monthly"}
    if s in known:
        return known[s]
    if s % 86_400 == 0:
        return f"{s // 86_400}-day"
    if s % 3_600 == 0:
        return f"{s // 3_600}-hour"
    return f"{max(1, round(s / 60))}-minute"


# --------------------------------------------------------------------------
# Claude Code
# --------------------------------------------------------------------------

def read_claude_credentials(env=None, system=None, home=None, run=subprocess.run) -> dict:
    env = os.environ if env is None else env
    system = system or platform.system()
    home = home or Path.home()
    raw = None
    if system == "Darwin":
        # The service name is the only argument; the secret comes back on a pipe.
        argv = ["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]
        try:
            result = run(argv, capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            raise ProviderError("Couldn't read Claude Code's sign-in from the macOS Keychain.") from None
        if result.returncode == 0:
            raw = result.stdout
        elif result.returncode != 44:  # 44 = item not found
            raise ProviderError(
                "Couldn't read Claude Code's sign-in from the macOS Keychain "
                "(it may be locked, or access was denied)."
            )
    if raw is None:
        config_dir = Path(env.get("CLAUDE_CONFIG_DIR") or home / ".claude")
        try:
            raw = (config_dir / ".credentials.json").read_bytes()
        except FileNotFoundError:
            raise NotSignedIn() from None
        except OSError:
            raise ProviderError("Couldn't read Claude Code's stored sign-in file.") from None
    try:
        data = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        raise ProviderError("Claude Code's stored sign-in couldn't be parsed.") from None
    oauth = data.get("claudeAiOauth") if isinstance(data, dict) else None
    if not isinstance(oauth, dict):
        raise NotSignedIn()
    token = oauth.get("accessToken") if isinstance(oauth.get("accessToken"), str) else ""
    register_secret(token)
    expires_ms = num(oauth.get("expiresAt"))
    expires_at = (
        dt.datetime.fromtimestamp(expires_ms / 1000, tz=dt.timezone.utc) if expires_ms else None
    )
    plan = oauth.get("subscriptionType")
    return {"token": token, "expires_at": expires_at, "plan": plan if isinstance(plan, str) else None}


def parse_claude(root, plan=None) -> Usage:
    if not isinstance(root, dict):
        raise changed("claude")
    usage = Usage(plan=plan)
    for key, label in (("five_hour", "5-hour"), ("seven_day", "Weekly")):
        window = root.get(key)
        if window is None:
            continue
        if not isinstance(window, dict):
            raise changed("claude")
        percent = num(window.get("utilization"))
        if percent is None:
            raise changed("claude")
        usage.windows.append(Window(label, percent, parse_iso(window.get("resets_at"))))
    return usage


def fetch_claude(creds: dict, transport, now: dt.datetime) -> Usage:
    expires_at = creds.get("expires_at")
    # An expired token gets a ~1 hour 429 from the endpoint, so don't call it.
    # Refreshing is left to the user: this script never writes credentials.
    if not creds.get("token") or (expires_at is not None and expires_at <= now):
        raise ProviderError(REFRESH_HINT["claude"])
    headers = {
        "Authorization": f"Bearer {creds['token']}",
        "anthropic-beta": "oauth-2025-04-20",
        "User-Agent": CLAUDE_USER_AGENT,
        "Accept": "application/json",
    }
    status, body, retry_after = send("claude", ENDPOINTS["claude"], headers, transport)
    check_status("claude", status, retry_after)
    return parse_claude(load_json("claude", body), plan=creds.get("plan"))


# --------------------------------------------------------------------------
# Codex
# --------------------------------------------------------------------------

def read_codex_credentials(env=None, home=None) -> dict:
    env = os.environ if env is None else env
    home = home or Path.home()
    codex_home = env.get("CODEX_HOME")
    path = Path(codex_home) / "auth.json" if codex_home else home / ".codex" / "auth.json"
    try:
        data = json.loads(path.read_bytes())
    except FileNotFoundError:
        raise NotSignedIn() from None
    except (OSError, ValueError, UnicodeDecodeError):
        raise ProviderError("Couldn't read Codex's stored sign-in (auth.json).") from None
    tokens = data.get("tokens") if isinstance(data, dict) else None
    if tokens is None:
        raise NotSignedIn()  # API-key mode: no plan limits to show
    token = tokens.get("access_token") if isinstance(tokens, dict) else None
    account = tokens.get("account_id") if isinstance(tokens, dict) else None
    if not (isinstance(token, str) and token and isinstance(account, str) and account):
        raise ProviderError("Codex's stored sign-in is incomplete. Run `codex login`, then ask again.")
    register_secret(token)
    register_secret(account)
    return {"token": token, "account_id": account}


def parse_codex(root) -> Usage:
    if not isinstance(root, dict) or not isinstance(root.get("rate_limit"), dict):
        raise changed("codex")
    plan = root.get("plan_type")
    usage = Usage(plan=plan if isinstance(plan, str) else None)
    for key in ("primary_window", "secondary_window"):
        window = root["rate_limit"].get(key)
        if window is None:
            continue
        if not isinstance(window, dict):
            raise changed("codex")
        percent = num(window.get("used_percent"))
        if percent is None:
            raise changed("codex")
        reset_at = num(window.get("reset_at"))
        resets = dt.datetime.fromtimestamp(reset_at, tz=dt.timezone.utc) if reset_at else None
        usage.windows.append(Window(window_label(window.get("limit_window_seconds")), percent, resets))
    return usage


def fetch_codex(creds: dict, transport, now: dt.datetime) -> Usage:
    headers = {
        "Authorization": f"Bearer {creds['token']}",
        "ChatGPT-Account-Id": creds["account_id"],
        "Accept": "application/json",
    }
    status, body, retry_after = send("codex", ENDPOINTS["codex"], headers, transport)
    check_status("codex", status, retry_after)
    return parse_codex(load_json("codex", body))


# --------------------------------------------------------------------------
# Cursor
# --------------------------------------------------------------------------

def cursor_db_path(system=None, env=None, home=None) -> Path:
    system = system or platform.system()
    env = os.environ if env is None else env
    home = home or Path.home()
    if system == "Darwin":
        base = home / "Library" / "Application Support"
    elif system == "Windows":
        base = Path(env.get("APPDATA") or home / "AppData" / "Roaming")
    else:
        base = Path(env.get("XDG_CONFIG_HOME") or home / ".config")
    return base / "Cursor" / "User" / "globalStorage" / "state.vscdb"


def cursor_user_id(token: str) -> str | None:
    """The user id Cursor expects in its cookie: the JWT `sub` after its last '|'."""
    parts = token.split(".")
    if len(parts) < 2:
        return None
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except (ValueError, UnicodeDecodeError):
        return None
    sub = claims.get("sub") if isinstance(claims, dict) else None
    if not isinstance(sub, str) or not sub:
        return None
    user_id = sub.rsplit("|", 1)[-1]
    return user_id if re.fullmatch(r"[A-Za-z0-9._-]+", user_id) else None


def read_cursor_credentials(path=None) -> dict:
    path = Path(path) if path else cursor_db_path()
    if not path.exists():
        raise NotSignedIn()
    uri = "file:" + urllib.parse.quote(str(path)) + "?mode=ro"  # read-only
    try:
        connection = sqlite3.connect(uri, uri=True, timeout=0.5)
        try:
            row = connection.execute(
                "SELECT value FROM ItemTable WHERE key = ?", ("cursorAuth/accessToken",)
            ).fetchone()
        finally:
            connection.close()
    except sqlite3.Error:
        raise ProviderError("Couldn't read Cursor's stored sign-in.") from None
    token = row[0].strip() if row and isinstance(row[0], str) else ""
    if not token:
        raise NotSignedIn()
    register_secret(token)
    if cursor_user_id(token) is None:
        raise ProviderError("Cursor's stored sign-in has an unexpected format. Sign in to Cursor again.")
    return {"token": token}


def parse_cursor(root) -> Usage:
    if not isinstance(root, dict):
        raise changed("cursor")
    individual = root.get("individualUsage")
    plan_usage = individual.get("plan") if isinstance(individual, dict) else None
    if not isinstance(plan_usage, dict):
        raise changed("cursor")
    used, limit = num(plan_usage.get("used")), num(plan_usage.get("limit"))
    if used is not None and limit:
        percent = used / limit * 100
    else:
        percent = num(plan_usage.get("totalPercentUsed"))
        if percent is None:
            raise changed("cursor")
    plan = root.get("membershipType")
    usage = Usage(plan=plan if isinstance(plan, str) else None)
    usage.windows.append(Window("Monthly", percent, parse_iso(root.get("billingCycleEnd"))))
    on_demand = individual.get("onDemand")
    if isinstance(on_demand, dict) and on_demand.get("enabled") is True:
        spent = (num(on_demand.get("used")) or 0) / 100  # Cursor reports US cents
        cap = num(on_demand.get("limit"))
        note = f"${spent:.2f} of ${cap / 100:.2f} spent" if cap else f"${spent:.2f} spent"
        usage.windows.append(Window("On-demand", None, note=note))
    return usage


def fetch_cursor(creds: dict, transport, now: dt.datetime) -> Usage:
    user_id = cursor_user_id(creds["token"])
    if user_id is None:
        raise ProviderError("Cursor's stored sign-in has an unexpected format. Sign in to Cursor again.")
    headers = {
        "Cookie": f"WorkosCursorSessionToken={user_id}%3A%3A{creds['token']}",
        "Accept": "application/json",
    }
    status, body, retry_after = send("cursor", ENDPOINTS["cursor"], headers, transport)
    check_status("cursor", status, retry_after)
    return parse_cursor(load_json("cursor", body))


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

READERS = {
    "claude": read_claude_credentials,
    "codex": read_codex_credentials,
    "cursor": read_cursor_credentials,
}
FETCHERS = {"claude": fetch_claude, "codex": fetch_codex, "cursor": fetch_cursor}

EXPLAIN = """\
What this script does (nothing has been read or sent):

  Claude Code  reads  macOS Keychain item "Claude Code-credentials"
                      (Linux/Windows: ~/.claude/.credentials.json, or $CLAUDE_CONFIG_DIR)
               sends  that token only to https://api.anthropic.com/api/oauth/usage
  Codex        reads  ~/.codex/auth.json (or $CODEX_HOME/auth.json)
               sends  that token only to https://chatgpt.com/backend-api/wham/usage
  Cursor       reads  Cursor's state.vscdb, opened read-only
               sends  that token only to https://cursor.com/api/usage-summary

It never prints, saves, refreshes or passes tokens on a command line.
HTTPS certificates are verified and redirects are refused.
Output is limited to usage percentages, plan names and reset times.
"""


def fmt_duration(seconds) -> str:
    seconds = max(0, int(seconds))
    days, rest = divmod(seconds, 86_400)
    hours, rest = divmod(rest, 3_600)
    minutes = max(1, rest // 60) if not (days or hours) else rest // 60
    if days:
        return f"{days}d {hours}h"
    if hours:
        return f"{hours}h {minutes}m"
    return f"{minutes}m"


def fmt_percent(percent: float) -> str:
    if 0 < percent < 1:
        return "<1%"
    return f"{round(percent)}%"


def render(provider: str, outcome, now: dt.datetime) -> list:
    if isinstance(outcome, ProviderError):
        return [NAMES[provider], f"  Couldn't check: {outcome}"]
    title = NAMES[provider] + (f" · {outcome.plan.replace('_', ' ').title()}" if outcome.plan else "")
    lines = [title]
    if not outcome.windows:
        lines.append("  No usage limits reported for this plan.")
    for window in outcome.windows:
        if window.percent is None:
            lines.append(f"  {window.label:<10} {window.note or ''}".rstrip())
            continue
        line = f"  {window.label:<10} {fmt_percent(window.percent):>4} used"
        if window.resets_at:
            remaining = (window.resets_at - now).total_seconds()
            line += f" · resets in {fmt_duration(remaining)}" if remaining > 0 else " · resets now"
        lines.append(line)
    return lines


def main(argv=None, *, readers=None, transport=None, now=None) -> int:
    parser = argparse.ArgumentParser(description="Show Claude Code, Codex and Cursor plan usage.")
    parser.add_argument("--only", help="comma-separated subset: claude,codex,cursor")
    parser.add_argument("--explain", action="store_true", help="show what would be read and sent, then exit")
    args = parser.parse_args(argv)

    if args.explain:
        print(EXPLAIN, end="")
        return 0

    selected = list(PROVIDERS)
    if args.only:
        selected = [p.strip().lower() for p in args.only.split(",") if p.strip()]
        unknown = [p for p in selected if p not in PROVIDERS]
        if unknown:
            parser.error(f"unknown provider(s): {', '.join(unknown)}")

    readers = readers or READERS
    transport = transport or https_transport
    current = (now or (lambda: dt.datetime.now(dt.timezone.utc)))()

    blocks, not_signed_in = [], []
    for provider in selected:
        try:
            creds = readers[provider]()
            for key in ("token", "account_id"):
                register_secret(creds.get(key))
            outcome = FETCHERS[provider](creds, transport, current)
        except NotSignedIn:
            not_signed_in.append(NAMES[provider])
            continue
        except ProviderError as error:
            outcome = error
        except Exception:  # never surface exception text: it could carry data
            outcome = ProviderError(f"Unexpected error while checking {NAMES[provider]}.")
        blocks.append(render(provider, outcome, current))

    lines = []
    for block in blocks:
        lines.extend(block + [""])
    if not_signed_in:
        lines.append("Not signed in: " + ", ".join(not_signed_in))
    if not lines:
        lines.append("Nothing to show.")
    print(scrub("\n".join(lines).rstrip()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
