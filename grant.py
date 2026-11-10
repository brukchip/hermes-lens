"""Gemini Live call grants for the glasses: the phone talks to Gemini directly.

The plugin never proxies audio. It mints a single-use ephemeral token whose setup
(model, voice, persona, tools) is locked server-side, so the phone cannot widen what
the voice model may do. Tokens live only in memory; only usage totals persist.
"""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import sqlite3
import threading
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

from . import voice

logger = logging.getLogger("hermes_lens.grant")

PROTOCOL = "luna.native.v2"
MAX_REQUEST_BYTES = 1024
MAX_CALL_SECONDS = 540  # Below Gemini Live's ~10-minute connection limit.
SETTLE_MARGIN_SECONDS = 30
MODELS = frozenset({"gemini-3.8-live", "gemini-3.1-flash-live-preview"})
# 3.8 Live rejects `thinkingConfig` at socket setup (close 1007) though the token accepts it.
MODELS_WITH_THINKING_LEVEL = frozenset({"gemini-3.1-flash-live-preview"})
VOICES = frozenset({"Kore", "Aoede", "Leda", "Zephyr", "Callirrhoe", "Despina", "Sulafat",
                    "Charon", "Puck", "Fenrir"})
TOKEN_API = "https://generativelanguage.googleapis.com/v1beta/auth_tokens"
SOCKET = ("wss://generativelanguage.googleapis.com/ws/"
          "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained")


class GrantError(Exception):
    def __init__(self, status: int, code: str) -> None:
        self.status, self.code = status, code
        super().__init__(code)


def session_configuration(model: str, voice_name: str, persona: str) -> dict:
    """The locked Gemini Live setup. Search grounding and context compression cannot be
    combined (the socket closes with 1007), and calls stay under MAX_CALL_SECONDS anyway."""
    if model not in MODELS or voice_name not in VOICES:
        raise GrantError(503, "native_configuration_invalid")
    generation: dict = {
        "responseModalities": ["AUDIO"], "maxOutputTokens": 1024,
        "speechConfig": {"voiceConfig": {"prebuiltVoiceConfig": {"voiceName": voice_name}}},
    }
    if model in MODELS_WITH_THINKING_LEVEL:
        generation["thinkingConfig"] = {"thinkingLevel": "minimal"}
    return {
        "model": f"models/{model}",
        "generationConfig": generation,
        "systemInstruction": {"parts": [{"text": persona}]},
        "outputAudioTranscription": {}, "inputAudioTranscription": {},
        "realtimeInputConfig": {
            "automaticActivityDetection": {
                "startOfSpeechSensitivity": "START_SENSITIVITY_LOW",
                "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
                "prefixPaddingMs": 200, "silenceDurationMs": 800,
            },
            "activityHandling": "START_OF_ACTIVITY_INTERRUPTS",
        },
        "tools": voice.TOOL_DECLARATIONS,
    }


def validate_request(body: bytes) -> str:
    if not body or len(body) > MAX_REQUEST_BYTES:
        raise GrantError(413, "native_request_size")
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise GrantError(400, "native_request_invalid") from None
    if payload != {"protocol": PROTOCOL}:
        raise GrantError(400, "native_request_invalid")
    return json.dumps(payload, sort_keys=True, separators=(",", ":"))


class UsageStore:
    """Daily call-time budget: one row per call (start time, seconds), never audio or tokens."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._lock = threading.Lock()
        path.parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as connection:
            connection.execute(
                "CREATE TABLE IF NOT EXISTS reservations (id TEXT PRIMARY KEY, "
                "issued_at INTEGER NOT NULL, seconds INTEGER NOT NULL)")

    def reserve(self, seconds: int, daily_limit: int, now: datetime | None = None) -> str | None:
        current = (now or datetime.now(timezone.utc)).astimezone(timezone.utc)
        day_start = int(current.replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
        reservation_id = str(uuid.uuid4())
        with self._lock, self._connect() as connection:
            connection.execute("BEGIN IMMEDIATE")
            connection.execute("DELETE FROM reservations WHERE issued_at < ?", (day_start - 40 * 86400,))
            used = connection.execute(
                "SELECT COALESCE(SUM(seconds), 0) FROM reservations WHERE issued_at >= ?",
                (day_start,)).fetchone()[0]
            if used + seconds > daily_limit:
                connection.rollback()
                return None
            connection.execute("INSERT INTO reservations VALUES (?, ?, ?)",
                               (reservation_id, int(current.timestamp()), seconds))
            connection.commit()
            return reservation_id

    def settle(self, reservation_id: str, used_seconds: int) -> None:
        """Shrink a reservation to what the call used; never grow it."""
        with self._lock, self._connect() as connection:
            connection.execute("UPDATE reservations SET seconds = MIN(seconds, ?) WHERE id = ?",
                               (max(0, int(used_seconds)), reservation_id))

    @contextlib.contextmanager
    def _connect(self):
        """One short-lived connection per operation: committed (or rolled back), then closed."""
        connection = sqlite3.connect(self.path, timeout=5.0)
        try:
            with connection:
                yield connection
        finally:
            connection.close()


@dataclass
class Call:
    device_id: str
    request_id: str
    digest: str
    identifier: str = field(default_factory=lambda: str(uuid.uuid4()))
    created: float = field(default_factory=time.monotonic)
    payload: dict | None = None
    ended: bool = False
    reservation_id: str | None = None
    settled: bool = False

    def is_live(self) -> bool:
        return not self.ended and self.payload is not None and time.monotonic() - self.created < MAX_CALL_SECONDS


class CallBroker:
    """One live call per phone. A new request from the same phone ends the old one: a
    phone that crashed or never sent DELETE must not be locked out for nine minutes."""

    def __init__(self, usage: UsageStore, *, api_key: str, model: str, voice_name: str,
                 persona: str, daily_seconds: int, http_post=None) -> None:
        self._calls: dict[str, Call] = {}
        self._lock = asyncio.Lock()
        self._usage = usage
        self._api_key, self._model, self._voice, self._persona = api_key, model, voice_name, persona
        self._daily_seconds = daily_seconds
        self._http_post = http_post or _post_json

    async def create(self, device_id: str, request_id: str, body: str) -> dict:
        setup = session_configuration(self._model, self._voice, self._persona)
        digest = hashlib.sha256(body.encode()).hexdigest()
        replaced: list[Call] = []
        async with self._lock:
            now = time.monotonic()
            self._calls = {k: v for k, v in self._calls.items() if now - v.created < 3600}
            for existing in self._calls.values():
                if now - existing.created >= MAX_CALL_SECONDS:
                    existing.ended, existing.payload = True, None
                if existing.device_id == device_id and existing.request_id == request_id:
                    if existing.digest != digest:
                        raise GrantError(409, "native_request_conflict")
                    if existing.ended:
                        raise GrantError(410, "native_call_ended")
                    if existing.payload:
                        return existing.payload
                    raise GrantError(409, "native_call_connecting")
            for existing in self._calls.values():
                if existing.device_id == device_id and not existing.ended:
                    if existing.payload is None:
                        raise GrantError(409, "native_call_already_active")
                    replaced.append(existing)
            for existing in replaced:
                existing.ended, existing.payload = True, None
            if len(self._calls) >= 256 or sum(not c.ended for c in self._calls.values()) >= 4:
                raise GrantError(429, "native_call_limit")
            call = Call(device_id, request_id, digest)
            self._calls[call.identifier] = call
        for existing in replaced:
            await self._settle(existing)
        try:
            call.reservation_id = await asyncio.to_thread(
                self._usage.reserve, MAX_CALL_SECONDS, self._daily_seconds)
            if call.reservation_id is None:
                raise GrantError(429, "native_usage_limit")
            # Never refund an uncertain request: Gemini may already have issued the token.
            now = datetime.now(timezone.utc)
            expires = now + timedelta(seconds=MAX_CALL_SECONDS)
            new_session_expires = now + timedelta(seconds=60)
            status, data = await self._http_post(TOKEN_API, self._api_key, {
                "uses": 1, "expireTime": expires.isoformat(),
                "newSessionExpireTime": new_session_expires.isoformat(),
                "bidiGenerateContentSetup": setup,
            })
            if status != 200:
                # Google answered and issued nothing: give the reserved minutes back.
                logger.warning("hermes_lens grant rejected status=%d", status)
                call.settled = True
                await asyncio.to_thread(self._usage.settle, call.reservation_id, 0)
                raise GrantError(503, "native_provider_unavailable")
            token = data.get("name") if isinstance(data, dict) else None
            if not isinstance(token, str) or not token.startswith("auth_tokens/") or len(token) > 16_384:
                raise GrantError(502, "native_provider_response_invalid")
            if call.ended:
                raise GrantError(410, "native_call_ended")
            call.payload = {
                "protocol": PROTOCOL, "callID": call.identifier, "token": token,
                "websocketURL": SOCKET, "model": self._model,
                "expiresAt": expires.isoformat(), "newSessionExpiresAt": new_session_expires.isoformat(),
                "maxSeconds": MAX_CALL_SECONDS, "tools": True,
            }
            return call.payload
        except BaseException as error:
            call.ended, call.payload = True, None
            if isinstance(error, (GrantError, asyncio.CancelledError)):
                raise
            raise GrantError(503, "native_connection_failed") from None

    async def end(self, identifier: str, device_id: str) -> None:
        call = self._calls.get(identifier)
        if call is None or call.device_id != device_id:
            raise GrantError(404, "native_call_not_found")
        # Forgets the grant; it does not revoke a Gemini socket already open.
        call.ended, call.payload = True, None
        await self._settle(call)

    def live_call(self, identifier: str, device_id: str) -> Call:
        call = self._calls.get(identifier)
        if call is None or call.device_id != device_id or not call.is_live():
            raise GrantError(404, "native_call_not_found")
        return call

    async def _settle(self, call: Call) -> None:
        if call.settled or not call.reservation_id:
            return
        call.settled = True
        await asyncio.to_thread(self._usage.settle, call.reservation_id, self._used(call))

    @staticmethod
    def _used(call: Call) -> int:
        return min(MAX_CALL_SECONDS, int(time.monotonic() - call.created) + SETTLE_MARGIN_SECONDS)

    def close(self) -> None:
        """Gateway shutdown: end every call and charge it only for the time it ran."""
        for call in self._calls.values():
            call.ended, call.payload = True, None
            if call.reservation_id and not call.settled:
                call.settled = True
                with contextlib.suppress(Exception):
                    self._usage.settle(call.reservation_id, self._used(call))


async def _post_json(url: str, api_key: str, body: dict) -> tuple[int, dict | None]:
    import aiohttp
    timeout = aiohttp.ClientTimeout(total=15)
    async with aiohttp.ClientSession(timeout=timeout, trust_env=False) as session:
        async with session.post(url, headers={"x-goog-api-key": api_key}, json=body,
                                allow_redirects=False) as response:
            raw = b""
            while len(raw) <= 64 * 1024:  # read() returns what is buffered, not the whole body
                chunk = await response.content.read(64 * 1024 + 1 - len(raw))
                if not chunk:
                    break
                raw += chunk
            if len(raw) > 64 * 1024:
                return 502, None
            try:
                return response.status, json.loads(raw)
            except ValueError:
                return response.status, None
