from __future__ import annotations

import base64
import json
import mimetypes
import re
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

from .prompts import (
    ANNOTATION_SYSTEM_PROMPT,
    QUERY_SYSTEM_PROMPT,
    annotation_user_prompt,
    query_user_prompt,
)
from .providers import ModelProvider, load_provider


class ModelProviderError(RuntimeError):
    pass


QwenError = ModelProviderError


def extract_json(text: str) -> dict[str, Any]:
    value = text.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value)
        value = re.sub(r"\s*```$", "", value)
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        start = value.find("{")
        end = value.rfind("}")
        if start < 0 or end <= start:
            raise ModelProviderError("model response did not contain a JSON object")
        try:
            parsed = json.loads(value[start : end + 1])
        except json.JSONDecodeError as nested_error:
            raise ModelProviderError("model response contained malformed JSON") from nested_error
    if not isinstance(parsed, dict):
        raise ModelProviderError("model JSON response was not an object")
    return parsed


class QwenClient:
    def __init__(self, provider: ModelProvider | None = None):
        self.provider = provider or load_provider()
        self.base_url = self.provider.base_url
        self.model = self.provider.model

    def _post(self, path: str, payload: dict[str, Any], timeout: int = 180) -> dict[str, Any]:
        headers = {"Content-Type": "application/json"}
        if self.provider.api_key:
            headers["Authorization"] = f"Bearer {self.provider.api_key}"
        request = urllib.request.Request(
            f"{self.base_url}{path}",
            data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8")
        except (urllib.error.URLError, TimeoutError) as error:
            raise ModelProviderError(f"Model API request failed: {error}") from error
        try:
            result = json.loads(body)
        except json.JSONDecodeError as error:
            raise ModelProviderError(f"Model API returned invalid JSON: {body[:500]}") from error
        if "error" in result:
            raise ModelProviderError(f"Model API error: {result['error']}")
        return result

    def models(self) -> dict[str, Any]:
        try:
            headers: dict[str, str] = {}
            if self.provider.api_key:
                headers["Authorization"] = f"Bearer {self.provider.api_key}"
            request = urllib.request.Request(f"{self.base_url}/models", headers=headers)
            with urllib.request.urlopen(request, timeout=8) as response:
                return json.loads(response.read().decode("utf-8"))
        except Exception as error:
            raise ModelProviderError(f"Model API unavailable at {self.base_url}: {error}") from error

    def annotate(self, image_path: Path, ocr_text: str, metadata: dict[str, Any]) -> tuple[dict[str, Any], str]:
        mime = mimetypes.guess_type(image_path.name)[0] or "image/jpeg"
        image_data = base64.b64encode(image_path.read_bytes()).decode("ascii")
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": ANNOTATION_SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": annotation_user_prompt(ocr_text, metadata)},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:{mime};base64,{image_data}"},
                        },
                    ],
                },
            ],
            "temperature": 0.1,
            "max_tokens": 2200,
        }
        if self.provider.json_mode:
            payload["response_format"] = {"type": "json_object"}
        if self.provider.qwen_thinking_control:
            payload["chat_template_kwargs"] = {"enable_thinking": False}
        result = self._post("/chat/completions", payload, timeout=300)
        message = result["choices"][0]["message"]
        content = message.get("content") or ""
        if not content:
            raise ModelProviderError("Model provider returned no annotation content")
        return extract_json(content), content

    def expand_query(self, query: str) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": QUERY_SYSTEM_PROMPT},
                {"role": "user", "content": query_user_prompt(query)},
            ],
            "temperature": 0,
            "max_tokens": 512,
        }
        if self.provider.json_mode:
            payload["response_format"] = {"type": "json_object"}
        if self.provider.qwen_thinking_control:
            payload["chat_template_kwargs"] = {"enable_thinking": False}
        result = self._post("/chat/completions", payload, timeout=90)
        content = result["choices"][0]["message"].get("content") or ""
        parsed = extract_json(content)
        terms = parsed.get("terms")
        if not isinstance(terms, list):
            parsed["terms"] = []
        return parsed
