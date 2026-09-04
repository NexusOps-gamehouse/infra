#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIO="${1:-}"

usage() {
  cat >&2 <<'EOF'
사용법: ./load-test/k6/local/run-local.sh <smoke|core-read|house-read|notification-read>

필수 환경변수:
  TEST_EMAIL       기존 로컬 테스트 계정 이메일
  TEST_PASSWORD    기존 로컬 테스트 계정 비밀번호

선택 환경변수:
  BASE_URL         기본값 http://localhost:8080
  CREW_BASE_URL    기본값 http://localhost:8086
  TEST_HOUSE_ID    승인 멤버인 House ID (공지/일정/채팅 조회에 필요)
  TEST_POST_ID     조회할 모집글 ID (없으면 목록 첫 항목)
EOF
  exit 2
}

case "${SCENARIO}" in
  smoke|core-read|house-read|notification-read) ;;
  *) usage ;;
esac

command -v k6 >/dev/null 2>&1 || {
  echo 'k6가 설치되어 있지 않습니다. macOS: brew install k6' >&2
  exit 1
}

BASE_URL="${BASE_URL:-http://localhost:8080}"
CREW_BASE_URL="${CREW_BASE_URL:-http://localhost:8086}"
export BASE_URL CREW_BASE_URL
for target in "${BASE_URL}" "${CREW_BASE_URL}"; do
  case "${target}" in
    http://localhost:*|https://localhost:*|http://127.0.0.1:*|https://127.0.0.1:*) ;;
    *)
      if [[ "${K6_ALLOW_REMOTE:-0}" != '1' ]]; then
        echo "원격 대상이 차단되었습니다: ${target}" >&2
        echo '로컬 부하테스트만 허용합니다. 명시적 승인 시에만 K6_ALLOW_REMOTE=1을 사용하세요.' >&2
        exit 1
      fi
      echo "경고: 원격 대상에 실행합니다: ${target}" >&2
      ;;
  esac
done

[[ -n "${TEST_EMAIL:-}" ]] || { echo 'TEST_EMAIL이 필요합니다.' >&2; exit 1; }
[[ -n "${TEST_PASSWORD:-}" ]] || { echo 'TEST_PASSWORD가 필요합니다.' >&2; exit 1; }

echo "시나리오: ${SCENARIO}"
echo "Main backend: ${BASE_URL}"
echo "Crew service: ${CREW_BASE_URL}"
echo '자격증명과 JWT는 출력하지 않습니다.'

exec k6 run "${SCRIPT_DIR}/scenarios/${SCENARIO}.js"
