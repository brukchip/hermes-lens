import asyncio
import json
from datetime import datetime, timezone

import pytest

from hermes_lens import grant

PERSONA = "You are Luna."


def broker(tmp_path, *, status=200, data=None, daily=3600, calls=None):
    calls = calls if calls is not None else []

    async def post(url, key, payload):
        calls.append((url, key, payload))
        return status, (data if data is not None else {"name": "auth_tokens/abc"})

    usage = grant.UsageStore(tmp_path / "usage.sqlite3")
    return grant.CallBroker(usage, api_key="k", model="gemini-3.8-live", voice_name="Kore",
                            persona=PERSONA, daily_seconds=daily, http_post=post), calls


BODY = grant.validate_request(json.dumps({"protocol": grant.PROTOCOL}).encode())


def test_locked_setup_has_tools_and_search_but_no_compression():
    setup = grant.session_configuration("gemini-3.8-live", "Kore", PERSONA)
    assert setup["tools"][1] == {"googleSearch": {}}
    assert "contextWindowCompression" not in setup and "thinkingConfig" not in setup["generationConfig"]
    assert setup["systemInstruction"]["parts"][0]["text"] == PERSONA
    assert "thinkingConfig" in grant.session_configuration(
        "gemini-3.1-flash-live-preview", "Kore", PERSONA)["generationConfig"]
    with pytest.raises(grant.GrantError):
        grant.session_configuration("other-model", "Kore", PERSONA)


def test_call_requests_must_name_the_protocol():
    with pytest.raises(grant.GrantError):
        grant.validate_request(b'{"protocol": "other"}')


def test_grant_is_minted_once_per_request_and_locks_the_setup(tmp_path):
    b, calls = broker(tmp_path)
    first = asyncio.run(b.create("dev", "req-1", BODY))
    again = asyncio.run(b.create("dev", "req-1", BODY))
    assert first == again and len(calls) == 1
    assert first["token"] == "auth_tokens/abc" and first["maxSeconds"] == grant.MAX_CALL_SECONDS
    sent = calls[0][2]
    assert sent["uses"] == 1 and sent["bidiGenerateContentSetup"]["model"] == "models/gemini-3.8-live"
    assert b.live_call(first["callID"], "dev")
    with pytest.raises(grant.GrantError):
        b.live_call(first["callID"], "someone-else")


def test_a_new_call_from_the_same_phone_replaces_the_old_one(tmp_path):
    b, _ = broker(tmp_path)

    async def run():
        old = await b.create("dev", "req-1", BODY)
        new = await b.create("dev", "req-2", BODY)
        return old, new
    old, new = asyncio.run(run())
    with pytest.raises(grant.GrantError):
        b.live_call(old["callID"], "dev")
    assert b.live_call(new["callID"], "dev")


def test_daily_budget_and_provider_errors_are_reported_plainly(tmp_path):
    b, _ = broker(tmp_path, daily=60)
    with pytest.raises(grant.GrantError) as limit:
        asyncio.run(b.create("dev", "req-1", BODY))
    assert limit.value.status == 429
    b, _ = broker(tmp_path / "x", status=403)
    with pytest.raises(grant.GrantError) as provider:
        asyncio.run(b.create("dev", "req-1", BODY))
    assert provider.value.status == 503
    b, _ = broker(tmp_path / "y", data={"name": "not-a-token"})
    with pytest.raises(grant.GrantError):
        asyncio.run(b.create("dev", "req-1", BODY))


def test_ending_a_call_settles_usage_to_what_was_used(tmp_path):
    b, _ = broker(tmp_path, daily=grant.MAX_CALL_SECONDS + 100)

    async def run():
        call = await b.create("dev", "req-1", BODY)
        await b.end(call["callID"], "dev")
        return await b.create("dev", "req-2", BODY)  # fits only because the first settled
    assert asyncio.run(run())["token"]


def test_usage_store_counts_one_day(tmp_path):
    store = grant.UsageStore(tmp_path / "u.sqlite3")
    day = datetime(2026, 11, 6, 12, tzinfo=timezone.utc)
    assert store.reserve(500, 600, now=day)
    assert store.reserve(200, 600, now=day) is None
    assert store.reserve(200, 600, now=datetime(2026, 11, 7, 1, tzinfo=timezone.utc))


def test_a_refused_grant_gives_the_minutes_back(tmp_path):
    b, _ = broker(tmp_path, status=403, daily=grant.MAX_CALL_SECONDS)
    for attempt in range(3):  # each refusal would otherwise burn a whole call's budget
        with pytest.raises(grant.GrantError) as refused:
            asyncio.run(b.create("dev", f"req-{attempt}", BODY))
        assert refused.value.status == 503


def test_shutdown_charges_open_calls_only_for_time_used(tmp_path):
    b, _ = broker(tmp_path, daily=grant.MAX_CALL_SECONDS + 100)
    asyncio.run(b.create("dev", "req-1", BODY))
    b.close()
    again, _ = broker(tmp_path, daily=grant.MAX_CALL_SECONDS + 100)
    assert asyncio.run(again.create("dev", "req-2", BODY))["token"]


def test_provider_response_is_read_whole_even_when_it_arrives_in_pieces(monkeypatch):
    aiohttp = pytest.importorskip("aiohttp")
    body = json.dumps({"name": "auth_tokens/" + "x" * 3000}).encode()

    class Content:
        def __init__(self):
            self.parts = [body[i:i + 700] for i in range(0, len(body), 700)]

        async def read(self, n):
            return self.parts.pop(0) if self.parts else b""

    class Response:
        status, content = 200, Content()

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    class Session:
        def __init__(self, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

        def post(self, *args, **kwargs):
            return Response()

    monkeypatch.setattr(aiohttp, "ClientSession", Session)
    status, data = asyncio.run(grant._post_json("https://example.test", "k", {}))
    assert status == 200 and data["name"].startswith("auth_tokens/")
