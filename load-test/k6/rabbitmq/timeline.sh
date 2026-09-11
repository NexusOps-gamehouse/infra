#!/usr/bin/env bash
set -Eeuo pipefail

RESULT_DIR="${RESULT_DIR:-results}"
mkdir -p "$RESULT_DIR"

message="${*:-}"
if [[ -z "$message" ]]; then
  echo "Usage: ./timeline.sh <message>"
  exit 2
fi

timestamp="$(date '+%H:%M:%S')"
line="[$timestamp] $message"
echo "$line" | tee -a "$RESULT_DIR/timeline.log"
