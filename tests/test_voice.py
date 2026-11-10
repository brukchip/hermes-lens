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


def test_photos_go_to_the_agent_only_when_the_voice_model_asks():
    ask_luna = voice.TOOL_DECLARATIONS[0]["functionDeclarations"][0]["parameters"]
    assert ask_luna["properties"]["attach_photos"]["type"] == "BOOLEAN"
    assert ask_luna["required"] == ["request"]
    assert "attach_photos" in voice.persona() and "Never say a photo was sent" in voice.persona()
    ids = ["a" * 32, "b" * 32]
    assert voice.validate_ask(body(args={"request": "keep this", "photoIDs": ids})).photo_ids == tuple(ids)
    assert voice.validate_ask(body(args={"request": "x"})).photo_ids == ()
    for bad in (["A" * 32], ["a" * 31], ["a" * 32, "a" * 32], ["%032x" % i for i in range(5)], "a" * 32, [1]):
        with pytest.raises(voice.VoiceRequestError):
            voice.validate_ask(body(args={"request": "x", "photoIDs": bad}))


def test_staged_photos_must_be_bounded_jpegs():
    jpeg = b"\xff\xd8\xff\xe0" + b"0" * 100
    assert voice.validate_photo("image/jpeg", jpeg) == jpeg
    assert voice.validate_photo("image/jpeg; q=1", jpeg) == jpeg
    for content_type, data, status in (("image/png", jpeg, 415), ("image/jpeg", b"\x89PNG....", 415),
                                       ("image/jpeg", b"", 400),
                                       ("image/jpeg", b"\xff\xd8\xff" + b"0" * voice.MAX_PHOTO_BYTES, 413)):
        with pytest.raises(voice.VoiceRequestError) as raised:
            voice.validate_photo(content_type, data)
        assert raised.value.status == status
