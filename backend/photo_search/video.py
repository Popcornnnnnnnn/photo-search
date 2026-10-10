"""Whole-video retrieval: sampled visual sequences plus strictly local speech recognition."""
from __future__ import annotations

import json
import math
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
from typing import Any

from .config import APP_HOME
from .native import run_ocr, simplify_chinese

VIDEO_PREPROCESS_VERSION = "video-frames-5s-v1"
VIDEO_PROMPT_VERSION = "whole-video-v1"
SPEECH_MODEL = "whisper-small"
SPEECH_VERSION = "ggml-small-1be3a9b20638-zh-hans-v1"
FRAME_INTERVAL = 5.0
FRAMES_PER_BATCH = 8


def local_tool(name: str) -> str:
    # launchd does not inherit Homebrew's PATH.
    path = shutil.which(name)
    if path:
        return path
    for root in (Path("/opt/homebrew/bin"), Path("/usr/local/bin")):
        candidate = root / name
        if candidate.is_file():
            return str(candidate)
    raise RuntimeError(f"Video indexing requires the local {name} executable")


def run_local(arguments: list[str], *, timeout: float = 300) -> str:
    # whisper.cpp can emit an incomplete UTF-8 token even after a successful run.
    result = subprocess.run(arguments, capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=timeout)
    if result.returncode:
        raise RuntimeError(result.stderr[-2000:] or "Local video processing failed")
    return result.stdout


def probe_video(path: Path) -> dict[str, Any]:
    data = json.loads(run_local([local_tool("ffprobe"), "-v", "error", "-show_format",
                                 "-show_streams", "-of", "json", str(path)]))
    video = next((s for s in data.get("streams", []) if s.get("codec_type") == "video"), None)
    if video is None:
        raise ValueError("No readable video track")
    # Audio can outlast the video track; never sample using that extra tail.
    duration = float(video.get("duration") or data.get("format", {}).get("duration") or 0)
    if not math.isfinite(duration) or duration <= 0:
        raise ValueError("Video duration is unavailable")
    return {"duration": duration, "has_audio": any(s.get("codec_type") == "audio" for s in data["streams"])}


def frame_times(duration: float) -> list[float]:
    end = max(0.0, duration - 0.1)
    times = [i * FRAME_INTERVAL for i in range(max(1, math.ceil(duration / FRAME_INTERVAL)))
             if i * FRAME_INTERVAL <= end]
    if end > times[-1] + 0.1:
        times.append(end)
    return times


def extract_frame(path: Path, timestamp: float, destination: Path) -> float:
    # A track's declared end can still fall after its last decodable frame.
    # Retry slightly earlier only when ffmpeg succeeds without producing a frame.
    candidates = dict.fromkeys(max(0.0, timestamp - offset) for offset in (0, 0.25, 0.5))
    for candidate in candidates:
        destination.unlink(missing_ok=True)
        run_local([local_tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-ss", str(candidate),
                   "-i", str(path), "-frames:v", "1", "-vf",
                   "scale=1280:1280:force_original_aspect_ratio=decrease:out_range=full,format=yuvj420p",
                   "-q:v", "3", str(destination)])
        if destination.is_file() and destination.stat().st_size:
            return candidate
    raise ValueError(f"Unable to decode video frame at {timestamp:.2f}s")


def transcribe_video(path: Path, info: dict[str, Any], directory: Path) -> dict[str, Any]:
    if not info["has_audio"]:
        return {"text": "", "segments": [], "status": "no_audio"}
    model = Path(os.environ.get("PHOTO_SEARCH_WHISPER_MODEL_PATH", APP_HOME / "models/whisper/ggml-small.bin"))
    if not model.is_file():
        raise RuntimeError("Download the local Whisper small model before indexing videos with audio")
    audio = directory / "speech.wav"
    output = directory / "speech"
    # Only local files enter whisper.cpp; no audio request is sent to any provider.
    run_local([local_tool("ffmpeg"), "-nostdin", "-v", "error", "-y", "-i", str(path),
               "-map", "0:a:0", "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(audio)],
              timeout=max(300, info["duration"] * 2))
    run_local([local_tool("whisper-cli"), "-m", str(model), "-f", str(audio), "-l", "auto",
               "-oj", "-of", str(output), "-np"], timeout=max(300, info["duration"] * 10))
    raw = output.with_suffix(".json").read_bytes()
    try:
        decoded = raw.decode("utf-8")
        decode_warning = False
    except UnicodeDecodeError:
        # Retain readable speech; JSON syntax must still validate normally.
        decoded = raw.decode("utf-8", errors="replace")
        decode_warning = True
    data = json.loads(decoded)
    segments = []
    for item in data.get("transcription", []):
        text = item.get("text", "").strip()
        if not text or text in {"[BLANK_AUDIO]", "[SILENCE]", "[Music]", "(music)"}:
            continue
        offsets = item["offsets"]
        segments.append({"start": offsets["from"] / 1000, "end": min(info["duration"], offsets["to"] / 1000), "text": text})
    original = "\n".join(s["text"] for s in segments)
    normalized = json.loads(simplify_chinese(json.dumps({"text": original, "segments": segments}, ensure_ascii=False)))
    return {**normalized, "original_text": original,
            "language": data.get("result", {}).get("language"),
            **({"decode_warning": "Whisper emitted malformed UTF-8; unreadable characters were replaced."}
               if decode_warning else {}),
            "status": "transcribed" if segments else "no_speech"}


def index_video(db, asset, client, provider, progress) -> dict[str, Any]:
    """Persist reusable stages in the existing artifact store, then one final annotation."""
    path = Path(asset["file_path"])
    metadata = json.loads(asset["metadata_json"])
    info = probe_video(path)
    times = frame_times(info["duration"])
    asset_id = asset["id"]
    digest = asset["sha256"]
    with tempfile.TemporaryDirectory(prefix="photo-search-video-") as temporary:
        directory = Path(temporary)
        os.chmod(directory, 0o700)
        speech = db.active_artifact(asset_id, "transcript")
        if not speech or speech["prompt_version"] != SPEECH_VERSION:
            progress(f"  Local speech recognition: {asset['filename']}")
            transcript = transcribe_video(path, info, directory)
            db.add_artifact(asset_id=asset_id, kind="transcript", producer="whisper.cpp", model=SPEECH_MODEL,
                            prompt_version=SPEECH_VERSION, schema_version="1.0", preprocess_version=VIDEO_PREPROCESS_VERSION,
                            input_sha256=digest, data=transcript, raw_text=transcript["text"])
        else:
            transcript = speech["data"]
        # Checkpoint each group so scheduled runs can resume a long video.
        saved = db.active_artifact(asset_id, "video-scenes")
        compatible = saved and saved["producer"] == provider.producer and saved["model"] == provider.model \
            and saved["prompt_version"] == VIDEO_PROMPT_VERSION and saved["preprocess_version"] == VIDEO_PREPROCESS_VERSION
        chunks = saved["data"]["chunks"] if compatible else []
        for offset in range(len(chunks) * FRAMES_PER_BATCH, len(times), FRAMES_PER_BATCH):
            batch = times[offset:offset + FRAMES_PER_BATCH]
            start = batch[0]
            end = times[offset + FRAMES_PER_BATCH] if offset + FRAMES_PER_BATCH < len(times) else info["duration"]
            frames = []
            frame_texts = []
            for index, timestamp in enumerate(batch):
                frame = directory / f"frame-{index}.jpg"
                decoded_at = extract_frame(path, timestamp, frame)
                frames.append((decoded_at, frame))
                text = run_ocr(frame).get("text", "")
                if text:
                    frame_texts.append(f"{decoded_at:.2f}s: {text}")
            spoken = "\n".join(s["text"] for s in transcript["segments"] if s["start"] < end and s["end"] > start)
            progress(f"  Video visuals: {end:.0f}/{info['duration']:.0f}s")
            annotation, _ = client.annotate_video_frames(frames, spoken, "\n".join(frame_texts),
                                                         {"start": start, "end": end, "duration": info["duration"]})
            chunks.append({"start": start, "end": end, "annotation": annotation, "ocr": "\n".join(frame_texts)})
            db.add_artifact(asset_id=asset_id, kind="video-scenes", producer=provider.producer, model=provider.model,
                            prompt_version=VIDEO_PROMPT_VERSION, schema_version="1.0", preprocess_version=VIDEO_PREPROCESS_VERSION,
                            input_sha256=digest, data={"chunks": chunks, "frame_interval": FRAME_INTERVAL})
        # Bound each summarization request while retaining every group's evidence.
        summaries = [c["annotation"] for c in chunks]
        while len(summaries) > 8:
            summaries = [client.summarize_video(summaries[i:i + 8], {"partial": True})[0]
                         for i in range(0, len(summaries), 8)]
        metadata.update(duration=info["duration"], filename=asset["filename"], captured_at=asset["captured_at"],
                        frame_interval=FRAME_INTERVAL, transcript_status=transcript["status"])
        annotation, raw = client.summarize_video(summaries, metadata)
        annotation["asset_type"] = "video"
        annotation["duration_seconds"] = info["duration"]
        annotation["transcript_status"] = transcript["status"]
        db.add_artifact(asset_id=asset_id, kind="annotation", producer=provider.producer, model=provider.model,
                        prompt_version=VIDEO_PROMPT_VERSION, schema_version="1.0", preprocess_version=VIDEO_PREPROCESS_VERSION,
                        input_sha256=digest, data=annotation, raw_text=raw)
    db.rebuild_search_doc(asset_id)
    return annotation
