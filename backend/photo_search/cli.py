from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .benchmark import evaluate_benchmark, evaluate_query_expansion, prepare_benchmark
from .config import APP_HOME, DATABASE_PATH, PHOTO_EXPORTER, VISION_OCR
from .db import Database
from .indexer import index_assets
from .native import build_native
from .qwen import QwenClient
from .providers import load_provider
from .search import search
from .sources import import_files, import_library_benchmark_sample, import_photos_selection
from .web import serve
from .worker import load_worker_status, run_full_library_worker
from .network import load_network_status, recover_model_connection


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="photo-search", description="Private photo search pilot")
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("build-native", help="Build the PhotoKit and Vision helpers")
    commands.add_parser("doctor", help="Check local helpers, database, and Qwen API")

    sample = commands.add_parser("sample", help="Import the current selection from Apple Photos")
    sample.add_argument("--limit", type=int, default=12)
    sample.add_argument("--index", action="store_true", help="Run OCR and Qwen after import")

    library_sample = commands.add_parser(
        "sample-library", help="Read a time-spread Photos sample with extra screenshots"
    )
    library_sample.add_argument("--limit", type=int, default=100)
    library_sample.add_argument("--index", action="store_true")

    ingest = commands.add_parser("ingest", help="Import image files or directories")
    ingest.add_argument("paths", nargs="+")
    ingest.add_argument("--limit", type=int)
    ingest.add_argument("--index", action="store_true")

    indexing = commands.add_parser("index", help="Create OCR and Qwen artifacts")
    indexing.add_argument("--limit", type=int)

    searching = commands.add_parser("search", help="Search from the terminal")
    searching.add_argument("query")
    searching.add_argument("--limit", type=int, default=20)
    searching.add_argument("--no-expand", action="store_true")
    searching.add_argument("--json", action="store_true")

    server = commands.add_parser("serve", help="Run the local search page")
    server.add_argument("--host", default="127.0.0.1")
    server.add_argument("--port", type=int, default=8766)

    commands.add_parser("stats", help="Show index counts")
    commands.add_parser("worker-run", help="Resume the unattended full-library worker")
    commands.add_parser("worker-status", help="Show unattended worker progress")
    commands.add_parser("network-recover", help="Repair the active private model connection")
    commands.add_parser("network-status", help="Show model connection recovery status")

    prepare = commands.add_parser("benchmark-prepare", help="Prepare image/text embedding inputs")
    prepare.add_argument("directory")
    prepare.add_argument("--cases", help="JSON file containing benchmark cases")
    prepare.add_argument("--source-kind", help="Limit images to one imported source kind")

    evaluate = commands.add_parser("benchmark-evaluate", help="Import vectors and score retrieval")
    evaluate.add_argument("directory")

    query_expansion = commands.add_parser(
        "benchmark-query-expansion", help="Score the live Qwen query-expansion path"
    )
    query_expansion.add_argument("directory")
    return root


def print_results(payload: dict) -> None:
    print("Terms:", ", ".join(payload["plan"].get("terms", [])))
    for index, item in enumerate(payload["results"], 1):
        print(f"{index:>2}. [{item['asset_type']}] {item['short_caption'] or item['filename']}")
        print(f"    id={item['asset_id']} score={item['score']} matched={', '.join(item['matched_terms'])}")


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        if args.command == "build-native":
            build_native()
            return 0
        if args.command == "doctor":
            provider = load_provider()
            with Database() as db:
                models = QwenClient(provider).models()
                result = {
                    "app_home": str(APP_HOME),
                    "database": str(DATABASE_PATH),
                    "photo_exporter": PHOTO_EXPORTER.exists(),
                    "vision_ocr": VISION_OCR.exists(),
                    "provider_id": provider.id,
                    "provider_name": provider.name,
                    "provider_url": provider.base_url,
                    "provider_model": provider.model,
                    "models": [item.get("id") for item in models.get("data", [])],
                    "stats": db.stats(),
                }
            print(json.dumps(result, ensure_ascii=False, indent=2))
            return 0
        if args.command == "sample":
            with Database() as db:
                count = import_photos_selection(db, args.limit)
                print(f"Imported {count} selected Photos assets")
                if args.index:
                    print(json.dumps(index_assets(db, limit=args.limit), ensure_ascii=False, indent=2))
            return 0
        if args.command == "sample-library":
            with Database() as db:
                count = import_library_benchmark_sample(db, args.limit)
                print(f"Imported {count} benchmark Photos assets")
                if args.index:
                    print(json.dumps(index_assets(db, limit=args.limit), ensure_ascii=False, indent=2))
            return 0
        if args.command == "ingest":
            with Database() as db:
                count = import_files(db, args.paths, args.limit)
                print(f"Imported {count} image files")
                if args.index:
                    print(json.dumps(index_assets(db, limit=args.limit), ensure_ascii=False, indent=2))
            return 0
        if args.command == "index":
            with Database() as db:
                print(json.dumps(index_assets(db, limit=args.limit), ensure_ascii=False, indent=2))
            return 0
        if args.command == "search":
            with Database() as db:
                result = search(db, args.query, limit=args.limit, expand=not args.no_expand)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print_results(result)
            return 0
        if args.command == "serve":
            serve(args.host, args.port)
            return 0
        if args.command == "stats":
            with Database() as db:
                print(json.dumps(db.stats(), indent=2))
            return 0
        if args.command == "worker-run":
            print(json.dumps(run_full_library_worker(), ensure_ascii=False, indent=2))
            return 0
        if args.command == "worker-status":
            print(json.dumps(load_worker_status(), ensure_ascii=False, indent=2))
            return 0
        if args.command == "network-recover":
            print(json.dumps(recover_model_connection(), ensure_ascii=False, indent=2))
            return 0
        if args.command == "network-status":
            print(json.dumps(load_network_status(), ensure_ascii=False, indent=2))
            return 0
        if args.command == "benchmark-prepare":
            cases = None
            if args.cases:
                cases = json.loads(Path(args.cases).read_text(encoding="utf-8"))
            with Database() as db:
                print(
                    json.dumps(
                        prepare_benchmark(
                            db, Path(args.directory), cases=cases,
                            source_kind=args.source_kind,
                        ),
                        ensure_ascii=False,
                        indent=2,
                    )
                )
            return 0
        if args.command == "benchmark-evaluate":
            with Database() as db:
                print(json.dumps(evaluate_benchmark(db, Path(args.directory)), ensure_ascii=False, indent=2))
            return 0
        if args.command == "benchmark-query-expansion":
            with Database() as db:
                print(
                    json.dumps(
                        evaluate_query_expansion(db, Path(args.directory)),
                        ensure_ascii=False,
                        indent=2,
                    )
                )
            return 0
    except Exception as error:
        print(f"photo-search: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
