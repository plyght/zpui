#!/usr/bin/env bash
# zig build zeron, printing only compiler errors.
cd "$(dirname "$0")/../../.." && zig build zeron "$@" 2>&1 | grep -E "^[^ ].*error:|note:" -A2 | grep -v "failed command" | head -40
