#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
agent_dir="$HOME/Library/LaunchAgents"
app_home="$HOME/Library/Application Support/PhotoSearch"
user_id="$(id -u)"

mkdir -p "$agent_dir" "$app_home/logs"

worker_plist="$agent_dir/com.popcornnn.photo-search.worker.plist"
network_plist="$agent_dir/com.popcornnn.photo-search.network.plist"
web_plist="$agent_dir/com.popcornnn.photo-search.web.plist"

/usr/bin/python3 - "$worker_plist" "$network_plist" "$web_plist" "$project_dir" "$app_home" <<'PY'
import plistlib
import sys
from pathlib import Path

worker_path, network_path, web_path, project, app_home = map(Path, sys.argv[1:])
common = {
    "ProcessType": "Background",
    "LowPriorityIO": True,
    "EnvironmentVariables": {"PYTHONUNBUFFERED": "1"},
}
worker = {
    **common,
    "Label": "com.popcornnn.photo-search.worker",
    "ProgramArguments": [str(project / "scripts/run_worker_awake.sh")],
    "RunAtLoad": True,
    "StartInterval": 60,
    "StandardOutPath": str(app_home / "logs/worker.log"),
    "StandardErrorPath": str(app_home / "logs/worker-error.log"),
}
network = {
    **common,
    "Label": "com.popcornnn.photo-search.network",
    "ProgramArguments": [str(project / ".venv/bin/photo-search"), "network-recover"],
    "RunAtLoad": True,
    "StartInterval": 60,
    "StandardOutPath": str(app_home / "logs/network.log"),
    "StandardErrorPath": str(app_home / "logs/network-error.log"),
}
web = {
    **common,
    "Label": "com.popcornnn.photo-search.web",
    "ProgramArguments": [
        str(project / ".venv/bin/photo-search"), "serve",
        "--host", "127.0.0.1", "--port", "8766",
    ],
    "RunAtLoad": True,
    "KeepAlive": True,
    "StandardOutPath": str(app_home / "logs/web.log"),
    "StandardErrorPath": str(app_home / "logs/web-error.log"),
}
for path, payload in ((worker_path, worker), (network_path, network), (web_path, web)):
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)
PY

chmod 755 "$project_dir/scripts/run_worker_awake.sh"
for label in com.popcornnn.photo-search.worker com.popcornnn.photo-search.network com.popcornnn.photo-search.web; do
    launchctl bootout "gui/$user_id/$label" 2>/dev/null || true
done
launchctl bootstrap "gui/$user_id" "$worker_plist"
launchctl bootstrap "gui/$user_id" "$network_plist"
launchctl bootstrap "gui/$user_id" "$web_plist"
launchctl kickstart -k "gui/$user_id/com.popcornnn.photo-search.network"
launchctl kickstart -k "gui/$user_id/com.popcornnn.photo-search.worker"
