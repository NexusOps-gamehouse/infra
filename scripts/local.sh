#!/usr/bin/env bash
#
# 로컬 개발용 docker compose 래퍼.
#
#   ./scripts/local.sh up -d --build rabbitmq
#   ./scripts/local.sh ps
#   ./scripts/local.sh logs -f rabbitmq
#   ./scripts/local.sh down
#
# 매번 세 가지를 빠뜨리지 않으려고 감쌌다.
#
#  1) --env-file .env.local
#     compose 는 변수 치환에 기본으로 .env 를 읽는다. 그런데 .env 에는
#     DB_HOST / DB_PORT 가 없어서 backend 의 DB_URL 조립이 깨진다.
#     .env.local 이 로컬에 필요한 값을 모두 갖고 있다.
#     ⚠️ 이 경로는 compose 파일 안에서 지정할 수 없다. 반드시 플래그여야 한다.
#
#  2) -f docker-compose.local.yml
#     rabbitmq 의 5672(서비스 간 이벤트) · 61613(채팅) 포트를 호스트에 여는 설정이
#     여기에만 있다. 기본 compose 에는 없다 — 컨테이너끼리만 통신하던 시절 설정이라
#     포트를 열 이유가 없었다. 백엔드를 IDE 에서 띄우는 지금은 필요하다.
#
#  3) 실행 위치
#     compose 의 프로젝트 디렉터리는 첫 -f 파일이 있는 곳으로 잡힌다.
#     어디서 실행하든 infra/ 를 기준으로 맞춘다.
#
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -f .env.local ]]; then
  echo "infra/.env.local 이 없습니다. .env.example 을 복사해 채우세요:" >&2
  echo "  cp .env.example .env.local" >&2
  exit 1
fi

exec docker compose \
  --env-file .env.local \
  -f docker-compose.yml \
  -f docker-compose.local.yml \
  "$@"
