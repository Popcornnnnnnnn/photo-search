#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
agent_dir="$HOME/Library/LaunchAgents"
app_home="$HOME/Library/Application Support/PhotoSearch"
user_id="$(id -u)"

mkdir -p "$agent_dir" "$app_home/logs"

worker_plist="$agent_dir/com.popcornnn.photo-search.worker.plist"
network_plist="$agent_dir/com.popcornnn.photo-search.network.plist"

/usr/bin/python3 - "$worker_plist" "$network_plist" "$project_dir" "$app_home" <<'PY'
import plistlib
import sys
from pathlib import Path

worker_path, network_path, project, app_home = map(Path, sys.argv[1:])
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
for path, payload in ((worker_path, worker), (network_path, network)):
    with path.open("wb") as handle:
        plistlib.dump(payload, handle, sort_keys=False)
PY

chmod 755 "$project_dir/scripts/run_worker_awake.sh"

# The app starts the visual-search encoder itself; this only tells it where the
# backend environment lives, so a relocated checkout still works.
/usr/bin/python3 - "$app_home/backend.json" "$project_dir" <<'PY'
import json
import sys
from pathlib import Path

path, project = Path(sys.argv[1]), Path(sys.argv[2])
path.write_text(json.dumps(
    {"encoder_command": [str(project / ".venv/bin/photo-search"), "encoder-serve"]},
    indent=2,
) + "\n", encoding="utf-8")
path.chmod(0o600)
PY

# The retired search page is unloaded so an existing install drops it.
for label in com.popcornnn.photo-search.worker com.popcornnn.photo-search.network com.popcornnn.photo-search.web; do
    launchctl bootout "gui/$user_id/$label" 2>/dev/null || true
done
rm -f "$agent_dir/com.popcornnn.photo-search.web.plist"
launchctl bootstrap "gui/$user_id" "$worker_plist"
launchctl bootstrap "gui/$user_id" "$network_plist"
launchctl kickstart -k "gui/$user_id/com.popcornnn.photo-search.network"
launchctl kickstart -k "gui/$user_id/com.popcornnn.photo-search.worker"
