from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .benchmark import evaluate_benchmark, evaluate_query_expansion, evaluate_search, prepare_benchmark
from .config import APP_HOME, DATABASE_PATH, PHOTO_EXPORTER, VISION_OCR
from .db import Database
from .encoder_server import serve as serve_encoder
from .indexer import index_assets
from .native import build_native, authorize_photos
from .qwen import QwenClient
from .providers import load_provider
from .search import search
from .sources import import_files, import_library_benchmark_sample, import_photos_selection
from .worker import load_worker_status, run_full_library_worker
from .network import load_network_status, recover_model_connection
from .embeddings import index_embeddings


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(prog="photo-search", description="Private photo search pilot")
    commands = root.add_subparsers(dest="command", required=True)

    commands.add_parser("build-native", help="Build the PhotoKit and Vision helpers")
    commands.add_parser("authorize-photos", help="Request Photos access after an explicit user action")
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
    searching.add_argument("--expand", action="store_true", help="Also ask the annotation model to expand query terms")
    searching.add_argument("--lexical-only", action="store_true")
    searching.add_argument("--json", action="store_true")

    embedding = commands.add_parser("index-embeddings", help="Resume a local image-vector batch")
    embedding.add_argument("--limit", type=int, default=100)

    commands.add_parser("encoder-serve", help="Serve query vectors to the app over stdio")
    commands.add_parser("chatgpt", help="Connect a ChatGPT plan account and test image understanding")
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

    live_evaluate = commands.add_parser("benchmark-search", help="Evaluate the production hybrid search against saved cases")
    live_evaluate.add_argument("directory")

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
    arguments = sys.argv[1:] if argv is None else argv
    if arguments and arguments[0] == "chatgpt":
        from .chatgpt_auth import command
        return command(arguments[1:])
    args = parser().parse_args(argv)
    try:
        if args.command == "build-native":
            build_native()
            return 0
        if args.command == "authorize-photos":
            print(json.dumps(authorize_photos()))
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
                result = search(db, args.query, limit=args.limit, expand=args.expand and not args.no_expand, hybrid=not args.lexical_only)
            if args.json:
                print(json.dumps(result, ensure_ascii=False, indent=2))
            else:
                print_results(result)
            return 0
        if args.command == "index-embeddings":
            if args.limit < 1:
                raise ValueError("limit must be positive")
            with Database() as db:
                print(json.dumps(index_embeddings(db, limit=args.limit)))
            return 0
        if args.command == "encoder-serve":
            return serve_encoder()
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
        if args.command == "benchmark-search":
            with Database() as db:
                print(json.dumps(evaluate_search(db, Path(args.directory)), ensure_ascii=False, indent=2))
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
