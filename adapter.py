"""Hermes Lens: Ray-Ban Meta glasses as a Hermes channel.

The iPhone app holds the voice conversation with Gemini Live directly; this adapter
1. mints the locked, single-use Gemini Live grant for each call (`grant.py`),
2. turns the voice model's `ask_luna` calls into ordinary messages in this chat, so the
   user's own Hermes agent answers with its memory, tools and skills, and
3. renders Hermes's approval requests as an Approve / Decline card on the phone; only the
   user's tap resolves them.

Never log requests, answers, approval text, tokens or audio.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import json
import logging
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

from gateway.config import Platform
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent, MessageType

from . import grant, voice

logger = logging.getLogger("hermes_lens")

PLATFORM = "hermes_lens"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 8795
ASK_TIMEOUT_SECONDS = 60.0
STOPPING_GRACE_SECONDS = 20.0  # how long a new question waits for a stopped turn to wind down
STALE_TURN_SECONDS = 600.0  # a turn that never reported completion stops blocking after this
APPROVAL_TTL_SECONDS = 120.0
RATE_LIMIT = (30, 60.0)  # requests per window per device
GLOBAL_RATE_LIMIT = (120, 60.0)  # all devices together: the device id is self-asserted
ASK_REPLAY_SECONDS = 600.0  # a retried ask_luna (same call + tool call id) never runs twice
MAX_TURN_MESSAGES = 20
# Tools that need the user's tap when the request came through the glasses. Hermes's own
# approval rules still apply everywhere; this adds a tap for actions a voice request should
# never take on its own. Set HERMES_LENS_CONFIRM_TOOLS to change it, or "none" to turn it off.
DEFAULT_CONFIRM_TOOLS = "cronjob_manage,cronjob,send_message"  # job tool names differ across versions
READ_ONLY_ACTIONS = {"cronjob_manage": {"list"}, "cronjob": {"list"}}
VERIFIED_SECONDS = 15 * 60  # how long a phone's last authenticated request vouches for it
CONFIG_BUILD = 1


def _secret(name: str, default: str = "") -> str:
    """Credentials and settings come through Hermes's scoped secret path (per profile)."""
    from agent.secret_scope import get_secret
    return get_secret(name) or default


def _setting(config, env: str, key: str, default: Any) -> Any:
    extra = getattr(config, "extra", {}) or {}
    return _secret(env) or extra.get(key, default)


def _int(value: Any, default: int) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


@dataclass
class _Card:
    """One Hermes approval request waiting for the user's tap on their phone."""
    id: str
    chat_id: str
    device_id: str
    call_id: str
    session_key: str
    request_id: str
    event_id: str  # the ask whose Hermes turn is waiting on this approval
    summary: str   # spoken: Hermes's reason
    detail: str    # shown on the card: the (redacted) command itself
    risky: bool    # Hermes's own safety check flagged it
    created: float = field(default_factory=time.monotonic)


class HermesLensAdapter(BasePlatformAdapter):
    # Replies are spoken once: no streaming edits, no progress bubbles.
    SUPPORTS_MESSAGE_EDITING = False

    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform(PLATFORM))
        self.token = _secret("HERMES_LENS_TOKEN")
        self.gemini_key = _secret("GEMINI_API_KEY")
        self.host = str(_setting(config, "HERMES_LENS_HOST", "host", DEFAULT_HOST) or DEFAULT_HOST)
        self.port = _int(_setting(config, "HERMES_LENS_PORT", "port", DEFAULT_PORT), DEFAULT_PORT)
        self.model = str(_setting(config, "HERMES_LENS_MODEL", "model", "gemini-3.8-live"))
        self.voice_name = str(_setting(config, "HERMES_LENS_VOICE", "voice", "Kore"))
        self.assistant = str(_setting(config, "HERMES_LENS_ASSISTANT_NAME", "assistant_name", "Luna"))
        self.persona = voice.persona(
            self.assistant,
            str(_setting(config, "HERMES_LENS_USER_NAME", "user_name", "")),
            str(_setting(config, "HERMES_LENS_PERSONA_NOTES", "persona_notes", "")))
        self.daily_seconds = 60 * _int(_setting(config, "HERMES_LENS_DAILY_MINUTES", "daily_minutes", 60), 60)
        self._broker: Optional[grant.CallBroker] = None
        self._runner = None
        self._sweeper: Optional[asyncio.Task] = None
        self._waiters: Dict[str, tuple] = {}  # chat -> (event id it answers, future)
        self._current_event: Dict[str, str] = {}  # chat -> event id of the turn in flight
        # chat -> (event id, started, finished) for the Hermes turn still running in that chat.
        # A new message sent while a stopped turn winds down is folded into the dying turn and lost.
        self._lens_turns: Dict[str, tuple] = {}
        self._active_call: Dict[str, str] = {}
        self._chat_locks: Dict[str, asyncio.Lock] = {}
        self._cards: Dict[str, _Card] = {}
        self._hits: Dict[str, deque] = {}
        self._all_hits: deque = deque()
        self._verified: Dict[str, tuple] = {}  # device -> (last good request, token digest used)
        self._turn_messages: Dict[str, list] = {}  # chat -> non-interim sends this turn
        self._asks: Dict[tuple, tuple] = {}  # (call, tool call id) -> (time, response body or None)
        self._tasks: set = set()

    # ----- lifecycle -------------------------------------------------------------------------

    async def connect(self, *, is_reconnect: bool = False) -> bool:
        if not self.token or len(self.token) < 24:
            return self._fail("config_missing", "HERMES_LENS_TOKEN must be set (at least 24 characters)")
        if not self.gemini_key:
            return self._fail("config_missing", "GEMINI_API_KEY must be set for Gemini Live calls")
        try:
            grant.session_configuration(self.model, self.voice_name, self.persona)
        except grant.GrantError:
            return self._fail("config_invalid", "HERMES_LENS_MODEL or HERMES_LENS_VOICE is not supported")
        from aiohttp import web
        from plugins.plugin_storage import plugin_data_dir
        app = self.build_app(Path(plugin_data_dir("hermes-lens")))
        self._runner = web.AppRunner(app, access_log=None)
        await self._runner.setup()
        try:
            await web.TCPSite(self._runner, self.host, self.port).start()
        except OSError as exc:
            await self._runner.cleanup()
            self._runner = None
            return self._fail("bind_failed", f"Could not listen on {self.host}:{self.port}: {exc}", retryable=True)
        self._mark_connected()
        logger.info("Hermes Lens listening on %s:%s", self.host, self.port)
        if self.host not in ("127.0.0.1", "::1", "localhost"):
            logger.warning("Hermes Lens listens on %s without TLS: put it behind an HTTPS proxy and "
                           "keep the port off the public internet", self.host)
        return True

    def build_app(self, data_dir: Path, *, http_post=None):
        """The phone-facing HTTP app; `connect` serves it, tests drive it directly."""
        from aiohttp import web
        usage = grant.UsageStore(data_dir / "usage.sqlite3")
        self._broker = grant.CallBroker(usage, api_key=self.gemini_key, model=self.model,
                                        voice_name=self.voice_name, persona=self.persona,
                                        daily_seconds=self.daily_seconds, http_post=http_post)
        app = web.Application(client_max_size=voice.MAX_BODY_BYTES, middlewares=[self._guard])
        app.router.add_post("/v1/lens/realtime/calls", self._create_call)
        app.router.add_delete("/v1/lens/realtime/calls/{call_id}", self._end_call)
        app.router.add_post("/v1/lens/native/tools", self._ask)
        app.router.add_post("/v1/lens/native/approvals", self._approve)
        app.router.add_get("/v1/lens/config", self._config)
        app.router.add_get("/health", self._health)

        async def start_sweeper(_app):
            self._sweeper = asyncio.create_task(self._sweep())

        async def stop_sweeper(_app):
            if self._sweeper:
                self._sweeper.cancel()
        app.on_startup.append(start_sweeper)
        app.on_cleanup.append(stop_sweeper)
        return app

    async def disconnect(self) -> None:
        self._mark_disconnected()
        if self._sweeper:
            self._sweeper.cancel()
        for card in list(self._cards.values()):  # nobody can tap them any more
            with contextlib.suppress(Exception):
                self._resolve(card, "deny")
        self._cards.clear()
        if self._broker:
            with contextlib.suppress(Exception):
                self._broker.close()
        if self._runner:
            with contextlib.suppress(Exception):
                await self._runner.cleanup()
            self._runner = None

    def _fail(self, code: str, detail: str, *, retryable: bool = False) -> bool:
        self._set_fatal_error(code, detail, retryable=retryable)
        return False

    # ----- Hermes -> phone ------------------------------------------------------------------

    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[Dict[str, Any]] = None) -> SendResult:
        """Collect what Hermes says during a turn. Gateway notices (no home channel yet, a
        context-window advisory) can arrive unmarked before the answer, so the answer is the
        turn's last message, taken when the turn completes."""
        if not (metadata or {}).get("_interim_send") and (content or "").strip():
            messages = self._turn_messages.setdefault(chat_id, [])
            messages.append(content)
            del messages[:-MAX_TURN_MESSAGES]
        return SendResult(success=True, message_id=str(uuid.uuid4()))

    async def on_processing_complete(self, event, outcome) -> None:
        """Hermes finished a turn in a lens chat: hand its final message to the call that
        asked for it. A late finish of an older turn (stopped, timed out) answers nobody."""
        await super().on_processing_complete(event, outcome)
        chat_id = getattr(event.source, "chat_id", "")
        messages = self._turn_messages.pop(chat_id, [])
        self._drop_cards(chat_id, event_id=getattr(event, "message_id", None))
        running = self._lens_turns.get(chat_id)
        if running is not None and running[0] == getattr(event, "message_id", None):
            running[2].set()
            del self._lens_turns[chat_id]
        entry = self._waiters.get(chat_id)
        if entry is None or entry[0] != getattr(event, "message_id", None) or entry[1].done():
            return
        if messages:
            entry[1].set_result(("answer", messages[-1]))
        else:
            entry[1].set_result(("failed", "Your Hermes agent did not answer. Try again."))

    async def _send_exec_approval_prompt(self, prompt) -> SendResult:
        """Hermes wants to act: show Approve / Decline on the phone. Never approved here."""
        device_id = prompt.chat_id.removeprefix("lens-")
        request_id = getattr(prompt, "request_id", None) or _pending_request_id(prompt.session_key)
        command = " ".join(str(prompt.command or "").split())
        if command.startswith("<") and command.endswith("(plugin approval rule)"):
            # A tool held for the user's tap: the reason is the action (see `_describe`). The
            # headline is shortened for speech, so the card's detail shows it whole.
            command = str(prompt.description or "")
        card = _Card(id=str(uuid.uuid4()), chat_id=prompt.chat_id, device_id=device_id,
                     call_id=self._active_call.get(prompt.chat_id, ""), session_key=prompt.session_key,
                     request_id=request_id or "", event_id=self._current_event.get(prompt.chat_id, ""),
                     summary=voice.summary(prompt.description or command),
                     detail=voice.detail(command),
                     risky=bool(getattr(prompt, "smart_denied", False)))
        entry = self._waiters.get(prompt.chat_id)
        if not request_id or entry is None or entry[1].done():
            # Without its exact id a tap could resolve some other pending approval, and with no
            # live call nobody can tap it: deny rather than leave the agent waiting.
            if request_id:
                with contextlib.suppress(Exception):
                    self._resolve(card, "deny")
            return SendResult(success=False, error="No live call to show the approval on")
        self._cards[card.id] = card
        entry[1].set_result(("approval", card))
        return SendResult(success=True, message_id=card.id)

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"name": "Hermes Lens", "type": "dm"}

    # ----- phone -> Hermes ------------------------------------------------------------------

    async def _create_call(self, request):
        from aiohttp import web
        body = grant.validate_request(await request.read())
        request_id = request["idempotency_key"]
        if not request_id:
            raise grant.GrantError(400, "native_request_invalid")
        payload = await self._broker.create(request["device_id"], request_id, body)
        return web.json_response(payload, headers={"Cache-Control": "no-store"})

    async def _end_call(self, request):
        from aiohttp import web
        try:
            call_id = str(uuid.UUID(request.match_info["call_id"]))
        except ValueError:
            raise grant.GrantError(404, "native_call_not_found") from None
        await self._broker.end(call_id, request["device_id"])
        for card_id, card in list(self._cards.items()):  # nobody can tap this call's cards now
            if card.call_id == call_id and card.device_id == request["device_id"]:
                self._cards.pop(card_id, None)
                with contextlib.suppress(Exception):
                    self._resolve(card, "deny")
        return web.Response(status=204, headers={"Cache-Control": "no-store"})

    async def _ask(self, request):
        """The voice model's `ask_luna`: one message to Hermes, answered within the call."""
        from aiohttp import web
        device_id = request["device_id"]
        ask = voice.validate_ask(await request.read())
        self._broker.live_call(ask.call_id, device_id)
        chat_id = f"lens-{device_id}"
        key = (ask.call_id, ask.tool_call_id)
        seen = self._asks.get(key)
        if seen is not None:  # a network retry: never start the same request twice
            if seen[1] is None:
                raise voice.VoiceRequestError(409, "native_tool_in_progress")
            return web.json_response(seen[1], headers={"Cache-Control": "no-store"})
        if any(card.chat_id == chat_id for card in self._cards.values()):
            # Hermes is paused on an approval; a new message would interrupt that run.
            return web.json_response({"response": voice.answer(voice.APPROVAL_PENDING)},
                                     headers={"Cache-Control": "no-store"})
        self._asks[key] = (time.monotonic(), None)
        try:
            async with self._chat_locks.setdefault(chat_id, asyncio.Lock()):
                if not await self._previous_turn_finished(chat_id):
                    self._asks.pop(key, None)
                    return web.json_response({"response": voice.failure(
                        "I'm still finishing your last request. Try again in a moment.")},
                        headers={"Cache-Control": "no-store"})
                self._active_call[chat_id] = ask.call_id
                self._turn_messages.pop(chat_id, None)
                # What the voice model relays stays conversational: it can never run a gateway
                # command or answer an approval prompt. Only the tap on the phone does that.
                event = MessageEvent(text=ask.request, message_type=MessageType.TEXT,
                                     source=self._source(chat_id, device_id), message_id=str(uuid.uuid4()),
                                     allow_gateway_control=False)
                self._current_event[chat_id] = event.message_id
                self._lens_turns[chat_id] = (event.message_id, time.monotonic(), asyncio.Event())
                response = await self._turn(request, chat_id, device_id, event.message_id,
                                            lambda: self._spawn(self.handle_message(event)))
        except BaseException:
            self._asks.pop(key, None)
            raise
        if response.status == 200:
            self._asks[key] = (time.monotonic(), json.loads(response.body))
        else:
            self._asks.pop(key, None)
        return response

    async def _approve(self, request):
        """The user's tap on the card: resume (or deny) the Hermes run, then speak the outcome."""
        from aiohttp import web
        device_id = request["device_id"]
        call_id, card_id, choice = voice.validate_approval(await request.read())
        card = self._cards.get(card_id)
        if (card is None or card.device_id != device_id or card.call_id != call_id
                or time.monotonic() - card.created > APPROVAL_TTL_SECONDS):
            raise voice.VoiceRequestError(404, "native_approval_not_found")
        try:
            self._broker.live_call(call_id, device_id)  # the call that showed the card is still on
        except grant.GrantError:
            raise voice.VoiceRequestError(404, "native_approval_not_found") from None
        del self._cards[card_id]
        decision = "once" if choice == "approve" else "deny"  # never a standing approval from a call

        def start():
            if self._resolve(card, decision) == 0:
                raise voice.VoiceRequestError(404, "native_approval_not_found")
        if decision == "deny":
            start()
            return web.json_response({"response": voice.answer("Declined; nothing was done.")},
                                     headers={"Cache-Control": "no-store"})
        async with self._chat_locks.setdefault(card.chat_id, asyncio.Lock()):
            return await self._turn(request, card.chat_id, device_id, card.event_id, start)

    async def _turn(self, request, chat_id: str, device_id: str, event_id: str, start):
        """Start something in Hermes and wait for the answer to `event_id`, or an approval card.
        A phone that hangs up (barge-in) or a run past the call's patience stops the turn."""
        from aiohttp import web
        waiter = asyncio.get_running_loop().create_future()
        self._waiters[chat_id] = (event_id, waiter)
        try:
            start()
            deadline = time.monotonic() + ASK_TIMEOUT_SECONDS
            while not waiter.done():
                if request.transport is None or request.transport.is_closing():
                    await self._stop(chat_id, device_id)
                    return web.Response(status=499)
                if time.monotonic() > deadline:
                    await self._stop(chat_id, device_id)
                    return web.json_response({"response": voice.failure(
                        "That is taking longer than a call allows, so I stopped it. "
                        "Ask me to run it in the background instead.")}, headers={"Cache-Control": "no-store"})
                await asyncio.wait({waiter}, timeout=0.5)
            kind, value = waiter.result()
        finally:
            if self._waiters.get(chat_id, (None, None))[1] is waiter:
                del self._waiters[chat_id]
        if kind == "approval":
            body = {"response": voice.needs_approval(value.summary),
                    "approval": {"id": value.id, "summary": value.summary, "detail": value.detail,
                                 "risky": value.risky}}
        elif kind == "failed":
            body = {"response": voice.failure(value)}
        else:
            body = {"response": voice.answer(voice.spoken(value) or "Done.")}
        return web.json_response(body, headers={"Cache-Control": "no-store"})

    async def _stop(self, chat_id: str, device_id: str) -> None:
        """Interrupt the turn the way a user would: the gateway's own /stop command. Its
        approval cards go with it."""
        self._drop_cards(chat_id)
        event = MessageEvent(text="/stop", message_type=MessageType.COMMAND,
                             source=self._source(chat_id, device_id), message_id=str(uuid.uuid4()))
        self._spawn(self.handle_message(event))

    async def _previous_turn_finished(self, chat_id: str) -> bool:
        """Wait briefly for the chat's previous Hermes turn (usually one just stopped) to end."""
        running = self._lens_turns.get(chat_id)
        if running is None:
            return True
        if time.monotonic() - running[1] > STALE_TURN_SECONDS:
            self._lens_turns.pop(chat_id, None)
            return True
        try:
            await asyncio.wait_for(running[2].wait(), STOPPING_GRACE_SECONDS)
            return True
        except asyncio.TimeoutError:
            return False

    def _spawn(self, coroutine) -> asyncio.Task:
        task = asyncio.get_running_loop().create_task(coroutine)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def _drop_cards(self, chat_id: str, event_id: Optional[str] = None) -> None:
        """Deny the cards of a turn that ended or was stopped: nobody should tap them later."""
        for card_id, card in list(self._cards.items()):
            if card.chat_id == chat_id and (event_id is None or card.event_id == event_id):
                self._cards.pop(card_id, None)
                with contextlib.suppress(Exception):
                    self._resolve(card, "deny")

    async def reauthorize_native_roles(self, source) -> bool:
        """Hermes re-checks a role-authorized sender before running its turn. A phone still
        counts if it authenticated recently and the token it used is still the configured one,
        so rotating HERMES_LENS_TOKEN revokes every phone at once."""
        device_id = str(getattr(source, "user_id", "") or "").removeprefix("lens-")
        seen = self._verified.get(device_id)
        if seen is None or time.monotonic() - seen[0] > VERIFIED_SECONDS:
            return False
        current = _secret("HERMES_LENS_TOKEN")
        return bool(current) and hmac.compare_digest(_digest(current), seen[1])

    def _source(self, chat_id: str, device_id: str):
        # The bearer token already authenticated the phone (checked in `_guard`), the way
        # Discord role auth vouches for a member; no pairing code is needed.
        return self.build_source(chat_id=chat_id, chat_name="Hermes Lens", chat_type="dm",
                                 user_id=f"lens-{device_id}", user_name="Hermes Lens",
                                 role_authorized=True)

    def _resolve(self, card: _Card, choice: str) -> int:
        """Resolve exactly this card's approval. Never the session's oldest pending one."""
        if not card.request_id:
            return 0
        from tools import approval
        resolve_card = getattr(approval, "resolve_gateway_approval_card", None)
        if resolve_card is not None:
            return resolve_card(card.session_key, choice, card.request_id)
        return approval.resolve_gateway_approval(card.session_key, choice, request_id=card.request_id)

    async def _sweep(self) -> None:
        while True:
            await asyncio.sleep(10)
            self._sweep_once(time.monotonic())

    def _sweep_once(self, now: float) -> None:
        """Deny unanswered cards (silence is never consent) and forget idle per-device state."""
        for card_id, card in list(self._cards.items()):
            if now - card.created > APPROVAL_TTL_SECONDS:
                self._cards.pop(card_id, None)
                with contextlib.suppress(Exception):
                    self._resolve(card, "deny")
        window = max(RATE_LIMIT[1], GLOBAL_RATE_LIMIT[1])
        for device_id, hits in list(self._hits.items()):
            if not hits or now - hits[-1] > window:
                del self._hits[device_id]
        for device_id, (seen, _) in list(self._verified.items()):
            if now - seen > VERIFIED_SECONDS:
                del self._verified[device_id]
        for key, (started, _) in list(self._asks.items()):
            if now - started > ASK_REPLAY_SECONDS:
                del self._asks[key]
        for chat_id, (_, started, _) in list(self._lens_turns.items()):
            if now - started > STALE_TURN_SECONDS:
                del self._lens_turns[chat_id]
        busy = set(self._waiters) | set(self._lens_turns) | {card.chat_id for card in self._cards.values()}
        for chat_id, lock in list(self._chat_locks.items()):
            if chat_id not in busy and not lock.locked():
                del self._chat_locks[chat_id]
                self._active_call.pop(chat_id, None)
                self._current_event.pop(chat_id, None)
                self._turn_messages.pop(chat_id, None)

    async def _config(self, request):
        from aiohttp import web
        return web.json_response(client_config(self.assistant), headers={"Cache-Control": "no-store"})

    async def _health(self, request):
        from aiohttp import web
        return web.json_response({"status": "ok"})

    # ----- auth ----------------------------------------------------------------------------

    @property
    def _guard(self):
        from aiohttp import web

        @web.middleware
        async def guard(request, handler):
            supplied = request.headers.get("Authorization", "").encode("utf-8", "replace")
            token = _secret("HERMES_LENS_TOKEN")  # live: rotating it locks old phones out at once
            if len(token) < 24 or not hmac.compare_digest(supplied, f"Bearer {token}".encode()):
                return web.json_response({"error": {"code": "unauthorized"}}, status=401)
            try:
                device_id = str(uuid.UUID(request.headers.get("X-Hermes-Device-Id", "")))
            except ValueError:
                return web.json_response({"error": {"code": "device_invalid"}}, status=400)
            key = request.headers.get("Idempotency-Key", "")
            try:
                request["idempotency_key"] = str(uuid.UUID(key)) if key else ""
            except ValueError:
                return web.json_response({"error": {"code": "idempotency_invalid"}}, status=400)
            now = time.monotonic()
            hits = self._hits.setdefault(device_id, deque())
            for queue, (limit, window) in ((hits, RATE_LIMIT), (self._all_hits, GLOBAL_RATE_LIMIT)):
                while queue and now - queue[0] > window:
                    queue.popleft()
                if len(queue) >= limit:
                    return web.json_response({"error": {"code": "rate_limited"}}, status=429)
            hits.append(now)
            self._all_hits.append(now)
            request["device_id"] = device_id
            self._verified[device_id] = (now, _digest(token))
            try:
                return await handler(request)
            except (grant.GrantError, voice.VoiceRequestError) as error:
                return web.json_response({"error": {"code": error.code}}, status=error.status,
                                         headers={"Cache-Control": "no-store"})
        return guard


def _digest(token: str) -> bytes:
    return hashlib.sha256(token.encode("utf-8", "replace")).digest()


def _pending_request_id(session_key: str) -> Optional[str]:
    """Hermes queues an approval before it asks the adapter to show it, and a session runs one
    turn at a time, so the newest pending entry is the one being shown. Older cores do not pass
    its id on the prompt; without the id a tap would resolve the session's oldest approval."""
    try:
        from tools import approval
        pending = approval.list_gateway_approvals(session_key)
    except Exception:
        return None
    request_id = pending[-1].get("request_id") if pending else None
    return str(request_id) if request_id else None


def client_config(assistant: str) -> dict:
    """What the app needs to enable native voice; same shape as protocol luna.native.v2."""
    return {
        "build": CONFIG_BUILD,
        "assistantIdentity": {
            "assistantName": assistant, "productName": "Hermes Lens", "singleCompanion": True,
            "exposeModelNames": False, "exposeRouteNames": False, "exposeProfileName": False,
            "exposeHarnessNames": False,
        },
        "voice": {
            "completeSentenceSilenceSeconds": 0.8, "unfinishedSentenceSilenceSeconds": 1.35,
            "playbackTailSeconds": 0.35, "realtimeSocketEnabled": False,
            "realtimeSocketProtocol": "luna.voice.v1", "nativeAudioEnabled": True,
            "nativeAudioProtocol": grant.PROTOCOL, "nativeSpokenField": "outputAudioTranscript",
            "partialRecognitionStreaming": True, "realtimeHeartbeatSeconds": 60,
            "contentFreeStageTiming": True,
        },
        "progressStates": ["Thinking", "Researching", "Using a tool", "Working", "Waiting for approval"],
        "responseStyle": {
            "mode": "voice_first", "spokenField": "observed", "spokenMinWords": 12, "spokenMaxWords": 32,
            "spokenMaxSeconds": 12, "nextActionField": "nextAction", "speakNextActionAutomatically": False,
        },
        "display": {
            "showAnswerPackHeader": False, "showSpokenGistLabel": False, "showSpokenTextOnce": True,
            "duplicateAnswerBlock": False, "primaryTextField": "observed", "nextActionAsCompactRow": True,
            "nextActionLabel": "Next", "contextCollapsedByDefault": True,
            "controls": ["Interrupt", "Ask follow-up", "Done"],
        },
        "video": {"activationPhrase": "scan this", "maxBytes": 6 * 1024 * 1024, "maxSeconds": 15,
                  "maxFrames": 6, "sandboxedDecoder": True},
        "languages": {
            "lunaPreferences": ["alwaysEnglish"], "defaultLunaPreference": "alwaysEnglish",
            "translationEnabled": False, "amharicRecognitionEnabled": False, "amharicSpeechEnabled": False,
            "translationDefaultTarget": "en", "translationFavorites": ["en"], "captionsDefault": True,
            "captionRetention": "session_only", "translationMaxSeconds": 0, "translationDailyMinutes": 0,
        },
        "updates": {"enabled": False, "retentionDays": 30, "spokenField": "observed",
                    "speakOnDemandOnly": True,
                    "quietHours": {"start": "22:00", "end": "07:00", "timezone": "UTC"}},
    }


# ----- the tap rule ----------------------------------------------------------------------------

def confirm_tools() -> frozenset:
    raw = _secret("HERMES_LENS_CONFIRM_TOOLS") or DEFAULT_CONFIRM_TOOLS
    if raw.strip().lower() in ("none", "off", "-"):
        return frozenset()
    return frozenset(name.strip() for name in raw.split(",") if name.strip())


def _session_platform() -> str:
    try:
        from gateway.session_context import get_session_env
        return get_session_env("HERMES_SESSION_PLATFORM", "")
    except Exception:
        import os
        return os.getenv("HERMES_SESSION_PLATFORM", "")


JOB_VERBS = {"create": "Start a background job", "run": "Run a background job now",
             "remove": "Delete a background job", "update": "Change a background job",
             "pause": "Pause a background job", "resume": "Resume a background job"}
MAX_VALUE_CHARS = 1_200  # per argument; the card marks anything cut (`voice.detail`)


def _describe(tool_name: str, args: dict) -> str:
    """The whole action in plain words for the approval card. When and where come first, so
    they survive the spoken headline's cut, and every other argument the tool was given is
    listed after the text: nothing the tool will receive is left off the card."""
    def clip(value) -> str:
        if isinstance(value, (list, tuple, set)):
            value = ", ".join(str(item) for item in value)
        text = " ".join(str(value if value is not None else "").split())
        return text if len(text) <= MAX_VALUE_CHARS else f"{text[:MAX_VALUE_CHARS]} … [cut]"

    def given(key: str) -> str:
        value = args.get(key)
        return "" if value is None or value == "" or value == [] or value is False else clip(value)

    if tool_name in ("cronjob_manage", "cronjob"):
        verb = JOB_VERBS.get(str(args.get("action", "")).lower(), "Change a background job")
        facts = [f"{label} {given(key)}" for key, label in
                 (("schedule", "runs"), ("repeat", "repeats"), ("deliver", "result goes to")) if given(key)]
        what = given("prompt") or given("name") or given("job_id")
        shown = {"action", "schedule", "repeat", "deliver", "prompt"} | ({"name"} if not given("prompt") else set())
        shown |= {"job_id"} if not (given("prompt") or given("name")) else set()
        head = f"{verb} ({'; '.join(facts)})" if facts else verb
    elif tool_name == "send_message":
        target = given("target") or given("to") or given("chat_id") or "a chat"
        what = given("message") or given("text")
        shown = {"target" if given("target") else "to" if given("to") else "chat_id",
                 "message" if given("message") else "text"}
        head = f"Send a message to {target}"
    else:
        head, what, shown = f"Use {tool_name}", "", set()
    rest = [f"{key}={given(key)}" for key in sorted(args) if key not in shown and given(key)]
    text = f"{head}: {what}" if what else head
    return f"{text} [also: {'; '.join(rest)}]" if rest else text


def make_confirm_hook(tools: frozenset):
    """`pre_tool_call` hook: a listed tool called from a Hermes Lens chat goes to Hermes's own
    approval gate, which shows the Approve / Decline card on the phone. Other channels and
    read-only actions are untouched; a decline, timeout or missing call blocks the tool."""
    def hook(tool_name: str = "", args: Optional[dict] = None, **_ignored):
        if tool_name not in tools or _session_platform() != PLATFORM:
            return None
        args = args if isinstance(args, dict) else {}
        if str(args.get("action", "")).lower() in READ_ONLY_ACTIONS.get(tool_name, ()):
            return None
        return {"action": "approve", "message": _describe(tool_name, args),
                "rule_key": f"hermes_lens:{tool_name}:{uuid.uuid4()}"}  # never an "always" for later calls
    return hook


# ----- registration ----------------------------------------------------------------------------

def check_requirements() -> bool:
    try:
        import aiohttp  # noqa: F401
    except ImportError:
        return False
    return bool(_secret("HERMES_LENS_TOKEN") and _secret("GEMINI_API_KEY"))


def validate_config(config) -> bool:
    return check_requirements()


def _env_enablement() -> Optional[Dict[str, Any]]:
    """Enable the channel from env alone so `hermes status` and the gateway pick it up."""
    return {} if check_requirements() else None


def register(ctx) -> None:
    kwargs = dict(
        name=PLATFORM, label="Hermes Lens (Ray-Ban Meta glasses)",
        adapter_factory=lambda cfg: HermesLensAdapter(cfg), check_fn=check_requirements,
        validate_config=validate_config, is_connected=validate_config,
        required_env=["HERMES_LENS_TOKEN", "GEMINI_API_KEY"], install_hint="pip install aiohttp",
        env_enablement_fn=_env_enablement, emoji="🕶️", pii_safe=False, allow_update_command=False,
        max_message_length=4000, platform_hint=voice.PLATFORM_HINT, display_tier="minimal",
    )
    # Feature-detect: older cores reject unknown register_platform keywords.
    try:
        import dataclasses
        from gateway.platform_registry import PlatformEntry
        known = {f.name for f in dataclasses.fields(PlatformEntry)} | {"name"}
        kwargs = {k: v for k, v in kwargs.items() if k in known}
    except Exception:
        kwargs.pop("display_tier", None)
    ctx.register_platform(**kwargs)
    tools = confirm_tools()
    if tools and hasattr(ctx, "register_hook"):
        ctx.register_hook("pre_tool_call", make_confirm_hook(tools))
