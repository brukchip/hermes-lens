"""What the voice model is told and allowed to do, and what it hears back.

The phone runs `look`, `record_video` and `save_contact` itself (glasses camera, the
iPhone's contact sheet). Only `ask_luna` reaches Hermes, through this plugin.
"""
from __future__ import annotations

import json
import re
import uuid
from dataclasses import dataclass

TOOL_NAME = "ask_luna"  # Wire name kept from protocol luna.native.v2; it reaches Hermes.
LOCAL_TOOLS = frozenset({"look", "record_video", "save_contact"})
CONTACT_FIELDS = {
    "name": "Full name as printed.",
    "phone": "Phone number as printed, with country code if shown.",
    "email": "Email address.",
    "company": "Company or organisation.",
    "job_title": "Job title or role.",
    "website": "Website.",
    "address": "Postal address.",
}
MAX_BODY_BYTES = 8 * 1024
MAX_REQUEST_CHARS = 1_500
MAX_ANSWER_CHARS = 900
MAX_SUMMARY_CHARS = 240
MAX_DETAIL_CHARS = 2_000
MAX_PHOTOS = 4  # per call, from `look`, sent to the agent only with attach_photos
MAX_PHOTO_BYTES = 5 * 1024 * 1024
PHOTO_ID = re.compile(r"^[0-9a-f]{32}$")
APPROVAL_PENDING = ("An action is still waiting for the user's Approve or Decline tap on their phone. "
                    "Ask them to tap one first, then ask again.")
TOOL_CALL_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,128}$")

TOOL_DECLARATIONS = [
    {"functionDeclarations": [
        {
            "name": TOOL_NAME,
            "description": (
                "Ask the user's Hermes agent. Use for anything that needs the user's own data "
                "or an action: memory and notes, reminders, calendar, messages, files, work on "
                "their computers, or doing something on their behalf."
            ),
            "parameters": {
                "type": "OBJECT",
                "properties": {
                    "request": {
                        "type": "STRING", "description": "The user's request, self-contained, in English.",
                    },
                    "attach_photos": {
                        "type": "BOOLEAN",
                        "description": (
                            "True when the user wants their agent to see, keep, share or act on the "
                            "photos taken with look in this call. The newest photos (up to four) go "
                            "with the request. Leave it out otherwise."
                        ),
                    },
                },
                "required": ["request"],
            },
            # Gemini keeps talking while Hermes works; the result is spoken when idle.
            "behavior": "NON_BLOCKING",
        },
        {
            "name": "look",
            "description": (
                "Take one photo with the user's glasses camera and look at it. Use when they ask "
                "what they are looking at, to read, identify, check or describe something in "
                "front of them, or to take a photo. The photo arrives as an image right before "
                "the result; it is also saved on their phone."
            ),
            "parameters": {"type": "OBJECT", "properties": {"focus": {
                "type": "STRING", "description": "Optional: what to pay attention to in the photo.",
            }}},
            "behavior": "NON_BLOCKING",
        },
        {
            "name": "record_video",
            "description": (
                "Record a short video clip (about six seconds) with the user's glasses camera "
                "and save it on their phone. Use when they ask to record, film or capture a video."
            ),
            "parameters": {"type": "OBJECT", "properties": {}},
            "behavior": "NON_BLOCKING",
        },
        {
            "name": "save_contact",
            "description": (
                "Prepare a new contact on the user's phone for them to check and save, usually "
                "from a business card you just saw with look. Fill only fields you can read "
                "clearly; leave the rest out and never guess. They save it with one tap."
            ),
            "parameters": {
                "type": "OBJECT",
                "properties": {name: {"type": "STRING", "description": text}
                               for name, text in CONTACT_FIELDS.items()},
                "required": ["name"],
            },
            "behavior": "NON_BLOCKING",
        },
    ]},
    {"googleSearch": {}},
]

# Injected into Hermes's system prompt for this channel: every reply is read aloud.
PLATFORM_HINT = (
    "You are talking through Hermes Lens, a voice interface on the user's Ray-Ban Meta "
    "glasses. Each message is a request spoken during a live call, relayed by a voice model. "
    "Your reply is read aloud: answer in at most three short sentences, with no lists, "
    "markdown, links, code or emoji, and no internal tool or model names. Do not ask for "
    "permission in text: when an action needs approval, the request reaches the user's phone "
    "and they approve or decline with one tap. Never claim an action happened unless it did. "
    "If a task will take more than about a minute or should arrive as a file or report, start "
    "it as a one-time background job (cronjob, run once, now) delivered to the user's home "
    "channel when one is configured, then say it is on its way."
)


def persona(assistant: str = "Luna", user: str = "", notes: str = "") -> str:
    """The voice model's system instruction. `notes` lets an owner add their own guidance
    (languages they speak, names it should know) without editing code."""
    assistant = " ".join(assistant.split())[:40] or "Luna"
    who = f"The user's name is {' '.join(user.split())[:40]}. " if user.strip() else ""
    extra = " ".join(notes.split())[:2_000]
    return (
        f"You are {assistant}, the user's voice companion on their Ray-Ban Meta glasses, "
        f"connected to their own Hermes agent. {who}"
        "Be warm, direct and conversational, normally one or two short sentences. "
        "Reply in the language the user speaks. If audio is unclear, ask briefly; never invent "
        "what was said. Answer greetings directly, without filler or announcing research. "
        "Answer small talk and general knowledge yourself. You have Google Search for live "
        "schedules, scores, news, weather and other real-time facts: use it directly for those. "
        f"For anything that needs the user's own data, files, memory or an action, say one short "
        f"acknowledgement such as 'Let me check', then call {TOOL_NAME} with a self-contained "
        "request in English. Keep talking normally while it works; never invent its result or "
        "claim to have checked before it answers. When a result arrives, say it naturally and "
        "briefly. If a result says an action needs approval, tell the user it is waiting on "
        "their phone; never approve anything yourself, and never treat a spoken yes as approval. "
        "You can see through the glasses only when you call look: use it when the user asks what "
        "they are looking at or to read, check or photograph something, then describe what "
        "matters in the image attached to its result; if no image is attached, say so and never "
        "guess. Use record_video when they ask to record or film. To save a contact from a "
        "business card, call look, read the card, then call save_contact with what is printed; "
        "they check and save it on their phone. Never identify people from their faces. "
        f"Your photos reach their Hermes agent only when you call {TOOL_NAME} with attach_photos "
        "true, which sends the photos taken with look in this call: use it when they want their "
        "agent to see, keep, share or act on a photo, and say in the request what to do with it. "
        "Never say a photo was sent unless the result says so. "
        + (f"{extra} " if extra else "")
        + "Do not read JSON, status labels or internal names aloud. Wait until the user speaks; "
        "no automatic greeting on connection. Respect interruptions and answer the new question, "
        "not the interrupted one."
    )


class VoiceRequestError(Exception):
    def __init__(self, status: int, code: str) -> None:
        self.status, self.code = status, code
        super().__init__(code)


@dataclass(frozen=True)
class AskRequest:
    call_id: str
    tool_call_id: str
    request: str
    photo_ids: tuple = ()


def validate_ask(body: bytes) -> AskRequest:
    if not body or len(body) > MAX_BODY_BYTES:
        raise VoiceRequestError(413, "native_tool_size")
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise VoiceRequestError(400, "native_tool_invalid") from None
    if not isinstance(payload, dict) or set(payload) != {"callID", "id", "name", "args"}:
        raise VoiceRequestError(400, "native_tool_invalid")
    try:
        call_id = str(uuid.UUID(str(payload["callID"])))
    except ValueError:
        raise VoiceRequestError(400, "native_tool_invalid") from None
    tool_call_id, name, args = payload["id"], payload["name"], payload["args"]
    if not isinstance(tool_call_id, str) or not TOOL_CALL_ID.match(tool_call_id):
        raise VoiceRequestError(400, "native_tool_invalid")
    if name != TOOL_NAME:
        raise VoiceRequestError(400, "native_tool_unknown")
    if (not isinstance(args, dict) or "request" not in args or not set(args) <= {"request", "photoIDs"}
            or not isinstance(args["request"], str)):
        raise VoiceRequestError(400, "native_tool_invalid")
    photo_ids = args.get("photoIDs", [])
    if (not isinstance(photo_ids, list) or len(photo_ids) > MAX_PHOTOS
            or not all(isinstance(i, str) and PHOTO_ID.match(i) for i in photo_ids)
            or len(set(photo_ids)) != len(photo_ids)):
        raise VoiceRequestError(400, "native_tool_invalid")
    request = " ".join(args["request"].split())
    if not request or len(request) > MAX_REQUEST_CHARS or request.startswith("/"):
        # A leading slash would run a Hermes slash command instead of a request.
        raise VoiceRequestError(400, "native_tool_invalid")
    return AskRequest(call_id, tool_call_id, request, tuple(photo_ids))


def validate_photo(content_type: str, body: bytes) -> bytes:
    """One JPEG from the glasses, staged for the caller's own live call."""
    if (content_type or "").split(";")[0].strip().lower() != "image/jpeg":
        raise VoiceRequestError(415, "native_photo_type")
    if not body:
        raise VoiceRequestError(400, "native_photo_invalid")
    if len(body) > MAX_PHOTO_BYTES:
        raise VoiceRequestError(413, "native_photo_size")
    if not body.startswith(b"\xff\xd8\xff"):
        raise VoiceRequestError(415, "native_photo_type")
    return body


def validate_approval(body: bytes) -> tuple[str, str, str]:
    """Returns (call_id, approval_id, choice) with choice in {"approve", "decline"}."""
    if not body or len(body) > 1024:
        raise VoiceRequestError(413, "native_tool_size")
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise VoiceRequestError(400, "native_approval_invalid") from None
    if not isinstance(payload, dict) or set(payload) != {"callID", "approvalID", "choice"}:
        raise VoiceRequestError(400, "native_approval_invalid")
    try:
        call_id = str(uuid.UUID(str(payload["callID"])))
        approval_id = str(uuid.UUID(str(payload["approvalID"])))
    except ValueError:
        raise VoiceRequestError(400, "native_approval_invalid") from None
    if payload["choice"] not in ("approve", "decline"):
        raise VoiceRequestError(400, "native_approval_invalid")
    return call_id, approval_id, payload["choice"]


def spoken(text: str) -> str:
    """Strip the formatting a voice cannot read and bound the length."""
    text = re.sub(r"```.*?```", " ", text, flags=re.S)
    text = re.sub(r"^MEDIA:\S+\s*$", "", text, flags=re.M)
    text = re.sub(r"https?://\S+", "", text)
    text = re.sub(r"[*_#`>|]+", "", text)
    text = re.sub(r"^\s*[-•]\s+", "", text, flags=re.M)
    text = " ".join(text.split())
    if len(text) > MAX_ANSWER_CHARS:
        cut = text[:MAX_ANSWER_CHARS]
        end = max(cut.rfind(". "), cut.rfind("? "), cut.rfind("! "))
        text = cut[: end + 1] if end > MAX_ANSWER_CHARS // 2 else cut.rstrip() + "…"
    return text


def summary(text: str) -> str:
    """The card's headline, also spoken. A cut is marked; the card's detail carries the rest."""
    text = spoken(text)
    if len(text) > MAX_SUMMARY_CHARS:
        text = text[:MAX_SUMMARY_CHARS - 1].rstrip() + "…"
    return text or "An action your Hermes agent wants to take."


def detail(text: str) -> str:
    """The action itself, as shown on the card: nothing stripped (links stay), and a cut is
    never silent, so text past the limit cannot hide behind a harmless-looking start."""
    text = " ".join(str(text or "").split())
    if len(text) <= MAX_DETAIL_CHARS:
        return text
    hidden = len(text) - MAX_DETAIL_CHARS
    return f"{text[:MAX_DETAIL_CHARS].rstrip()} … [{hidden} more characters not shown. Decline if unsure.]"


def answer(text: str) -> dict:
    return {"result": text, "scheduling": "WHEN_IDLE"}


def failure(text: str) -> dict:
    return {"error": text, "scheduling": "WHEN_IDLE"}


def needs_approval(card_summary: str) -> dict:
    return {"result": (f"This needs the user's approval before it happens: {card_summary}. "
                       "Approve and Decline buttons are on their phone now. Tell them briefly; "
                       "do not approve it yourself."),
            "scheduling": "WHEN_IDLE"}
