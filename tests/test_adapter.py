"""The phone-facing server against a fake Hermes runner (needs Hermes importable)."""
import asyncio
import json
import uuid
from types import SimpleNamespace

import pytest

pytest.importorskip("gateway.platforms.base")
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402

from hermes_lens import adapter as lens  # noqa: E402

TOKEN = "t" * 32
DEVICE = "5f0c3b8e-1d2a-4c6b-9e7f-0a1b2c3d4e5f"


def headers(token=TOKEN, device=DEVICE, key=None):
    return {"Authorization": f"Bearer {token}", "X-Hermes-Device-Id": device,
            "Idempotency-Key": key or str(uuid.uuid4()), "Content-Type": "application/json"}


class FakeHermes:
    """Stands in for the gateway runner: answers, asks for approval, or hangs."""

    def __init__(self, adapter):
        self.adapter, self.events, self.resolved = adapter, [], []
        self.choice = None

    async def handle(self, event):
        """Like the gateway: sends during the turn, then the completion hook."""
        from gateway.platforms.event import ProcessingOutcome
        await self._turn(event)
        await self.adapter.on_processing_complete(event, ProcessingOutcome.SUCCESS)

    async def _turn(self, event):
        self.events.append(event)
        chat = event.source.chat_id
        if event.text == "/stop" or "silent" in event.text:
            return
        if "send it" in event.text:
            self.choice = asyncio.get_running_loop().create_future()
            prompt = SimpleNamespace(chat_id=chat, session_key="session-1", command="send_message to=Sam",
                                     description="Send the weekly report to Sam", request_id="req-1",
                                     smart_denied="risky" in event.text)
            await self.adapter._send_exec_approval_prompt(prompt)
            choice = await self.choice
            await self.adapter.send(chat, "Sent it to Sam." if choice == "once" else "Not sent.")
        elif "slow" in event.text:
            await asyncio.sleep(3600)
        else:
            await self.adapter.send(chat, "📬 No home channel is set for Hermes Lens.")  # unmarked notice
            await self.adapter.send(chat, "Looking it up…", metadata={"_interim_send": True})
            await self.adapter.send(chat, f"**Answer:** {event.text}\nhttps://example.com")

    def resolve(self, session_key, choice, request_id=None):
        self.resolved.append((session_key, choice, request_id))
        if self.choice and not self.choice.done():
            self.choice.set_result(choice)
            return 1
        return 0


def _register_platform():
    """What Hermes does when it loads the plugin."""
    from gateway.platform_registry import PlatformEntry, platform_registry
    lens.register(SimpleNamespace(register_platform=lambda **kw: platform_registry.register(PlatformEntry(**kw))))


@pytest.fixture
def server(monkeypatch, tmp_path):
    settings = {"HERMES_LENS_TOKEN": TOKEN, "GEMINI_API_KEY": "g"}
    monkeypatch.setattr(lens, "_secret", lambda name, default="": settings.get(name, default))
    _register_platform()
    adapter = lens.HermesLensAdapter(SimpleNamespace(extra={}))
    fake = FakeHermes(adapter)
    adapter.handle_message = fake.handle
    import tools.approval as approval
    monkeypatch.setattr(approval, "resolve_gateway_approval_card",
                        lambda key, choice, rid: fake.resolve(key, choice, rid), raising=False)

    async def post(url, key, body):
        return 200, {"name": "auth_tokens/test"}
    app = adapter.build_app(tmp_path, http_post=post)
    return adapter, fake, app


def run(app, scenario):
    async def go():
        async with TestClient(TestServer(app)) as client:
            return await scenario(client)
    return asyncio.run(go())


async def start_call(client):
    response = await client.post("/v1/lens/realtime/calls", data=json.dumps({"protocol": "luna.native.v2"}),
                                 headers=headers())
    assert response.status == 200
    return (await response.json())["callID"]


async def ask(client, call_id, text, tool_id=None):
    body = {"callID": call_id, "id": tool_id or f"fc-{uuid.uuid4().hex[:8]}", "name": "ask_luna",
            "args": {"request": text}}
    return await client.post("/v1/lens/native/tools", data=json.dumps(body), headers=headers())


def test_only_the_paired_phone_gets_in(server):
    adapter, fake, app = server

    async def scenario(client):
        assert (await client.get("/health", headers=headers(token="wrong" * 8))).status == 401
        assert (await client.get("/health", headers=headers(device="not-a-uuid"))).status == 400
        config = await (await client.get("/v1/lens/config", headers=headers())).json()
        assert config["voice"]["nativeAudioEnabled"] is True
        assert config["voice"]["nativeAudioProtocol"] == "luna.native.v2"
        assert config["assistantIdentity"]["assistantName"] == "Luna"
        statuses = [(await client.get("/health", headers=headers())).status for _ in range(30)]
        return statuses
    assert run(app, scenario)[-1] == 429


def test_a_spoken_request_becomes_a_hermes_message_and_comes_back_speakable(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        response = await ask(client, call_id, "what is on my calendar")
        return response.status, await response.json()
    status, body = run(app, scenario)
    assert status == 200
    assert body == {"response": {"result": "Answer: what is on my calendar", "scheduling": "WHEN_IDLE"}}
    event = fake.events[0]
    assert event.text == "what is on my calendar"
    # Spoken text can never act as a gateway command or answer an approval prompt.
    assert event.allow_gateway_control is False and event.get_command() is None
    assert event.source.chat_id == f"lens-{DEVICE}" and event.source.role_authorized is True


def test_asks_need_the_callers_own_live_call(server):
    adapter, fake, app = server

    async def scenario(client):
        await start_call(client)
        return (await ask(client, str(uuid.uuid4()), "hello")).status
    assert run(app, scenario) == 404 and fake.events == []


def test_approval_waits_for_the_tap_and_only_the_tap_resumes_it(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        first = await (await ask(client, call_id, "send it to Sam")).json()
        card = first["approval"]
        assert card["summary"] == "Send the weekly report to Sam"
        assert "needs the user's approval" in first["response"]["result"]
        assert fake.resolved == []  # nothing approved by voice or by timeout
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        second = await client.post("/v1/lens/native/approvals", data=json.dumps(tap), headers=headers())
        replay = await client.post("/v1/lens/native/approvals", data=json.dumps(tap), headers=headers())
        return await second.json(), replay.status
    outcome, replay = run(app, scenario)
    assert fake.resolved == [("session-1", "once", "req-1")]
    assert outcome == {"response": {"result": "Sent it to Sam.", "scheduling": "WHEN_IDLE"}}
    assert replay == 404


def test_decline_denies_and_answers_at_once(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "decline"}
        return await (await client.post("/v1/lens/native/approvals", data=json.dumps(tap),
                                        headers=headers())).json()
    assert "Declined" in run(app, scenario)["response"]["result"]
    assert fake.resolved == [("session-1", "deny", "req-1")]


def test_another_phone_cannot_answer_the_card(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        other = await client.post("/v1/lens/native/approvals", data=json.dumps(tap),
                                  headers=headers(device=str(uuid.uuid4())))
        return other.status
    assert run(app, scenario) == 404 and fake.resolved == []


def test_an_approval_with_no_call_to_show_it_on_is_denied(server):
    adapter, fake, app = server
    prompt = SimpleNamespace(chat_id=f"lens-{DEVICE}", session_key="s", command="rm", description="x",
                             request_id="r", smart_denied=False)
    result = asyncio.run(adapter._send_exec_approval_prompt(prompt))
    assert result.success is False and fake.resolved == [("s", "deny", "r")]


def test_a_run_past_the_calls_patience_is_stopped(server, monkeypatch):
    adapter, fake, app = server
    monkeypatch.setattr(lens, "ASK_TIMEOUT_SECONDS", 1.0)

    async def scenario(client):
        call_id = await start_call(client)
        body = await (await ask(client, call_id, "slow job")).json()
        await asyncio.sleep(0.1)
        return body
    body = run(app, scenario)
    assert "stopped it" in body["response"]["error"]
    assert [e.text for e in fake.events][-1] == "/stop"


def test_unanswered_cards_expire_as_a_deny(server, monkeypatch):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        adapter._cards[card["id"]].created -= lens.APPROVAL_TTL_SECONDS + 1
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        return (await client.post("/v1/lens/native/approvals", data=json.dumps(tap), headers=headers())).status
    assert run(app, scenario) == 404 and fake.resolved == []


def test_hermes_role_recheck_trusts_only_recently_authenticated_phones(server, monkeypatch):
    adapter, fake, app = server

    async def scenario(client):
        await client.get("/health", headers=headers())
    run(app, scenario)
    me = SimpleNamespace(user_id=f"lens-{DEVICE}")
    stranger = SimpleNamespace(user_id=f"lens-{uuid.uuid4()}")
    assert asyncio.run(adapter.reauthorize_native_roles(me)) is True
    assert asyncio.run(adapter.reauthorize_native_roles(stranger)) is False
    # Rotating the token revokes the phone at once.
    monkeypatch.setattr(lens, "_secret", lambda name, default="": "r" * 32 if name == "HERMES_LENS_TOKEN" else default)
    assert asyncio.run(adapter.reauthorize_native_roles(me)) is False


def test_a_turn_with_no_answer_is_reported_plainly(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        return await (await ask(client, call_id, "silent please")).json()
    assert "did not answer" in run(app, scenario)["response"]["error"]


def test_the_card_shows_the_command_itself_and_the_safety_flag(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        return (await (await ask(client, call_id, "send it, risky")).json())["approval"]
    card = run(app, scenario)
    assert card["detail"] == "send_message to=Sam" and card["risky"] is True


def test_older_cores_resolve_the_exact_pending_approval_never_the_oldest(server, monkeypatch):
    """Hermes 0.22.x passes no request_id on the prompt: the card takes it from the queue."""
    adapter, fake, app = server
    import tools.approval as approval
    monkeypatch.delattr(approval, "resolve_gateway_approval_card", raising=False)
    exact = []
    monkeypatch.setattr(approval, "list_gateway_approvals",
                        lambda key: [{"request_id": "older"}, {"request_id": "newest"}], raising=False)
    monkeypatch.setattr(approval, "resolve_gateway_approval",
                        lambda key, choice, request_id=None, **kw: exact.append(request_id)
                        or fake.resolve(key, choice, request_id), raising=False)
    original = fake._turn

    async def turn_without_request_id(event):
        if "send it" in event.text:
            event_prompt = SimpleNamespace(chat_id=event.source.chat_id, session_key="session-1",
                                           command="send_message", description="Send it",
                                           smart_denied=False)
            fake.choice = asyncio.get_running_loop().create_future()
            await adapter._send_exec_approval_prompt(event_prompt)
            choice = await fake.choice
            await adapter.send(event.source.chat_id, "Sent." if choice == "once" else "Not sent.")
            return
        await original(event)
    fake._turn = turn_without_request_id

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        return await (await client.post("/v1/lens/native/approvals", data=json.dumps(tap),
                                        headers=headers())).json()
    assert run(app, scenario)["response"]["result"] == "Sent."
    assert exact == ["newest"]


def test_without_an_approval_id_nothing_is_resolved_and_no_card_is_shown(server, monkeypatch):
    adapter, fake, app = server
    import tools.approval as approval
    monkeypatch.setattr(approval, "list_gateway_approvals", lambda key: [], raising=False)
    prompt = SimpleNamespace(chat_id=f"lens-{DEVICE}", session_key="s", command="rm", description="x",
                             smart_denied=False)
    result = asyncio.run(adapter._send_exec_approval_prompt(prompt))
    assert result.success is False and fake.resolved == [] and adapter._cards == {}


def test_a_new_question_while_a_card_waits_does_not_interrupt_the_paused_run(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        await ask(client, call_id, "send it")
        body = await (await ask(client, call_id, "what time is it")).json()
        return body, len(fake.events)
    body, events = run(app, scenario)
    assert "waiting" in body["response"]["result"] and events == 1


def test_a_tap_after_the_call_ended_is_refused(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        await client.delete(f"/v1/lens/realtime/calls/{call_id}", headers=headers())
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        return (await client.post("/v1/lens/native/approvals", data=json.dumps(tap),
                                  headers=headers())).status
    # Hanging up declines the card at once: the paused run ends instead of waiting two minutes.
    assert run(app, scenario) == 404 and fake.resolved == [("session-1", "deny", "req-1")]


def test_a_live_token_that_became_too_short_locks_every_phone_out(server, monkeypatch):
    adapter, fake, app = server

    async def scenario(client):
        monkeypatch.setattr(lens, "_secret", lambda name, default="": "short"
                            if name == "HERMES_LENS_TOKEN" else default)
        return (await client.get("/health", headers=headers(token="short"))).status
    assert run(app, scenario) == 401


def test_deeply_nested_json_is_a_bad_request_not_a_crash(server):
    adapter, fake, app = server

    async def scenario(client):
        tool = await client.post("/v1/lens/native/tools", data="[" * 8000, headers=headers())
        tap = await client.post("/v1/lens/native/approvals", data="[" * 1000, headers=headers())
        return tool.status, tap.status
    assert run(app, scenario) == (400, 400)


def test_a_stopped_turn_takes_its_cards_with_it(server, monkeypatch):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        card = (await (await ask(client, call_id, "send it")).json())["approval"]
        await adapter._stop(f"lens-{DEVICE}", DEVICE)
        tap = {"callID": call_id, "approvalID": card["id"], "choice": "approve"}
        status = (await client.post("/v1/lens/native/approvals", data=json.dumps(tap),
                                    headers=headers())).status
        await asyncio.sleep(0.05)
        return status
    assert run(app, scenario) == 404
    assert fake.resolved == [("session-1", "deny", "req-1")]  # denied by the stop, never approved


def test_a_late_finish_of_an_older_turn_never_answers_the_current_question(server):
    adapter, fake, app = server
    from gateway.platforms.event import ProcessingOutcome

    async def scenario(client):
        call_id = await start_call(client)
        chat = f"lens-{DEVICE}"
        original = fake.handle

        async def handle(event):
            if event.text == "current":
                stale = SimpleNamespace(source=event.source, message_id="older-turn")
                await adapter.send(chat, "Answer to an older question")
                await adapter.on_processing_complete(stale, ProcessingOutcome.SUCCESS)
            await original(event)
        adapter.handle_message = handle
        return await (await ask(client, call_id, "current")).json()
    assert run(app, scenario)["response"]["result"] == "Answer: current"


def test_a_retried_ask_returns_the_first_answer_without_asking_again(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        first = await (await ask(client, call_id, "hello", tool_id="fc-1")).json()
        second = await (await ask(client, call_id, "hello", tool_id="fc-1")).json()
        return first, second
    first, second = run(app, scenario)
    assert first == second and len(fake.events) == 1


def test_a_rotated_token_is_refused_at_once(server, monkeypatch):
    adapter, fake, app = server

    async def scenario(client):
        before = (await client.get("/health", headers=headers())).status
        monkeypatch.setattr(lens, "_secret", lambda name, default="": "n" * 32
                            if name == "HERMES_LENS_TOKEN" else default)
        after = (await client.get("/health", headers=headers())).status
        return before, after
    assert run(app, scenario) == (200, 401)


def test_idle_per_device_state_is_forgotten(server):
    adapter, fake, app = server

    async def scenario(client):
        call_id = await start_call(client)
        await ask(client, call_id, "hello")
    run(app, scenario)
    import time as clock
    adapter._sweep_once(clock.monotonic() + lens.ASK_REPLAY_SECONDS + lens.VERIFIED_SECONDS)
    assert not (adapter._hits or adapter._verified or adapter._asks or adapter._chat_locks)


def test_a_question_after_a_stop_waits_for_the_stopped_turn_to_end(server, monkeypatch):
    """Real Hermes folds a message sent while a stopped turn winds down into that dying turn,
    and the question is lost. The next ask waits for the old turn to report completion."""
    adapter, fake, app = server
    from gateway.platforms.event import ProcessingOutcome
    monkeypatch.setattr(lens, "ASK_TIMEOUT_SECONDS", 0.5)
    original = fake.handle
    slow = {}

    async def handle(event):
        if event.text == "slow job":
            slow["event"] = event
            fake.events.append(event)
            return
        if event.text == "/stop" and "event" in slow:
            fake.events.append(event)
            await asyncio.sleep(0.3)  # the stopped run takes a moment to wind down
            await adapter.on_processing_complete(slow.pop("event"), ProcessingOutcome.CANCELLED)
            return
        await original(event)
    adapter.handle_message = handle

    async def scenario(client):
        call_id = await start_call(client)
        await ask(client, call_id, "slow job")
        return await (await ask(client, call_id, "hello")).json()
    assert run(app, scenario)["response"]["result"] == "Answer: hello"
    assert [e.text for e in fake.events] == ["slow job", "/stop", "hello"]


def test_a_turn_that_never_winds_down_gets_a_plain_answer_not_a_lost_question(server, monkeypatch):
    adapter, fake, app = server
    monkeypatch.setattr(lens, "ASK_TIMEOUT_SECONDS", 0.3)
    monkeypatch.setattr(lens, "STOPPING_GRACE_SECONDS", 0.3)

    async def scenario(client):
        call_id = await start_call(client)
        await ask(client, call_id, "slow job")
        return await (await ask(client, call_id, "hello")).json()
    body = run(app, scenario)
    assert "still finishing" in body["response"]["error"]
    assert "hello" not in [e.text for e in fake.events]


def test_the_plugins_own_state_survives_the_base_adapter_lifecycle(server):
    """Hermes's BasePlatformAdapter keeps its own private attributes (0.22.5 has a `_running`
    flag). Plugin state must not share a name, or the base class overwrites it."""
    adapter, fake, app = server
    adapter._mark_connected()
    adapter._mark_disconnected()
    for name in ("_waiters", "_current_event", "_lens_turns", "_active_call", "_chat_locks", "_cards",
                 "_hits", "_verified", "_turn_messages", "_asks"):
        assert isinstance(getattr(adapter, name), dict), name
    assert isinstance(adapter._tasks, set)
