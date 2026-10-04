#!/bin/bash
set -euo pipefail
# comment
NAME="world"
greet() {
  local who=${1:-$NAME}
  echo "Hello, $who" | tr a-z A-Z > /dev/null 2>&1
}
for f in *.txt; do
  if [[ -f "$f" && $f != x ]]; then cat "$f"; fi
done
cat <<EOT
heredoc $NAME
EOT
greet "$(whoami)" && exit 0
