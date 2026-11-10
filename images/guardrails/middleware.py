"""Request-key adapter between LiteLLM and the Guardrails AI server.

LiteLLM's `guardrails_ai` guardrail POSTs {"llmOutput": "..."} to
/guards/<name>/validate, but guardrails-api 0.4.x reads the snake_case key
"llm_output" (camelCase leads to HTTP 500 "You must provide a prompt...").
This middleware renames the key before the request reaches the handler.

Loaded by `guardrails start --middleware middleware.py`, which registers any
BaseHTTPMiddleware subclass found in the file. The class overrides __call__ and
works at the raw ASGI level, because BaseHTTPMiddleware.dispatch cannot
reliably replace a request body.
"""

import json

from starlette.middleware.base import BaseHTTPMiddleware

RENAMES = {"llmOutput": "llm_output", "numReasks": "num_reasks", "promptParams": "prompt_params"}


class LiteLLMKeyAdapter(BaseHTTPMiddleware):
    async def __call__(self, scope, receive, send):
        if not (
            scope.get("type") == "http"
            and scope.get("method") == "POST"
            and scope.get("path", "").endswith("/validate")
        ):
            await self.app(scope, receive, send)
            return

        # Read the whole request body.
        chunks = []
        while True:
            message = await receive()
            if message["type"] != "http.request":
                break
            chunks.append(message.get("body", b""))
            if not message.get("more_body", False):
                break
        body = b"".join(chunks)

        try:
            payload = json.loads(body or b"{}")
        except ValueError:
            payload = None
        if isinstance(payload, dict):
            for old, new in RENAMES.items():
                if old in payload and new not in payload:
                    payload[new] = payload.pop(old)
            body = json.dumps(payload).encode()

        headers = [(k, v) for k, v in scope.get("headers", []) if k.lower() != b"content-length"]
        headers.append((b"content-length", str(len(body)).encode()))
        scope = dict(scope, headers=headers)

        sent = False

        async def new_receive():
            nonlocal sent
            if not sent:
                sent = True
                return {"type": "http.request", "body": body, "more_body": False}
            return await receive()

        await self.app(scope, new_receive, send)
