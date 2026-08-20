#!/usr/bin/env bash
# ===========================================================================
# 정상 상태 유지 — 회차 '중에' 계속 돌린다.
#
# 왜 필요한가
#
# ⚠️ 2026-08-18 에 이유가 바뀌었다. 목록에 페이징이 들어오면서 예전 근거는
#    사라졌는데, 그것을 대신할 더 미묘한 이유가 생겼다. "페이징 됐으니 이제
#    필요 없다" 고 끄면 회차가 조용히 오염된다.
#
#   [예전 이유 — 지금은 해당 없음]
#     GET /api/posts 가 전건을 돌려주던 시절, 시나리오 5 가 Peak 에서 6 RPS 로
#     글을 만들면 15분에 약 5,400건이 쌓여 목록이 300 → 5,700 건으로 19배가 됐다.
#     응답이 300KB → 5MB 로 불어나므로 p95 상승이 부하 탓인지 데이터 탓인지
#     구분할 수 없었다. 지금은 몇 건이 있든 한 페이지(20건)만 나가므로 이 일은
#     일어나지 않는다(회차 D 실측: 게시글 10,000건에서도 응답 0.015MB 고정).
#
#   [지금 이유 — 첫 페이지에 '무엇이' 담기는가]
#     목록은 ORDER BY createdAt DESC 이고 첫 페이지는 20건이다. 시나리오 5 가
#     초당 6개씩 글을 만드니 약 3초면 첫 페이지가 통째로 신규 글로 교체된다.
#
#     그런데 그 신규 글은 전부 '빈 글' 이다. 시나리오 4(참가 신청)는
#     seedPostId() 로 시딩 글에만 신청하므로, 회차 중 만들어진 글에는 신청도
#     채팅방도 영영 안 붙는다.
#
#       [SEED] 글 300건   신청 평균 3건 · 채팅방 있음  → extras() 가 실제로 행을 찾는다
#       런타임 생성 글    신청 0건 · 채팅방 없음       → 전부 빈 결과. 가장 싼 글
#
#     정리 잡 없이 돌리면 회차 A 15분 내내 "아무것도 안 달린 글 20개" 를 재게
#     된다. 재려던 것이 시작 몇 초 만에 1페이지 밖으로 밀려나는 것이다.
#
#     ⚠️ 이 오염은 p95 를 '낮추는' 방향이라 더 위험하다. 회차 A 는 p95 가
#        평평한지 우상향하는지를 보는 회차인데, 측정 대상이 회차 초반에 가벼워지면
#        서버가 나빠지고 있어도 상쇄되어 안 보인다.
#
#   즉 이 스크립트의 역할은 '데이터 크기 고정' 에서 '첫 페이지 구성 고정' 으로
#   바뀌었다. 회차 A 가 데이터 조건을 고정한 채 부하만 본다는 원칙은 그대로다.
#
# 지우는 것 / 지우지 않는 것
#   지운다     : 부하 계정(lt####)이 회차 중 만든 글과 거기 딸린 신청
#   지우지 않는다: '[SEED]' 시딩 글 300 건 — 시나리오 2·4 의 대상 풀이다
#   지우지 않는다: 시딩 글에 들어온 런타임 신청
#                 → 중복 신청 400 의 발생률(회차 끝 약 5%, 평균 2.5%)은
#                   설계상 예상된 값이다. 여기서 지우면 그 값이 0 에 수렴해
#                   실제와 다른 조건이 된다.
#
# 사용
#   ./cleanup/steady-state.sh              # 5초 주기, 배치 50건
#   INTERVAL=10 BATCH=100 ./cleanup/steady-state.sh
#   Ctrl-C 로 멈춘다. 멈출 때 남은 런타임 글 수를 찍는다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../db.sh
source "${SCRIPT_DIR}/../db.sh"
lt_guard_target

INTERVAL="${INTERVAL:-5}"   # 초. 문서 기준 5~10초
BATCH="${BATCH:-50}"        # 1회 삭제 건수

# 삭제 속도가 생성 속도를 못 따라가면 의미가 없다.
#   Peak 기준 시나리오 5 = 6 RPS → 5초당 30건
#   기본값 50건/5초 = 10 RPS 이므로 여유가 있다.
# 배율을 올린 회차(×2 = 12 RPS)에서도 50/5 로 충분하지만, 뒤처지는지는
# 아래 로그의 '남은' 값이 계속 증가하는지로 판단한다.
#
# ⚠️ 다만 '재고가 0 으로 수렴한다' 와 '첫 페이지가 [SEED] 로 유지된다' 는 다르다.
#    삭제가 배치라서, 기본값(5초 주기)이면 주기 안에서 30건이 쌓였다가 지워지는
#    것을 반복한다. 첫 페이지가 20건이므로 그 5초의 대부분을 신규 글이 덮는다.
#
#      5초/50건  1초에 6건 생성 → 다음 삭제까지 최대 30건 재고 → 첫 페이지 거의 전부 신규 글
#      1초/20건  1초에 6건 생성 · 20건 삭제 → 재고 6건 내외 → 첫 페이지 20건 중 약 14건이 [SEED]
#
#    위 '지금 이유' 대로 첫 페이지 구성을 재려는 것이면 주기를 조인다.
#      INTERVAL=1 BATCH=20 ./cleanup/steady-state.sh
#    대가는 DELETE 가 5배 잦아지는 것이다. 회차 A 는 쿼리 수가 아니라 지연을 보는
#    회차라 감당할 만하지만, 쿼리 수를 같이 재는 회차(--queries)에는 붙이지 않는다.
echo "정리 잡 시작 — ${INTERVAL}초마다 런타임 생성 글 최대 ${BATCH}건"
echo "대상: $(lt_db_label)"
echo "(Ctrl-C 로 종료)"

TOTAL=0

on_exit() {
  echo ""
  echo "정리 잡 종료 — 누적 ${TOTAL}건 삭제"
  local left
  left=$(psql_exec -c "SELECT count(*) FROM posts WHERE author_id IN (SELECT id FROM users WHERE email LIKE 'lt%@test.local');" 2>/dev/null || echo "?")
  echo "남은 런타임 글: ${left}건"
  if [[ "${left}" != "0" && "${left}" != "?" ]]; then
    echo "0 이 아니면 회차 후 한 번 더 돌리거나 seed/reset.sh 로 정리한다." >&2
  fi
}
trap on_exit EXIT
# Ctrl-C 를 즉시 받으려면 sleep 을 백그라운드로 두고 wait 해야 한다.
# 포그라운드 sleep 중에는 bash 가 트랩을 sleep 이 끝난 뒤로 미룬다.
RUNNING=1
trap 'RUNNING=0' INT TERM

while [[ "${RUNNING}" -eq 1 ]]; do
  # PK 로 대상을 먼저 고정한 뒤 지운다.
  #   · 조건(title LIKE)으로 바로 DELETE 하면 매번 전체를 훑는다
  #   · LIMIT 없이 지우면 한 트랜잭션이 길어져 회차 중 락 대기가 생긴다
  # 오래된 것부터(ORDER BY id) 지워야 방금 만들어진 글이 조회 대상에
  # 잠시라도 남아, 시나리오 5 의 쓰기가 읽기에 반영되는 실제 흐름과 같아진다.
  # 판별 기준은 제목이 아니라 '작성자' 다.
  #
  #   [SEED] 글 → seedauthor@test.local  (generate.sh 가 만든 고정 300건)
  #   [LT]   글 → lt0001~lt0600          (시나리오 5 가 회차 중 만든 것)
  #
  # 제목의 '[LT]' 접두사로 고르면, 그것을 붙이는 주체가 A 의 시나리오 5 코드라
  # 접두사가 빠지는 순간 아무것도 안 지워진다. 그런데 회차는 정상으로 끝나고
  # 목록만 조용히 불어난다 — 결과를 다 뽑고 나서야 알게 되는 종류의 실패다.
  # 작성자로 고르면 A 가 제목을 뭐라고 짓든 동작한다.
  DELETED=$(psql_exec -c "
    WITH doomed AS (
      SELECT p.id FROM posts p
       WHERE p.author_id IN (
               SELECT id FROM users WHERE email LIKE 'lt%@test.local'
             )
       ORDER BY p.id
       LIMIT ${BATCH}
    ),
    del_app AS (
      DELETE FROM applications WHERE post_id IN (SELECT id FROM doomed)
    ),
    del_room_member AS (
      DELETE FROM chat_room_members
       WHERE room_id IN (SELECT id FROM chat_rooms WHERE post_id IN (SELECT id FROM doomed))
    ),
    del_room AS (
      DELETE FROM chat_rooms WHERE post_id IN (SELECT id FROM doomed)
    ),
    del_post AS (
      DELETE FROM posts WHERE id IN (SELECT id FROM doomed) RETURNING 1
    )
    SELECT count(*) FROM del_post;
  ")

  TOTAL=$(( TOTAL + DELETED ))

  if [[ "${DELETED}" -gt 0 ]]; then
    LEFT=$(psql_exec -c "SELECT count(*) FROM posts WHERE author_id IN (SELECT id FROM users WHERE email LIKE 'lt%@test.local');")
    printf '%s  삭제 %3d건 (누적 %d) · 남은 런타임 글 %s건\n' \
      "$(date +%H:%M:%S)" "${DELETED}" "${TOTAL}" "${LEFT}"
  fi

  sleep "${INTERVAL}" &
  wait $! 2>/dev/null || true
done
