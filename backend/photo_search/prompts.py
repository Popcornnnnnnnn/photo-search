from __future__ import annotations

import json


ANNOTATION_SCHEMA = {
    "asset_type": "photo|chat_screenshot|document|ui_screenshot|poster_or_meme|other",
    "short_caption": "one factual sentence",
    "detailed_description": "compact factual description optimized for later retrieval",
    "entities": ["visible names, products, organizations, places, objects"],
    "actions": ["observable actions"],
    "scene": "setting, environment, weather, or UI context",
    "topics": ["retrieval-oriented topics"],
    "time_clues": ["visible or strongly supported time clues"],
    "location_clues": ["visible or strongly supported location clues"],
    "observed_facts": ["facts directly supported by pixels or OCR"],
    "inferences": ["useful but uncertain interpretations"],
    "uncertainties": ["important missing or ambiguous information"],
    "search_terms": ["concise Chinese or English terms a person might search"],
    "details": {
        "chat": {
            "app": "",
            "visible_participants": [],
            "conversation_type": "private|group|unknown",
            "key_decisions": [],
            "action_items": [],
            "amounts_dates_products": [],
        },
        "document": {
            "document_type": "",
            "issuer": "",
            "dates": [],
            "amounts": [],
            "identifiers": [],
        },
        "ui": {
            "application": "",
            "page_or_feature": "",
            "errors": [],
            "commands_files_technologies": [],
        },
        "photo": {
            "subjects": [],
            "relationships_visible": [],
            "visual_attributes": [],
            "event": "",
        },
    },
}


ANNOTATION_SYSTEM_PROMPT = """You create durable, evidence-grounded metadata for a private photo search system.

Return exactly one JSON object and no markdown. Describe what will help a person find this image months or years later. Separate directly observed facts from inference. Never invent a person's identity, relationship, location, date, or hidden conversation context. OCR text supplied by the caller is evidence but can contain recognition errors.

For natural photos, emphasize subjects, actions, scene, event, weather, visible relationships, distinctive objects, colors, and location clues.
For chat screenshots, emphasize the app, visible participant names, discussion topics, decisions, products, amounts, dates, and action items. Do not transcribe the full conversation because OCR is stored separately.
For documents and receipts, emphasize document type, issuer, date, amount, products, identifiers, and purpose.
For UI or error screenshots, emphasize application, page, user action, errors, commands, files, and technologies.

Use the supplied schema. Keep irrelevant nested detail objects empty rather than fabricating values. Write descriptions primarily in Simplified Chinese while preserving exact visible names, identifiers, commands, and product names."""


def annotation_user_prompt(ocr_text: str, metadata: dict) -> str:
    return (
        "Analyze this image for future personal retrieval.\n\n"
        f"Known metadata:\n{json.dumps(metadata, ensure_ascii=False)}\n\n"
        f"Apple Vision OCR (may contain errors):\n{ocr_text[:16000]}\n\n"
        f"Required JSON shape:\n{json.dumps(ANNOTATION_SCHEMA, ensure_ascii=False)}"
    )


QUERY_SYSTEM_PROMPT = """You expand a personal photo-search query into compact retrieval terms.
Return JSON only with this shape:
{"terms": ["..."], "asset_types": ["..."], "intent": "..."}

Preserve exact names, quoted text, product names, dates, amounts, app names, and error strings. Add only a few close synonyms or concrete concepts that could plausibly occur in OCR or image descriptions. Do not answer the query and do not invent a specific person or date."""


def query_user_prompt(query: str) -> str:
    return f"Expand this photo-search query:\n{query}"
