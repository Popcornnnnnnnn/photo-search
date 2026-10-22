"""Responses image understanding using only Photo Search's OAuth grant."""
from __future__ import annotations

import base64
import json
import struct
import time
import urllib.error
import urllib.request
import zlib

from .chatgpt_auth import ChatGPTError, RESOURCE, access_token, api_error, list_models, open_request, safe_code


def response_text(lines):
    """Parse SSE frames, requiring a completed terminal response, never a partial delta."""
    data = []
    total = 0
    text_parts = {}
    started = time.monotonic()
    for raw in lines:
        total += len(raw)
        if total > 8_000_000 or time.monotonic() - started > 600:
            raise ChatGPTError("ChatGPT response exceeded the request limit.")
        line = raw.decode("utf-8").rstrip("\r\n")
        if line.startswith("data:"):
            data.append(line[5:].lstrip())
        elif not line and data:
            value = "\n".join(data)
            data = []
            if value == "[DONE]":
                break
            try:
                event = json.loads(value)
            except ValueError:
                raise ChatGPTError("ChatGPT returned an invalid response stream.") from None
            kind = event.get("type")
            if kind in ("response.output_text.delta", "response.output_text.done"):
                key = (event.get("output_index", 0), event.get("content_index", 0))
                if kind.endswith(".done"):
                    text_parts[key] = event.get("text", "")
                else:
                    text_parts[key] = text_parts.get(key, "") + event.get("delta", "")
            if kind in ("error", "response.failed", "response.incomplete"):
                error = event.get("response", {}).get("error") or event.get("error") or event
                code = safe_code(error.get("code") if isinstance(error, dict) else None)
                raise ChatGPTError(f"ChatGPT inference did not complete ({code}).")
            if kind == "response.completed":
                response = event.get("response", {})
                if response.get("status") != "completed":
                    raise ChatGPTError("ChatGPT returned an incomplete response.")
                text = "".join(part.get("text", "") for item in response.get("output", [])
                               if item.get("type") == "message" for part in item.get("content", [])
                               if part.get("type") == "output_text")
                # Plan streams can omit output from the completed envelope.
                # Read text events, but release them only after terminal success.
                if not text:
                    text = "".join(text_parts[key] for key in sorted(text_parts))
                if not text:
                    raise ChatGPTError("ChatGPT completed without image-understanding text.")
                usage = response.get("usage") or {}
                return text, {k: usage[k] for k in ("input_tokens", "output_tokens", "total_tokens") if k in usage}
    raise ChatGPTError("ChatGPT connection ended before response.completed.")


class ChatGPTClient:
    def __init__(self, provider):
        if provider.base_url != RESOURCE or not provider.chatgpt_account_id:
            raise ChatGPTError("ChatGPT requires its official endpoint and a connected account.")
        self.provider = provider
        self.last_usage = {}

    def models(self):
        return {"data": list_models(self.provider.chatgpt_account_id)}

    def complete(self, system, content):
        converted = []
        for part in content:
            if part["type"] == "text":
                converted.append({"type": "input_text", "text": part["text"]})
            elif part["type"] == "image_url":
                converted.append({"type": "input_image", "image_url": part["image_url"]["url"]})
            else:
                raise ChatGPTError("Unsupported ChatGPT image input.")
        payload = {"model": self.provider.model, "instructions": system,
                   "input": [{"role": "user", "content": converted}], "store": False, "stream": True}
        request = urllib.request.Request(RESOURCE + "/responses", data=json.dumps(payload).encode(),
                     headers={"Authorization": "Bearer " + access_token(self.provider.chatgpt_account_id),
                              "Content-Type": "application/json", "Accept": "text/event-stream"})
        try:
            with open_request(request, timeout=300) as response:
                text, self.last_usage = response_text(response)
                return text
        except urllib.error.HTTPError as error:
            raise api_error(error) from None
        except OSError:
            raise ChatGPTError("ChatGPT inference connection failed. No completed result was saved.") from None


def test_image(account, model):
    # A synthetic PNG, no Photos access and no personal image upload.
    from .providers import ModelProvider
    from .qwen import extract_json
    if not model or model not in [m["id"] for m in list_models(account)]:
        raise ChatGPTError("Select a model available to this ChatGPT account.")
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    pixels = b"".join(b"\x00" + b"\xff\x00\x00" * 64 for _ in range(64))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">2I5B", 64, 64, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    provider = ModelProvider(id="chatgpt-plan", name="ChatGPT", kind="chatgpt", base_url=RESOURCE,
                             model=model, producer="chatgpt-plan", chatgpt_account_id=account)
    client = ChatGPTClient(provider)
    answer = client.complete('Return JSON with one key "color": the lowercase English name of the dominant image color.',
                [{"type": "image_url", "image_url": {"url": "data:image/png;base64," + base64.b64encode(png).decode()}},
                 {"type": "text", "text": "Identify the dominant color in this test image."}])
    if extract_json(answer).get("color", "").lower() != "red":
        raise ChatGPTError("ChatGPT completed but did not correctly identify the test image.")
    return {"event": "tested", "model": model, "image_understanding": True, "color": "red", "usage": client.last_usage}
