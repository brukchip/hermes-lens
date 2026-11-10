import json

import pytest

from hermes_lens import voice


def body(**overrides):
    payload = {"callID": "8a1f6c1e-2b7c-4a35-9a5e-0c7f1c2d3e4f", "id": "fc-1", "name": "ask_luna",
               "args": {"request": "What is on my calendar today?"}}
    payload.update(overrides)
    return json.dumps(payload).encode()


def test_persona_is_generic_and_takes_the_owner_settings():
    text = voice.persona("Nova", "Sam", "Sam speaks English and French.")
    assert text.startswith("You are Nova,") and "The user's name is Sam." in text
    assert "French" in text and "ask_luna" in text and "Never identify people from their faces" in text
    default = voice.persona()
    assert "You are Luna," in default and "user's name" not in default


def test_voice_model_can_reach_hermes_the_camera_and_contacts_but_nothing_else():
    names = [d["name"] for d in voice.TOOL_DECLARATIONS[0]["functionDeclarations"]]
    assert names == ["ask_luna", "look", "record_video", "save_contact"]
    assert {"googleSearch": {}} in voice.TOOL_DECLARATIONS
    assert voice.LOCAL_TOOLS == {"look", "record_video", "save_contact"}
    contact = voice.TOOL_DECLARATIONS[0]["functionDeclarations"][3]["parameters"]
    assert set(contact["properties"]) == set(voice.CONTACT_FIELDS) and contact["required"] == ["name"]


def test_ask_requests_are_validated_and_normalised():
    ask = voice.validate_ask(body(args={"request": "  what's   next  "}))
    assert ask.request == "what's next" and ask.tool_call_id == "fc-1"
    for bad in (body(name="look"), body(args={"request": ""}), body(args={"request": "x", "y": 1}),
                body(callID="nope"), body(id="bad id!"), b"{", b""):
        with pytest.raises(voice.VoiceRequestError):
            voice.validate_ask(bad)


def test_a_spoken_slash_never_becomes_a_hermes_command():
    with pytest.raises(voice.VoiceRequestError):
        voice.validate_ask(body(args={"request": "/approve all"}))


def test_approval_taps_are_validated():
    good = json.dumps({"callID": "8a1f6c1e-2b7c-4a35-9a5e-0c7f1c2d3e4f",
                       "approvalID": "1b2c3d4e-5f60-4718-9a0b-1c2d3e4f5a6b", "choice": "approve"}).encode()
    assert voice.validate_approval(good)[2] == "approve"
    with pytest.raises(voice.VoiceRequestError):
        voice.validate_approval(good.replace(b"approve", b"always"))


def test_answers_are_made_speakable_and_bounded():
    text = "## Plan\n- **one** item\nSee https://example.com\n```code```\nMEDIA:/tmp/report.pdf\nDone."
    assert voice.spoken(text) == "Plan one item See Done."
    long = ("A sentence that keeps going. " * 60).strip()
    assert len(voice.spoken(long)) <= voice.MAX_ANSWER_CHARS and voice.spoken(long).endswith(".")
    assert voice.summary("") == "An action your Hermes agent wants to take."
    assert voice.needs_approval("Send a message")["scheduling"] == "WHEN_IDLE"
