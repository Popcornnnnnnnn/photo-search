#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
exec /usr/bin/caffeinate -is "$project_dir/.venv/bin/photo-search" worker-run
