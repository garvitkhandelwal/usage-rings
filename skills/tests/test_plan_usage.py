"""Tests for skills/plan-usage/scripts/usage.py.

Run from the repo root:  python3 -I -m unittest discover -s skills/tests

Uses the Swift app's redacted fixtures so both implementations parse the
same real responses. Never touches the network, the Keychain, or real
credential files: every reader and the transport are injected.
"""
from __future__ import annotations

import base64
import datetime as dt
import importlib.util
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "skills" / "plan-usage" / "scripts" / "usage.py"
FIXTURES = REPO / "Tests" / "UsageRingsCoreTests" / "Fixtures"

spec = importlib.util.spec_from_file_location("plan_usage", SCRIPT)
usage = importlib.util.module_from_spec(spec)
sys.modules["plan_usage"] = usage  # dataclasses on Python 3.9 look the module up here
spec.loader.exec_module(usage)

NOW = dt.datetime(2026, 10, 1, 12, 0, tzinfo=dt.timezone.utc)
SECRET = "SECRET-TOKEN-do-not-leak-0123456789"


def fixture(name: str) -> bytes:
    return (FIXTURES / name).read_bytes()


def fake_jwt(sub: str, token_tail: str = SECRET) -> str:
    def seg(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).rstrip(b"=").decode()
    return f"{seg({'alg': 'HS256'})}.{seg({'sub': sub})}.{token_tail}"


class RecordingTransport:
    """Stands in for the network. Records every call; replays canned replies."""

    def __init__(self, replies):
        self.replies = replies  # url -> (status, body, retry_after)
        self.calls = []

    def __call__(self, url, headers):
        self.calls.append((url, dict(headers)))
        reply = self.replies[url]
        if isinstance(reply, Exception):
            raise reply
        return reply


def claude_creds(expires_in_s=3600, token=SECRET, plan="max"):
    return {
        "token": token,
        "expires_at": NOW + dt.timedelta(seconds=expires_in_s),
        "plan": plan,
    }


def run_report(readers, transport, only=None):
    out = io.StringIO()
    with redirect_stdout(out):
        code = usage.main(
            [] if only is None else ["--only", only],
            readers=readers,
            transport=transport,
            now=lambda: NOW,
        )
    return code, out.getvalue()


ALL_OK = {
    usage.ENDPOINTS["claude"]: (200, fixture("claude-usage.json"), None),
    usage.ENDPOINTS["codex"]: (200, fixture("codex-usage.json"), None),
    usage.ENDPOINTS["cursor"]: (200, fixture("cursor-usage.json"), None),
}


def all_readers():
    return {
        "claude": lambda: claude_creds(),
        "codex": lambda: {"token": SECRET, "account_id": "acct_REDACTED"},
        "cursor": lambda: {"token": fake_jwt("auth0|user_ABC123")},
    }


# --------------------------------------------------------------------------
# Parsing (same fixtures as the Swift app)
# --------------------------------------------------------------------------

class ParsingTests(unittest.TestCase):
    def test_claude_fixture_yields_5h_and_weekly(self):
        u = usage.parse_claude(json.loads(fixture("claude-usage.json")), plan="max")
        self.assertEqual([w.label for w in u.windows], ["5-hour", "Weekly"])
        for w in u.windows:
            self.assertIsInstance(w.percent, float)
            self.assertIsNotNone(w.resets_at)

    def test_claude_skips_null_windows_and_ignores_unknown_keys(self):
        u = usage.parse_claude(
            {"five_hour": None, "seven_day": {"utilization": 12, "resets_at": None}, "mystery": {}},
            plan=None,
        )
        self.assertEqual([(w.label, w.percent) for w in u.windows], [("Weekly", 12.0)])

    def test_codex_fixture_labels_from_window_length(self):
        u = usage.parse_codex(json.loads(fixture("codex-usage.json")))
        self.assertEqual(u.plan, "free")
        self.assertEqual([w.label for w in u.windows], ["Monthly"])  # 2592000 s; secondary is null

    def test_codex_window_labels(self):
        self.assertEqual(usage.window_label(18000), "5-hour")
        self.assertEqual(usage.window_label(604800), "Weekly")
        self.assertEqual(usage.window_label(2592000), "Monthly")
        self.assertEqual(usage.window_label(3 * 86400), "3-day")
        self.assertEqual(usage.window_label(None), "Window")

    def test_cursor_cents_are_rendered_as_dollars(self):
        u = usage.parse_cursor(json.loads(fixture("cursor-usage.json")))
        self.assertEqual(u.plan, "enterprise")
        monthly, on_demand = u.windows
        self.assertEqual((monthly.label, monthly.percent), ("Monthly", 100.0))
        self.assertEqual(on_demand.label, "On-demand")
        self.assertIsNone(on_demand.percent)
        self.assertEqual(on_demand.note, "$20.83 spent")

    def test_cursor_falls_back_to_total_percent_when_limit_zero(self):
        u = usage.parse_cursor({"individualUsage": {"plan": {"used": 5, "limit": 0, "totalPercentUsed": 37}}})
        self.assertEqual(u.windows[0].percent, 37.0)

    def test_changed_response_shape_is_a_clear_error(self):
        with self.assertRaises(usage.ProviderError) as ctx:
            usage.parse_cursor({"something": "else"})
        self.assertIn("changed", str(ctx.exception))


# --------------------------------------------------------------------------
# Security: tokens only go to their own provider, over HTTPS, no redirects
# --------------------------------------------------------------------------

class TransportGuardTests(unittest.TestCase):
    def test_each_token_goes_only_to_its_own_host(self):
        t = RecordingTransport(ALL_OK)
        run_report(all_readers(), t)
        hosts = {u.split("/")[2] for u, _ in t.calls}
        self.assertEqual(hosts, {"api.anthropic.com", "chatgpt.com", "cursor.com"})
        for url, headers in t.calls:
            self.assertTrue(url.startswith("https://"))
            provider = usage.provider_for_url(url)
            self.assertEqual(url, usage.ENDPOINTS[provider])

    def test_send_refuses_mismatched_host(self):
        t = RecordingTransport({})
        with self.assertRaises(usage.ProviderError):
            usage.send("claude", "https://chatgpt.com/backend-api/wham/usage", {}, t)
        with self.assertRaises(usage.ProviderError):
            usage.send("claude", "http://api.anthropic.com/api/oauth/usage", {}, t)
        with self.assertRaises(usage.ProviderError):
            usage.send("claude", "https://api.anthropic.com.evil.example/x", {}, t)
        self.assertEqual(t.calls, [])

    def test_redirects_are_refused_not_followed(self):
        handler = usage.RefuseRedirects()
        with self.assertRaises(usage.RedirectRefused):
            handler.redirect_request(None, None, 302, "Found", {}, "https://evil.example/")

    def test_real_transport_follows_no_redirects(self):
        # A local server that redirects: the transport must raise, never follow.
        import http.server
        import threading

        hits = []

        class Redirector(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                hits.append(self.path)
                self.send_response(302)
                self.send_header("Location", "/stolen")
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Redirector)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            opener = usage.urllib.request.build_opener(usage.RefuseRedirects())
            with self.assertRaises(usage.RedirectRefused):
                opener.open(f"http://127.0.0.1:{server.server_port}/start", timeout=5)
        finally:
            server.shutdown()
        self.assertEqual(hits, ["/start"])

    def test_tls_verification_is_on(self):
        ctx = usage.tls_context()
        self.assertTrue(ctx.check_hostname)
        self.assertEqual(ctx.verify_mode, usage.ssl.CERT_REQUIRED)


# --------------------------------------------------------------------------
# Security: tokens and personal data never reach the output
# --------------------------------------------------------------------------

class NoLeakTests(unittest.TestCase):
    def test_happy_path_output_has_no_token_or_pii(self):
        _, out = run_report(all_readers(), RecordingTransport(ALL_OK))
        self.assertIn("Claude Code", out)
        self.assertIn("Codex", out)
        self.assertIn("Cursor", out)
        for forbidden in (SECRET, "acct_REDACTED", "user@example.com", "user-REDACTED", "user_ABC123"):
            self.assertNotIn(forbidden, out)

    def test_error_paths_never_echo_exception_text_or_bodies(self):
        leaky = {
            usage.ENDPOINTS["claude"]: RuntimeError(f"boom {SECRET}"),
            usage.ENDPOINTS["codex"]: (500, f"server error for {SECRET}".encode(), None),
            usage.ENDPOINTS["cursor"]: (200, b"not json " + SECRET.encode(), None),
        }
        _, out = run_report(all_readers(), RecordingTransport(leaky))
        self.assertNotIn(SECRET, out)
        self.assertNotIn("boom", out)

    def test_reader_crash_is_reported_without_details(self):
        def bad():
            raise ValueError(f"parse failed near {SECRET}")
        readers = all_readers() | {"claude": bad}
        _, out = run_report(readers, RecordingTransport(ALL_OK))
        self.assertNotIn(SECRET, out)
        self.assertIn("Claude Code", out)

    def test_final_scrub_redacts_any_registered_secret(self):
        usage.register_secret(SECRET)
        self.assertEqual(usage.scrub(f"x{SECRET}y"), "x[redacted]y")


# --------------------------------------------------------------------------
# Behaviour that avoids side effects
# --------------------------------------------------------------------------

class BehaviourTests(unittest.TestCase):
    def test_expired_claude_token_makes_no_network_call(self):
        t = RecordingTransport(ALL_OK)
        readers = all_readers() | {"claude": lambda: claude_creds(expires_in_s=-60)}
        _, out = run_report(readers, t, only="claude")
        self.assertEqual(t.calls, [])
        self.assertIn("Run `claude`", out)

    def test_claude_sends_claude_code_user_agent(self):
        t = RecordingTransport(ALL_OK)
        run_report(all_readers(), t, only="claude")
        (_, headers), = t.calls
        self.assertTrue(headers["User-Agent"].startswith("claude-code/"))
        self.assertEqual(headers["anthropic-beta"], "oauth-2025-04-20")

    def test_401_says_how_to_refresh(self):
        t = RecordingTransport({usage.ENDPOINTS["codex"]: (401, b"", None)})
        _, out = run_report(all_readers(), t, only="codex")
        self.assertIn("Run `codex`", out)

    def test_429_reports_retry_time(self):
        t = RecordingTransport({usage.ENDPOINTS["cursor"]: (429, b"", 600)})
        _, out = run_report(all_readers(), t, only="cursor")
        self.assertIn("rate limited", out.lower())
        self.assertIn("10m", out)

    def test_not_signed_in_providers_are_listed_not_errors(self):
        def missing():
            raise usage.NotSignedIn()
        readers = all_readers() | {"codex": missing}
        _, out = run_report(readers, RecordingTransport(ALL_OK))
        self.assertIn("Not signed in: Codex", out)

    def test_explain_reads_nothing_and_sends_nothing(self):
        def forbidden():
            raise AssertionError("reader called during --explain")
        readers = {k: forbidden for k in ("claude", "codex", "cursor")}
        t = RecordingTransport({})
        out = io.StringIO()
        with redirect_stdout(out):
            code = usage.main(["--explain"], readers=readers, transport=t, now=lambda: NOW)
        self.assertEqual(code, 0)
        self.assertEqual(t.calls, [])
        for host in ("api.anthropic.com", "chatgpt.com", "cursor.com"):
            self.assertIn(host, out.getvalue())


# --------------------------------------------------------------------------
# Credential readers (against temp files, never the real ones)
# --------------------------------------------------------------------------

class ReaderTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())

    def test_codex_reader_honours_codex_home(self):
        (self.tmp / "auth.json").write_text(json.dumps({"tokens": {"access_token": "a", "account_id": "b"}}))
        creds = usage.read_codex_credentials(env={"CODEX_HOME": str(self.tmp)}, home=Path("/nonexistent"))
        self.assertEqual(creds, {"token": "a", "account_id": "b"})

    def test_codex_api_key_mode_is_not_signed_in(self):
        (self.tmp / "auth.json").write_text(json.dumps({"OPENAI_API_KEY": "sk-x", "tokens": None}))
        with self.assertRaises(usage.NotSignedIn):
            usage.read_codex_credentials(env={"CODEX_HOME": str(self.tmp)}, home=Path("/nonexistent"))

    def test_cursor_reader_opens_read_only_and_rejects_bad_user_id(self):
        db = self.tmp / "state.vscdb"
        con = sqlite3.connect(db)
        con.execute("CREATE TABLE ItemTable (key TEXT, value TEXT)")
        con.execute("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", (fake_jwt("auth0|bad;id"),))
        con.commit()
        con.close()
        before = db.stat().st_mtime_ns
        with self.assertRaises(usage.ProviderError):
            usage.read_cursor_credentials(path=db)
        self.assertEqual(db.stat().st_mtime_ns, before)

    def test_cursor_user_id_is_segment_after_last_pipe(self):
        self.assertEqual(usage.cursor_user_id(fake_jwt("auth0|user_ABC123")), "user_ABC123")
        self.assertIsNone(usage.cursor_user_id("not-a-jwt"))

    def test_claude_file_reader_parses_credentials(self):
        (self.tmp / ".credentials.json").write_text(json.dumps({
            "claudeAiOauth": {"accessToken": "t", "expiresAt": 1_900_000_000_000, "subscriptionType": "pro"}
        }))
        creds = usage.read_claude_credentials(
            env={"CLAUDE_CONFIG_DIR": str(self.tmp)}, system="Linux", home=Path("/nonexistent")
        )
        self.assertEqual(creds["token"], "t")
        self.assertEqual(creds["plan"], "pro")

    def test_keychain_command_carries_no_secret_in_argv(self):
        seen = []

        class Done:
            returncode = 44
            stdout = b""

        def fake_run(argv, **kwargs):
            seen.append(argv)
            return Done()

        with self.assertRaises(usage.NotSignedIn):
            usage.read_claude_credentials(env={}, system="Darwin", home=self.tmp, run=fake_run)
        self.assertEqual(seen, [["/usr/bin/security", "find-generic-password", "-s", "Claude Code-credentials", "-w"]])


if __name__ == "__main__":
    unittest.main()
