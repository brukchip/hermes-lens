"""`hermes lens`: set the plugin up in one command, and try it without glasses.

    hermes lens setup        create the access token, check the Gemini key and model, check that the
                             gateway serves the plugin, and print what to type into the iPhone app
    hermes lens try "..."    send one request through the running plugin, the way the app does,
                             and show the answer (and any approval card) in the terminal

`setup` writes only HERMES_LENS_TOKEN (and GEMINI_API_KEY if you type one) to the profile's .env.
It reads `tailscale status` / `tailscale serve status` if Tailscale is installed, and makes one
read-only request to Google to check the key and model. It never prints the Gemini key.
"""
from __future__ import annotations

import getpass
import ipaddress
import json
import secrets
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
from typing import Callable, Optional

from . import grant

MODELS_API = "https://generativelanguage.googleapis.com/v1beta/models/"
DEFAULT_HTTPS_PORT = 8443
TOKEN_BYTES = 32

Http = Callable[..., tuple]  # (method, url, headers, body, timeout) -> (status, dict | None)


# ----- small helpers ------------------------------------------------------------------------------

def _env(name: str, default: str = "") -> str:
    from hermes_cli.config import get_env_value
    value = get_env_value(name)
    return default if value in (None, "") else str(value)


def _save(name: str, value: str) -> None:
    from hermes_cli.config import save_env_value
    save_env_value(name, value)


def http(method: str, url: str, headers: Optional[dict] = None, body: Optional[dict] = None,
         timeout: float = 15.0) -> tuple:
    """One request; returns (status, parsed JSON or None). Network errors are status 0."""
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers=dict(headers or {}))
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:  # noqa: S310 (fixed hosts)
            raw = response.read(256 * 1024)
            status = response.status
    except urllib.error.HTTPError as error:
        raw, status = error.read(64 * 1024), error.code
    except (urllib.error.URLError, OSError, TimeoutError):
        return 0, None
    try:
        return status, json.loads(raw) if raw else None
    except ValueError:
        return status, None


def _local_base(port: int, host: str) -> str:
    if host in ("", "0.0.0.0", "::"):
        host = "127.0.0.1"
    try:
        if ipaddress.ip_address(host).version == 6:
            host = f"[{host}]"
    except ValueError:
        pass
    return f"http://{host}:{port}"


def _headers(token: str, device_id: str) -> dict:
    return {"Authorization": f"Bearer {token}", "X-Hermes-Device-Id": device_id,
            "Idempotency-Key": str(uuid.uuid4())}


def _settings() -> dict:
    from .adapter import DEFAULT_HOST, DEFAULT_PORT
    try:
        port = int(_env("HERMES_LENS_PORT", str(DEFAULT_PORT)))
    except ValueError:
        port = DEFAULT_PORT
    return {"host": _env("HERMES_LENS_HOST", DEFAULT_HOST), "port": port,
            "model": _env("HERMES_LENS_MODEL", "gemini-3.8-live")}


# ----- checks -------------------------------------------------------------------------------------

def check_gemini(key: str, model: str, request: Http = http) -> tuple[bool, str]:
    """Read-only: does this key see the Live model? The key goes in a header, never the URL."""
    status, _ = request("GET", MODELS_API + model, {"x-goog-api-key": key}, None, 15.0)
    if status == 200:
        return True, f"Gemini key works and {model} is available"
    if status in (400, 401, 403):
        return False, "Gemini rejected the key: check GEMINI_API_KEY"
    if status == 404:
        return False, f"{model} is not available to this key: set HERMES_LENS_MODEL to a Live model it can use"
    if status == 0:
        return False, "Could not reach Google to check the key (offline?)"
    return False, f"Google answered {status} when checking the key"


def check_plugin(base: str, token: str, request: Http = http) -> tuple[Optional[bool], str]:
    """Is the gateway serving this plugin with this token? None means 'not running yet'."""
    status, _ = request("GET", base + "/health", _headers(token, str(uuid.uuid4())), None, 5.0)
    if status == 200:
        return True, f"The gateway serves the plugin at {base}"
    if status == 401:
        return False, "The gateway is running with a different token: run `hermes gateway restart`"
    if status == 0:
        return None, f"Nothing answers at {base} yet: run `hermes gateway restart`"
    return False, f"{base}/health answered {status}"


def tailscale_address(port: int, https_port: int, run=subprocess.run) -> tuple[Optional[str], Optional[bool]]:
    """(https address on the tailnet, whether `tailscale serve` already points at the plugin).
    Read-only: never changes what Tailscale serves."""
    if not shutil.which("tailscale"):
        return None, None
    try:
        status = json.loads(run(["tailscale", "status", "--json"], capture_output=True, text=True,
                                timeout=10).stdout or "{}")
        dns = str(((status.get("Self") or {}).get("DNSName") or "")).rstrip(".")
    except (OSError, ValueError, subprocess.SubprocessError):
        return None, None
    if not dns:
        return None, None
    address = f"https://{dns}:{https_port}" if https_port != 443 else f"https://{dns}"
    try:
        serve = run(["tailscale", "serve", "status", "--json"], capture_output=True, text=True,
                    timeout=10).stdout or ""
        served = f"127.0.0.1:{port}" in serve or f"localhost:{port}" in serve
    except (OSError, subprocess.SubprocessError):
        served = None
    return address, served


# ----- hermes lens setup --------------------------------------------------------------------------

def setup(args, *, request: Http = http, run=subprocess.run, ask=getpass.getpass,
          interactive: Optional[bool] = None, out=print) -> int:
    settings = _settings()
    interactive = sys.stdin.isatty() if interactive is None else interactive
    problems = 0

    token = _env("HERMES_LENS_TOKEN")
    if getattr(args, "rotate_token", False) or len(token) < 24:
        token = secrets.token_hex(TOKEN_BYTES)
        _save("HERMES_LENS_TOKEN", token)
        new_token = True
        out("✓ Created a new access token (HERMES_LENS_TOKEN)")
    else:
        new_token = False
        out("✓ Access token is set (HERMES_LENS_TOKEN)")

    key = _env("GEMINI_API_KEY")
    if not key and interactive:
        key = (ask("Gemini API key (https://aistudio.google.com/apikey, input hidden): ") or "").strip()
        if key:
            _save("GEMINI_API_KEY", key)
    if not key:
        problems += 1
        out("✗ GEMINI_API_KEY is not set: hermes config set GEMINI_API_KEY \"<your key>\"")
    elif getattr(args, "no_check", False):
        out("• Skipped the Gemini check")
    else:
        ok, message = check_gemini(key, settings["model"], request)
        problems += not ok
        out(("✓ " if ok else "✗ ") + message)

    base = _local_base(settings["port"], settings["host"])
    running, message = check_plugin(base, token, request)
    if new_token and running is not False:
        running, message = None, "Restart the gateway so it uses the new token: hermes gateway restart"
    out({True: "✓ ", False: "✗ ", None: "• "}[running] + message)
    problems += running is False

    https_port = int(getattr(args, "https_port", DEFAULT_HTTPS_PORT) or DEFAULT_HTTPS_PORT)
    address, served = tailscale_address(settings["port"], https_port, run)
    serve_cmd = f"tailscale serve --bg --https={https_port} http://127.0.0.1:{settings['port']}"
    if address and served:
        out(f"✓ Tailscale serves the plugin at {address}")
    elif address:
        out(f"• Publish it on your tailnet (tailnet only, not the internet): {serve_cmd}")
    else:
        out("• The phone needs HTTPS to reach the plugin, for example with Tailscale: " + serve_cmd)

    out("")
    out("In the Luna app (You › Hermes server):")
    out(f"  Server address  {address or 'https://<your-machine>.<tailnet>.ts.net:' + str(https_port)}")
    if new_token or getattr(args, "show_token", False):
        out(f"  Access token    {token}")
        out("  Keep the token secret: anyone holding it can talk to your agent.")
    else:
        out("  Access token    (unchanged; run `hermes lens setup --show-token` to print it)")
    out("")
    out("Then try it without glasses: hermes lens try \"What can you do for me?\"")
    return 1 if problems else 0


# ----- hermes lens try ----------------------------------------------------------------------------

def try_request(args, *, request: Http = http, confirm=input, interactive: Optional[bool] = None,
                out=print) -> int:
    """One request through the running plugin, exactly as the app sends it: start a call (this
    mints a real single-use Gemini grant, which is never printed), ask, show the answer or the
    approval card, end the call. The terminal stands in for the phone's tap."""
    settings = _settings()
    token = _env("HERMES_LENS_TOKEN")
    if len(token) < 24:
        out("✗ No access token yet: run `hermes lens setup` first")
        return 1
    text = " ".join(getattr(args, "request", None) or []).strip()
    if not text:
        out("✗ Say what to ask, for example: hermes lens try \"What's on my calendar today?\"")
        return 1
    interactive = sys.stdin.isatty() if interactive is None else interactive
    base = (getattr(args, "server", None) or _local_base(settings["port"], settings["host"])).rstrip("/")
    device = str(uuid.uuid4())

    status, body = request("POST", base + "/v1/lens/realtime/calls", _headers(token, device),
                           {"protocol": grant.PROTOCOL}, 20.0)
    if status != 200 or not isinstance(body, dict) or "callID" not in body:
        out("✗ Could not start a call: " + _explain(status, body))
        return 1
    call_id = str(body["callID"])
    out("✓ Call started (a single-use Gemini grant was minted; it is not shown)")
    try:
        out(f"You: {text}")
        status, body = request("POST", base + "/v1/lens/native/tools", _headers(token, device),
                               {"callID": call_id, "id": f"try-{uuid.uuid4().hex[:12]}",
                                "name": "ask_luna", "args": {"request": text}}, 90.0)
        if status != 200 or not isinstance(body, dict):
            out("✗ The request failed: " + _explain(status, body))
            return 1
        approval = body.get("approval")
        if isinstance(approval, dict):
            out("")
            out("Approval card")
            out(f"  {approval.get('summary', '')}")
            if approval.get("detail"):
                out(f"  Action: {approval['detail']}")
            if approval.get("risky"):
                out("  Hermes flagged this as risky")
            answer = confirm("Approve? [y/N] ") if interactive else ""
            choice = "approve" if str(answer).strip().lower() in ("y", "yes") else "decline"
            status, body = request("POST", base + "/v1/lens/native/approvals", _headers(token, device),
                                   {"callID": call_id, "approvalID": approval.get("id"),
                                    "choice": choice}, 90.0)
            if status != 200 or not isinstance(body, dict):
                out("✗ The tap was not accepted: " + _explain(status, body))
                return 1
        reply = body.get("response") or {}
        if "error" in reply:
            out(f"Luna: {reply['error']}")
            return 1
        out(f"Luna: {reply.get('result', '')}")
        return 0
    finally:
        request("DELETE", base + f"/v1/lens/realtime/calls/{call_id}", _headers(token, device), None, 10.0)


def _explain(status: int, body) -> str:
    code = ((body or {}).get("error") or {}).get("code") if isinstance(body, dict) else None
    if status == 0:
        return "nothing answers; is the gateway running? (hermes gateway restart)"
    if status == 401:
        return "the token does not match the gateway's; run `hermes gateway restart`"
    if status == 429 and code:
        return f"{code} (rate or daily limit)"
    return f"HTTP {status}" + (f" ({code})" if code else "")


# ----- registration -------------------------------------------------------------------------------

def _setup_parser(parser) -> None:
    sub = parser.add_subparsers(dest="lens_command")
    p = sub.add_parser("setup", help="Create the token, check the key and gateway, print the app settings")
    p.add_argument("--rotate-token", action="store_true", help="Replace the access token (locks out every phone)")
    p.add_argument("--show-token", action="store_true", help="Print the current access token")
    p.add_argument("--https-port", type=int, default=DEFAULT_HTTPS_PORT, help="Tailnet HTTPS port (default 8443)")
    p.add_argument("--no-check", action="store_true", help="Skip the request to Google")
    t = sub.add_parser("try", help="Ask your agent through the plugin, without glasses")
    t.add_argument("request", nargs="+", help="What to ask")
    t.add_argument("--server", help="Plugin address (default: this machine)")


def _main(args) -> int:
    command = getattr(args, "lens_command", None)
    if command == "setup":
        return setup(args)
    if command == "try":
        return try_request(args)
    print("Usage: hermes lens setup | hermes lens try \"<request>\"")
    return 1


def register(ctx) -> None:
    if hasattr(ctx, "register_cli_command"):
        ctx.register_cli_command("lens", help="Set up Hermes Lens and try it without glasses",
                                 setup_fn=_setup_parser, handler_fn=_main,
                                 description=__doc__.split("\n\n")[0])
