#!/usr/bin/env bash
# ===========================================================================
# 테스트 데이터 전량 삭제 — 부하 테스트를 끝내고 로컬을 원래대로 돌릴 때.
#
# generate.sh 는 00-reset 을 돌린 뒤 곧바로 다시 시딩한다. 이 스크립트는
# 지우기만 한다.
#
# 지우는 것
#   · DB    : @test.local 계정과 거기 딸린 글·신청·알림·채팅 (00-reset.sql)
#   · 파일  : seed/data/*.json
#
# ⚠️ 파일을 같이 지우는 이유
#    DB 만 비우고 JSON 을 남기면, post-ids.json 이 존재하지 않는 PK 를
#    가리키는 상태가 된다. 그 상태로 회차를 돌리면 시나리오 2·4 가 전부
#    404 를 받는데, 4xx 는 실패로 세지 않으므로 회차는 끝까지 정상으로
#    돌고 결과만 무의미해진다. 조용히 틀리는 것이 가장 나쁘다.
#
#    평문 비밀번호 600개와 24시간짜리 JWT 가 들어 있으므로, 안 쓸 거면
#    남겨둘 이유도 없다.
#
# 실제 개발 데이터는 건드리지 않는다 — 00-reset.sql 이 삭제 범위를
# '%@test.local' 로 한정한다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
DATA_DIR="${SCRIPT_DIR}/data"

# shellcheck source=../db.sh
source "${SCRIPT_DIR}/../db.sh"
lt_guard_target

echo "대상: $(lt_db_label)"

# 00-reset.sql 이 실제로 지우는 것을 전부 센다.
# 계정과 글만 찍으면 "신청은 남는 건가?" 하고 다시 확인하게 된다.
# 지운 것을 안 보여주면 지웠는지 알 수 없다.
read -r ACCOUNTS POSTS APPS NOTIS <<<"$(psql_exec -c "
  WITH u AS (SELECT id FROM users WHERE email LIKE '%@test.local'),
       p AS (SELECT id FROM posts WHERE author_id IN (SELECT id FROM u))
  SELECT (SELECT count(*) FROM u) || ' '
      || (SELECT count(*) FROM p) || ' '
      || (SELECT count(*) FROM applications
           WHERE post_id IN (SELECT id FROM p)
              OR applicant_id IN (SELECT id FROM u)) || ' '
      || (SELECT count(*) FROM notifications WHERE user_id IN (SELECT id FROM u));
")"

echo "삭제 대상: 계정 ${ACCOUNTS} · 글 ${POSTS} · 신청 ${APPS} · 알림 ${NOTIS}"

if (( ACCOUNTS == 0 && POSTS == 0 && APPS == 0 && NOTIS == 0 )); then
  echo "이미 비어 있다."
else
  psql_exec -f "${SQL_DIR}/00-reset.sql" >/dev/null
  echo "DB 삭제 완료 (채팅방·친구·챔피언숙련도까지 함께)"
fi

if [[ -d "${DATA_DIR}" ]]; then
  rm -f "${DATA_DIR}"/*.json
  rmdir "${DATA_DIR}" 2>/dev/null || true
  echo "seed/data/ 삭제 완료"
fi

echo ""
echo "남은 상태 (테스트 데이터 / 전체)"
psql_exec -c "
  SELECT '  계정 ' || (SELECT count(*) FROM users WHERE email LIKE '%@test.local')
              || ' / ' || (SELECT count(*) FROM users)
      || E'\n  글   ' || (SELECT count(*) FROM posts WHERE title LIKE '[SEED]%' OR title LIKE '[LT]%')
              || ' / ' || (SELECT count(*) FROM posts)
      || E'\n  신청 ' || (SELECT count(*) FROM applications
                           WHERE applicant_id IN (SELECT id FROM users WHERE email LIKE '%@test.local'))
              || ' / ' || (SELECT count(*) FROM applications)
      || E'\n  알림 ' || (SELECT count(*) FROM notifications
                           WHERE user_id IN (SELECT id FROM users WHERE email LIKE '%@test.local'))
              || ' / ' || (SELECT count(*) FROM notifications);
"
echo ""
echo "  왼쪽이 0 이면 정리 완료다. 오른쪽은 실제 개발 데이터라 건드리지 않는다."
echo ""
echo "다시 시딩하려면: ./seed/generate.sh"
