from __future__ import annotations

import json
import mimetypes
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .db import Database
from .search import search
from .worker import load_worker_status


INDEX_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Photo Search Pilot</title>
<style>
:root { color-scheme: light; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; }
body { margin: 0; background: #f5f5f7; color: #1d1d1f; }
main { max-width: 1080px; margin: 0 auto; padding: 40px 24px 80px; }
h1 { font-size: 32px; margin: 0 0 8px; }
.sub { color: #6e6e73; margin-bottom: 24px; }
.worker { background: white; border-radius: 14px; padding: 14px 16px; margin: 0 0 18px; }
.worker-row { display: flex; justify-content: space-between; gap: 12px; font-size: 13px; }
.bar { height: 7px; border-radius: 999px; background: #e8e8ed; overflow: hidden; margin-top: 10px; }
.bar > div { height: 100%; width: 0; background: #34c759; transition: width .25s ease; }
form { display: flex; gap: 10px; }
input { flex: 1; font-size: 17px; padding: 13px 16px; border: 1px solid #d2d2d7; border-radius: 12px; background: white; }
button { border: 0; border-radius: 12px; padding: 0 20px; background: #0071e3; color: white; font-weight: 600; }
#status { min-height: 22px; margin: 16px 2px; color: #6e6e73; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(230px, 1fr)); gap: 16px; }
.card { background: white; border-radius: 16px; overflow: hidden; box-shadow: 0 1px 2px rgba(0,0,0,.06); }
.card img { width: 100%; height: 210px; object-fit: cover; display: block; background: #eee; }
.body { padding: 14px; }
.type { color: #7c3aed; font-size: 12px; font-weight: 700; text-transform: uppercase; }
.caption { margin: 7px 0; line-height: 1.38; }
.meta, .matches { color: #6e6e73; font-size: 12px; word-break: break-word; }
details { margin-top: 10px; border-top: 1px solid #eee; padding-top: 9px; }
summary { cursor: pointer; color: #0071e3; font-size: 12px; }
pre { white-space: pre-wrap; word-break: break-word; font: 11px/1.4 ui-monospace, monospace; color: #444; }
</style>
</head>
<body><main>
<h1>Photo Search Pilot</h1>
<div class="sub">Private local index · Apple Vision OCR · Qwen annotations</div>
<section class="worker"><div class="worker-row"><strong id="worker-stage">Worker: loading…</strong>
<span id="worker-count"></span></div><div id="worker-message" class="meta"></div>
<div id="worker-rate" class="meta"></div>
<div class="bar"><div id="worker-bar"></div></div></section>
<form id="search"><input id="q" autofocus placeholder="Try: 和张三讨论显卡的聊天截图"><button>Search</button></form>
<div id="status">Ready.</div><div id="results" class="grid"></div>
</main>
<script>
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
async function loadWorkerStatus() {
  try {
    const data = await (await fetch('/api/status')).json();
    const worker = data.worker || {};
    const done = Number(worker.annotated || 0);
    const total = Number(worker.library_images || worker.assets || 0);
    const percent = total ? Math.min(100, Math.round(done * 1000 / total) / 10) : 0;
    document.querySelector('#worker-stage').textContent = `Worker: ${worker.status || 'unknown'} · ${worker.stage || 'idle'}`;
    document.querySelector('#worker-count').textContent = total
      ? `${done} / ${total} (${percent}%)`
      : worker.exported_previews ? `${worker.exported_previews} previews exported` : '';
    const skipped = Number(worker.skipped || 0);
    document.querySelector('#worker-message').textContent = `${worker.message || ''}${skipped ? ` · ${skipped} isolated error(s)` : ''}`;
    const eta = worker.eta_at ? new Date(worker.eta_at).toLocaleString() : '';
    document.querySelector('#worker-rate').textContent = worker.rate_per_hour
      ? `${worker.rate_per_hour} images/hour · ETA ${eta}` : '';
    document.querySelector('#worker-bar').style.width = `${percent}%`;
  } catch (error) {
    document.querySelector('#worker-stage').textContent = 'Worker status unavailable';
  }
}
loadWorkerStatus(); setInterval(loadWorkerStatus, 5000);
document.querySelector('#search').addEventListener('submit', async (event) => {
  event.preventDefault();
  const q = document.querySelector('#q').value.trim();
  if (!q) return;
  const status = document.querySelector('#status');
  const target = document.querySelector('#results');
  status.textContent = 'Searching and expanding the query…'; target.innerHTML = '';
  try {
    const response = await fetch('/api/search?q=' + encodeURIComponent(q));
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Search failed');
    status.textContent = `${data.results.length} result(s) · terms: ${(data.plan.terms || []).join(', ')}`;
    target.innerHTML = data.results.map(item => `<article class="card">
      <img loading="lazy" src="/asset/${encodeURIComponent(item.asset_id)}" alt="">
      <div class="body"><div class="type">${esc(item.asset_type)}</div>
      <div class="caption">${esc(item.short_caption || item.filename)}</div>
      <div class="meta">${esc(item.captured_at || '')}</div>
      <div class="matches">Matched: ${esc((item.matched_terms || []).join(', '))}</div>
      <details><summary>Structured metadata</summary><pre>${esc(JSON.stringify(item.annotation || {}, null, 2))}</pre></details></div>
    </article>`).join('');
  } catch (error) { status.textContent = error.message; }
});
</script></body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "PhotoSearch/0.1"

    def _json(self, value: object, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = INDEX_HTML.encode("utf-8")
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if parsed.path == "/api/status":
            with Database() as db:
                self._json({**db.stats(), "worker": load_worker_status()})
            return
        if parsed.path == "/api/search":
            query = parse_qs(parsed.query).get("q", [""])[0].strip()
            if not query:
                self._json({"error": "Missing q"}, HTTPStatus.BAD_REQUEST)
                return
            try:
                with Database() as db:
                    self._json(search(db, query, limit=30, expand=True))
            except Exception as error:
                self._json({"error": str(error)}, HTTPStatus.INTERNAL_SERVER_ERROR)
            return
        if parsed.path.startswith("/asset/"):
            asset_id = parsed.path.removeprefix("/asset/")
            with Database() as db:
                asset = db.get_asset(asset_id)
            if asset is None:
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            path = Path(asset["thumbnail_path"])
            if not path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND)
                return
            body = path.read_bytes()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "image/jpeg")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_error(HTTPStatus.NOT_FOUND)

    def log_message(self, format: str, *args: object) -> None:
        print(f"web: {format % args}")


def serve(host: str = "127.0.0.1", port: int = 8766) -> None:
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"Photo Search is available at http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
