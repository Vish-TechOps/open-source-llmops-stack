"""Guardrails AI server config for the LLMOps stack (GCP phase B).

Loaded by `guardrails start --config config.py`. Each module-level Guard becomes
an endpoint: POST /guards/<name>/validate  {"llmOutput": "<text>"}
which is exactly what LiteLLM's `guardrails_ai` guardrail calls.

Validators are defined here (no Guardrails Hub token, no large NLP models), so
the image is small and deterministic. Swap in Hub validators later if you like
(e.g. hub://guardrails/detect_pii) by installing them in the Dockerfile.

Guards
  topic-guard     (LiteLLM pre_call)   blocks prompts that mention a banned topic
  pii-mask-guard  (LiteLLM pre_call)   masks e-mail addresses and card-like numbers
                                       in the user's message before any model sees it
  output-guard    (LiteLLM post_call)  rejects a model answer that leaks an e-mail
                                       address or a card-like number
"""

import os
import re
from typing import Any, Dict

from guardrails import Guard, OnFailAction
from guardrails.validator_base import (
    FailResult,
    PassResult,
    ValidationResult,
    Validator,
    register_validator,
)

EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# 13-19 digits, optionally separated by spaces or dashes (card-like numbers)
CARD_RE = re.compile(r"\b(?:\d[ -]?){12,18}\d\b")

BANNED_TOPICS = [
    t.strip().lower()
    for t in os.environ.get(
        "GUARD_BANNED_TOPICS",
        "make a bomb,build a weapon,credit card dump,bypass authentication",
    ).split(",")
    if t.strip()
]


def _mask(text: str) -> str:
    text = EMAIL_RE.sub("<EMAIL>", text)
    return CARD_RE.sub("<CARD_NUMBER>", text)


@register_validator(name="llmops/simple-pii", data_type="string")
class SimplePII(Validator):
    """Finds e-mail addresses and card-like numbers. fix_value is the masked text."""

    def validate(self, value: Any, metadata: Dict) -> ValidationResult:
        text = str(value)
        found = []
        if EMAIL_RE.search(text):
            found.append("email")
        if CARD_RE.search(text):
            found.append("card_number")
        if not found:
            return PassResult()
        return FailResult(
            error_message=f"PII detected: {', '.join(found)}",
            fix_value=_mask(text),
        )


@register_validator(name="llmops/banned-topics", data_type="string")
class BannedTopics(Validator):
    """Blocks text that mentions any phrase in GUARD_BANNED_TOPICS (comma-separated)."""

    def validate(self, value: Any, metadata: Dict) -> ValidationResult:
        text = str(value).lower()
        hits = [t for t in BANNED_TOPICS if t in text]
        if hits:
            return FailResult(error_message=f"Banned topic: {hits[0]}")
        return PassResult()


# One validator per guard. Combining a FIX validator with a blocking one in a single
# guard lets the fix mask the other failure (validationPassed comes back true).
# Blocking guards use NOOP, not EXCEPTION: an exception returns {"detail": ...}
# without validationPassed, and LiteLLM's client would treat that as a pass.

# Input (pre_call), runs first: a banned topic -> validationPassed=false -> LiteLLM HTTP 400.
topic_guard = Guard(id="topic-guard", name="topic-guard").use(
    BannedTopics(on_fail=OnFailAction.NOOP),
)

# Input (pre_call): e-mails and card-like numbers are masked; the request continues
# with the masked text (LiteLLM replaces the user message with validatedOutput).
pii_mask_guard = Guard(id="pii-mask-guard", name="pii-mask-guard").use(
    SimplePII(on_fail=OnFailAction.FIX),
)

# Output (post_call): PII in the model's answer -> validationPassed=false -> HTTP 400.
output_guard = Guard(id="output-guard", name="output-guard").use(
    SimplePII(on_fail=OnFailAction.NOOP),
)
