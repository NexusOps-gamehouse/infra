#!/usr/bin/env bash
set -Eeuo pipefail

STAGE="${1:-smoke}"
RESULT_DIR="${RESULT_DIR:-results}"
mkdir -p "$RESULT_DIR"

case "$STAGE" in
  smoke)
    RATE="${RATE:-5}"
    DURATION="${DURATION:-2m}"
    ;;
  low)
    RATE="${RATE:-20}"
    DURATION="${DURATION:-3m}"
    ;;
  medium)
    RATE="${RATE:-50}"
    DURATION="${DURATION:-5m}"
    ;;
  high)
    RATE="${RATE:-100}"
    DURATION="${DURATION:-5m}"
    ;;
  burst)
    RATE="${RATE:-200}"
    DURATION="${DURATION:-1m}"
    ;;
  *)
    echo "Unknown stage: $STAGE"
    echo "Allowed: smoke | low | medium | high | burst"
    exit 2
    ;;
esac

if [[ -z "${TOKEN:-}" ]]; then
  echo "TOKEN is required"
  exit 2
fi

if [[ -z "${POST_PAYLOAD_JSON:-}" ]]; then
  echo "POST_PAYLOAD_JSON is required"
  echo "Use a JSON body already verified to succeed with POST /api/posts."
  exit 2
fi

ts="$(date '+%Y%m%d-%H%M%S')"
summary="$RESULT_DIR/${ts}-${STAGE}-summary.json"

./timeline.sh "load stage=$STAGE rate=${RATE}req/s duration=$DURATION start"

RATE="$RATE" \
DURATION="$DURATION" \
k6 run \
  --summary-export="$summary" \
  rabbit.js

./timeline.sh "load stage=$STAGE end summary=$summary"
echo "Saved: $summary"
