#!/bin/zsh
set -euo pipefail
# Install local video decoding / speech recognition, then fetch a pinned model.
brew install ffmpeg whisper-cpp
project_dir=${0:A:h:h}
"$project_dir/.venv/bin/python" - <<'PY'
import hashlib
import os
import urllib.request
from photo_search.config import APP_HOME

model = APP_HOME / 'models/whisper/ggml-small.bin'
expected = '1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b'
model.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
if model.is_file():
    with model.open('rb') as handle:
        if hashlib.file_digest(handle, 'sha256').hexdigest() == expected:
            print('Local Whisper small model is ready.')
            raise SystemExit(0)
temporary = model.with_suffix('.download')
try:
    urllib.request.urlretrieve(
        'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small.bin',
        temporary,
    )
    with temporary.open('rb') as handle:
        if hashlib.file_digest(handle, 'sha256').hexdigest() != expected:
            raise RuntimeError('Whisper model checksum mismatch')
    temporary.replace(model)
    os.chmod(model, 0o600)
finally:
    temporary.unlink(missing_ok=True)
print('Local Whisper small model is ready.')
PY
