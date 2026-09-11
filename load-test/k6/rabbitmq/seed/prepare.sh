#!/usr/bin/env bash
# ===========================================================================
# RabbitMQ 회차 전용 계정·JWT 준비
#
# 공용 load-test/seed/generate.sh 를 쓰지 않는다. 그쪽은 여러 회차가 함께
# 쓰는 데이터를 초기화하므로, RabbitMQ 회차가 돌리면 다른 팀 회차의 기준선이
# 사라진다. 여기서 만드는 계정은 이 회차만 쓴다.
#
# 산출물 (전부 seed/data/ 안에만 쓴다)
#   users.json   생성한 계정
#   tokens.json  발급한 JWT   ← rabbit.js 가 읽는다
#   meta.json    회차 ID · 제목 접두사 · 대상 주소
#
#   ./seed/prepare.sh
#   USERS=5 ./seed/prepare.sh
#
# 멱등하다. 이미 있는 계정은 로그인만 해서 토큰을 새로 받는다.
#
# ⚠️ 로컬 kind 전용이다. 계정과 글을 실제로 만들기 때문에 BASE_URL 이
#    로컬이 아니면 중단한다.
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

BASE_URL="${BASE_URL:-http://gamehouse.local}"
USERS="${USERS:-3}"
PREFIX="${RMQ_USER_PREFIX:-rmq}"
DOMAIN="${RMQ_USER_DOMAIN:-kind.local}"
PASSWORD="${RMQ_USER_PASSWORD:-RmqTest!234}"
TITLE_PREFIX="${RMQ_TITLE_PREFIX:-[RMQ-TEST]}"

# --- 안전장치 -------------------------------------------------------------
case "$BASE_URL" in
  http://gamehouse.local|http://gamehouse.local:*|http://localhost:*|http://127.0.0.1:*) ;;
  *)
    echo "중단: BASE_URL 이 로컬이 아니다 ($BASE_URL)" >&2
    echo "이 스크립트는 계정을 실제로 생성한다. 로컬 kind 에서만 쓴다." >&2
    exit 2
    ;;
esac

for c in curl jq; do
  command -v "$c" >/dev/null || { echo "$c 가 필요하다" >&2; exit 2; }
done

# curl 실패로 스크립트가 통째로 죽지 않게 감싼다. 계정 하나가 실패해도
# 나머지는 계속 만들어야 한다.
http()      { curl -s  --max-time 30 "$@" || true; }
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" || echo "000"; }

mkdir -p "$DATA_DIR"

ROUND_ID="${RMQ_ROUND_ID:-RMQ-$(date '+%Y%m%d-%H%M')}"

echo "대상      : $BASE_URL"
echo "회차 ID   : $ROUND_ID"
echo "계정 목표 : $USERS"
echo

# --- 0. 연결 확인 ---------------------------------------------------------
probe=$(http_code "$BASE_URL/api/posts?page=0&size=1")
case "$probe" in
  200|401|403) ;;
  *)
    echo "중단: $BASE_URL 에 닿지 않는다 (HTTP $probe)" >&2
    echo "  · kubectl -n gamehouse get ingress" >&2
    echo "  · /etc/hosts 에 '127.0.0.1 gamehouse.local' 이 있는지" >&2
    exit 2
    ;;
esac

# --- 1. 계정과 토큰 -------------------------------------------------------
users_json='[]'
tokens_json='[]'
created=0; reused=0; failed=0

for i in $(seq 1 "$USERS"); do
  email="${PREFIX}${i}@${DOMAIN}"
  nick="${PREFIX}${i}"

  signup=$(jq -nc \
    --arg email "$email" --arg password "$PASSWORD" \
    --arg name "$nick" --arg nickname "$nick" \
    '{email:$email, password:$password, name:$name, nickname:$nickname,
      phone:"01000000000", mic:true, age:25,
      playTimes:"저녁", playDays:"평일", playDuration:"2~4시간"}')

  # signup 은 서비스 버전에 따라 JSON 만 받거나 multipart 만 받는다.
  #   gamehouse-user : JSON · multipart 둘 다
  #   backend/user   : multipart 만
  # 로컬 이미지가 어느 쪽에서 빌드됐는지에 따라 갈리므로 둘 다 시도한다.
  code=$(http_code -X POST "$BASE_URL/api/auth/signup" \
    -H 'Content-Type: application/json' -d "$signup")
  if [ "$code" = "415" ]; then
    code=$(http_code -X POST "$BASE_URL/api/auth/signup" \
      -F "email=$email" -F "password=$PASSWORD" \
      -F "name=$nick" -F "nickname=$nick" \
      -F "phone=01000000000" -F "mic=true" -F "age=25" \
      -F "playTimes=저녁" -F "playDays=평일" -F "playDuration=2~4시간")
  fi

  login=$(jq -nc --arg email "$email" --arg password "$PASSWORD" \
    '{email:$email, password:$password}')
  token=$(http -X POST "$BASE_URL/api/auth/login" \
    -H 'Content-Type: application/json' -d "$login" \
    | jq -r '.token // empty' 2>/dev/null || true)

  if [ -z "$token" ]; then
    echo "  경고: $email 토큰 발급 실패 (signup HTTP $code)" >&2
    failed=$((failed + 1))
    continue
  fi

  case "$code" in
    200|201) created=$((created + 1)) ;;
    *)       reused=$((reused + 1)) ;;
  esac

  users_json=$(jq -c --arg e "$email" --arg p "$PASSWORD" --arg n "$nick" \
    '. + [{email:$e, password:$p, nickname:$n}]' <<<"$users_json")
  tokens_json=$(jq -c --arg e "$email" --arg t "$token" \
    '. + [{email:$e, token:$t}]' <<<"$tokens_json")
done

count=$(jq 'length' <<<"$tokens_json")
if [ "$count" -eq 0 ]; then
  echo "중단: 토큰을 받은 계정이 하나도 없다." >&2
  echo "  kubectl -n gamehouse get pods 로 user 가 Ready 인지 확인한다." >&2
  exit 1
fi

# --- 2. 저장 -------------------------------------------------------------
jq . <<<"$users_json"  > "$DATA_DIR/users.json"
jq . <<<"$tokens_json" > "$DATA_DIR/tokens.json"
jq -n \
  --arg roundId "$ROUND_ID" \
  --arg baseUrl "$BASE_URL" \
  --arg titlePrefix "$TITLE_PREFIX" \
  --argjson users "$count" \
  --arg createdAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  '{roundId:$roundId, baseUrl:$baseUrl, titlePrefix:$titlePrefix,
    users:$users, createdAt:$createdAt}' > "$DATA_DIR/meta.json"

echo "계정      : 신규 $created · 재사용 $reused · 실패 $failed · 사용 $count"
echo
echo "산출물    : $DATA_DIR"
jq -r '"  회차 ID   : \(.roundId)\n  제목 접두사: \(.titlePrefix)"' "$DATA_DIR/meta.json"
echo
echo "다음: ./preflight.sh 로 실행 조건을 확인한다."
