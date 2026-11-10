"""`hermes lens setup` and `hermes lens try`, against fake HTTP, fake Tailscale and a fake .env."""
import json
from types import SimpleNamespace

import pytest

from hermes_lens import cli


class Env:
    def __init__(self, **values):
        self.values = dict(values)

    def get(self, name, default=""):
        return self.values.get(name, default) or default

    def save(self, name, value):
        self.values[name] = value


@pytest.fixture
def env(monkeypatch):
    store = Env()
    monkeypatch.setattr(cli, "_env", store.get)
    monkeypatch.setattr(cli, "_save", store.save)
    monkeypatch.setattr(cli, "_settings", lambda: {"host": "127.0.0.1", "port": 8795, "model": "gemini-x-live"})
    monkeypatch.setattr(cli.shutil, "which", lambda name: None)
    return store


def args(**kw):
    base = {"rotate_token": False, "show_token": False, "https_port": 8443, "no_check": False}
    base.update(kw)
    return SimpleNamespace(**base)


class Http:
    def __init__(self, routes):
        self.routes, self.calls = routes, []

    def __call__(self, method, url, headers=None, body=None, timeout=0):
        self.calls.append((method, url, dict(headers or {}), body))
        for (m, suffix), reply in self.routes.items():
            if m == method and url.endswith(suffix):
                return reply(body) if callable(reply) else reply
        return 0, None


def test_setup_creates_a_token_checks_the_key_and_prints_what_to_type(env):
    env.values["GEMINI_API_KEY"] = "g-key"
    http = Http({("GET", "/models/gemini-x-live"): (200, {}), ("GET", "/health"): (0, None)})
    lines = []
    assert cli.setup(args(), request=http, interactive=False, out=lines.append) == 0
    token = env.values["HERMES_LENS_TOKEN"]
    assert len(token) == 64
    text = "\n".join(lines)
    assert "Created a new access token" in text and f"Access token    {token}" in text
    assert "gemini-x-live is available" in text and "hermes gateway restart" in text
    model_call = http.calls[0]
    assert model_call[2] == {"x-goog-api-key": "g-key"} and "g-key" not in model_call[1]  # header, never URL
    assert "g-key" not in text


def test_setup_keeps_a_good_token_and_hides_it(env):
    env.values.update(HERMES_LENS_TOKEN="k" * 40, GEMINI_API_KEY="g")
    http = Http({("GET", "/models/gemini-x-live"): (200, {}), ("GET", "/health"): (200, {"status": "ok"})})
    lines = []
    assert cli.setup(args(), request=http, interactive=False, out=lines.append) == 0
    assert env.values["HERMES_LENS_TOKEN"] == "k" * 40
    text = "\n".join(lines)
    assert "k" * 40 not in text and "--show-token" in text and "The gateway serves the plugin" in text
    health = [c for c in http.calls if c[1].endswith("/health")][0]
    assert health[2]["Authorization"] == "Bearer " + "k" * 40


def test_setup_reports_problems_with_a_nonzero_exit(env):
    env.values["HERMES_LENS_TOKEN"] = "k" * 40
    http = Http({("GET", "/health"): (401, None)})
    lines = []
    assert cli.setup(args(), request=http, interactive=False, out=lines.append) == 1
    text = "\n".join(lines)
    assert "GEMINI_API_KEY is not set" in text and "different token" in text


def test_a_rejected_key_or_missing_model_is_named(env):
    for status, words in ((403, "rejected the key"), (404, "is not available to this key")):
        ok, message = cli.check_gemini("g", "gemini-x-live", Http({("GET", "/models/gemini-x-live"): (status, None)}))
        assert ok is False and words in message


def test_a_typed_key_is_saved_and_never_echoed(env):
    http = Http({("GET", "/models/gemini-x-live"): (200, {})})
    lines = []
    cli.setup(args(), request=http, interactive=True, ask=lambda prompt: " typed-key ", out=lines.append)
    assert env.values["GEMINI_API_KEY"] == "typed-key" and "typed-key" not in "\n".join(lines)


def test_tailscale_is_only_read_never_changed(env, monkeypatch):
    monkeypatch.setattr(cli.shutil, "which", lambda name: "/usr/bin/tailscale")
    commands = []

    def run(cmd, **kw):
        commands.append(cmd)
        if cmd[:2] == ["tailscale", "status"]:
            return SimpleNamespace(stdout=json.dumps({"Self": {"DNSName": "box.tail1.ts.net."}}))
        return SimpleNamespace(stdout='{"Web":{"box:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8795"}}}}}')
    assert cli.tailscale_address(8795, 8443, run) == ("https://box.tail1.ts.net:8443", True)
    assert commands == [["tailscale", "status", "--json"], ["tailscale", "serve", "status", "--json"]]


def test_try_asks_through_the_plugin_and_ends_the_call(env):
    env.values["HERMES_LENS_TOKEN"] = "k" * 40
    http = Http({
        ("POST", "/v1/lens/realtime/calls"): (200, {"callID": "c1", "token": "secret-grant"}),
        ("POST", "/v1/lens/native/tools"): (200, {"response": {"result": "You have two meetings."}}),
        ("DELETE", "/v1/lens/realtime/calls/c1"): (204, None),
    })
    lines = []
    assert cli.try_request(SimpleNamespace(request=["what's", "on", "today"], server=None),
                           request=http, interactive=False, out=lines.append) == 0
    text = "\n".join(lines)
    assert "Luna: You have two meetings." in text and "secret-grant" not in text
    ask = http.calls[1]
    assert ask[3]["name"] == "ask_luna" and ask[3]["args"] == {"request": "what's on today"}
    assert http.calls[-1][0] == "DELETE"
    assert len({c[2]["X-Hermes-Device-Id"] for c in http.calls}) == 1


def test_try_shows_the_card_and_only_an_explicit_yes_approves(env):
    env.values["HERMES_LENS_TOKEN"] = "k" * 40
    card = {"id": "a1", "summary": "Start a background job (runs now)", "detail": "Start a background job: hi",
            "risky": False}
    for answer, expected in (("y", "approve"), ("", "decline"), ("sure", "decline")):
        http = Http({
            ("POST", "/v1/lens/realtime/calls"): (200, {"callID": "c1"}),
            ("POST", "/v1/lens/native/tools"): (200, {"response": {"result": "needs approval"}, "approval": card}),
            ("POST", "/v1/lens/native/approvals"): lambda body: (200, {"response": {"result": body["choice"]}}),
            ("DELETE", "/v1/lens/realtime/calls/c1"): (204, None),
        })
        lines = []
        cli.try_request(SimpleNamespace(request=["send", "me", "hello"], server=None), request=http,
                        confirm=lambda prompt: answer, interactive=True, out=lines.append)
        tap = [c for c in http.calls if c[1].endswith("/approvals")][0]
        assert tap[3] == {"callID": "c1", "approvalID": "a1", "choice": expected}
        assert "Action: Start a background job: hi" in "\n".join(lines)


def test_try_without_a_terminal_declines(env):
    env.values["HERMES_LENS_TOKEN"] = "k" * 40
    http = Http({
        ("POST", "/v1/lens/realtime/calls"): (200, {"callID": "c1"}),
        ("POST", "/v1/lens/native/tools"): (200, {"response": {}, "approval": {"id": "a1", "summary": "x"}}),
        ("POST", "/v1/lens/native/approvals"): lambda body: (200, {"response": {"result": body["choice"]}}),
    })
    cli.try_request(SimpleNamespace(request=["x"], server=None), request=http,
                    confirm=lambda prompt: "y", interactive=False, out=lambda line: None)
    assert [c[3]["choice"] for c in http.calls if c[1].endswith("/approvals")] == ["decline"]


def test_try_explains_a_gateway_that_is_not_running(env):
    env.values["HERMES_LENS_TOKEN"] = "k" * 40
    lines = []
    assert cli.try_request(SimpleNamespace(request=["x"], server=None), request=Http({}),
                           interactive=False, out=lines.append) == 1
    assert "is the gateway running" in "\n".join(lines)


def test_the_command_is_registered_when_hermes_supports_it():
    seen = []
    cli.register(SimpleNamespace(register_cli_command=lambda name, **kw: seen.append((name, kw["handler_fn"]))))
    assert seen == [("lens", cli._main)]
    cli.register(SimpleNamespace())  # older cores: nothing to do
