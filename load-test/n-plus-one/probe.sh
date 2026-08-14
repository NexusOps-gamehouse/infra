#!/usr/bin/env bash
# ===========================================================================
# N+1 프로브 — 의심 API 를 하나씩 두드려 '항목 1건당 쿼리 수' 를 낸다.
#
# query-count.sh 는 "이 구간에 DB 가 몇 번 훑였나" 만 센다. 그 구간에 요청
# 하나만 넣으면 그 요청의 값이 되므로, 그쪽은 회차든 단발이든 아무 API 에나
# 쓸 수 있다. 이 스크립트는 그것을 엔드포인트 목록만큼 반복해 자동화한 것이고,
# 자동화의 대가로 대상이 좁다 — 같은 요청을 N 번 되풀이해도 결과가 같은 API,
# 즉 조회뿐이다.
#
# ⚠️ 쓰기 API 는 대상이 아니다. --reqs 로 반복하는 순간 2회차부터 의미가
#    달라진다 — 참가 신청은 unique(post_id, applicant_id) 에 걸려 예외 경로로
#    빠지고, 삭제는 404 가 된다. 그러면 측정값이 '쓰기 1회 + 실패 N-1회' 의
#    혼합이 되어 아무 뜻도 없다.
#
#    쓰기를 재려면 이 스크립트를 거치지 말고 query-count.sh 를 직접 쓴다.
#    분모는 응답 항목이 아니라 연관 데이터 건수다(예: 글 삭제라면 그 방의
#    메시지 수). 파생 delete 는 벌크가 아니라 건별로 도는 것이 기본이라
#    거기서도 '건당' 이 1 근처로 나올 수 있다.
#      ./load-test/query-count.sh before
#      curl -X DELETE .../api/posts/123 -H "Authorization: Bearer $TOKEN"
#      ./load-test/query-count.sh after --reqs 1 --per <메시지수> --per-label 메시지
#
# ⚠️ 분모가 엔드포인트마다 다르다.
#    /api/posts 는 게시글 수에, /api/friends 는 친구 수에, /api/chat/rooms 는
#    방 수에 비례한다. 그래서 각 엔드포인트의 응답에서 항목 수를 직접 세어
#    (itemsJq) 그것을 분모로 넘긴다. 게시글 수로 고정하면 다른 API 에서는
#    아무 뜻도 없는 숫자가 나온다.
#
# ⚠️ 구간 경계를 공유한다.
#    측정 하나에 통계 반영 대기가 12초 이상 든다(query-count.sh 참조).
#    엔드포인트마다 before/after 를 따로 찍으면 그 두 배가 든다. 앞 구간의
#    after 가 다음 구간의 before 이므로, --save 로 넘겨 한 번씩만 기다린다.
#    → 엔드포인트 6개에 스냅샷 7장. 약 2분.
#
# 사용법
#   cd infra
#   ./load-test/n-plus-one/probe.sh fixture   # 잴 수 있게 데이터를 만든다 (1회)
#   ./load-test/n-plus-one/probe.sh run
#   ./load-test/n-plus-one/probe.sh reset     # 프로브 데이터 제거
#
#   ./load-test/n-plus-one/probe.sh run --only posts,chat-rooms --reqs 5
#
# ⚠️ 재는 동안 다른 트래픽이 없어야 한다. 정리 잡·회차가 돌고 있으면 그 쿼리가
#    전부 섞인다. 프런트엔드 탭이 열려 있으면 폴링(/api/notifications)도 섞인다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SQL_DIR="${SCRIPT_DIR}/sql"
QC="${LT_DIR}/query-count.sh"
SEED_DIR="${SEED_DATA_DIR:-${LT_DIR}/seed/data}"
TOKENS="${SEED_DIR}/tokens.json"

BASE_URL="${BASE_URL:-http://localhost:8080}"
PROBE_EMAIL="${PROBE_EMAIL:-lt0001@test.local}"

# shellcheck source=../db.sh
source "${LT_DIR}/db.sh"

command -v jq   >/dev/null 2>&1 || { echo "jq 가 없다." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl 이 없다." >&2; exit 1; }

# ---------------------------------------------------------------------------
# 대상 목록
#
# 코드를 읽어 고른 것이다. 기준은 하나 — "DTO 로 옮기는 동안 항목마다 쿼리가
# 나가는가". 서비스 메서드가 아니라 '매퍼' 단위로 골랐다. listForPost 와
# myApplications 는 같은 ApplicationService.toDto 를 쓰므로 하나만 재면 된다.
#
#   key ; 경로 ; 항목수 jq ; 분모 라벨 ; 역할(list|control)
#
# 역할이 control 인 것은 '목록' 이 아니라 단건 조회다. 항목이 영원히 1 이라
# 비례 여부를 따질 수 없고, 따질 필요도 없다. 재는 이유는 **대조군** 이라서다 —
# 잡음 없는 환경에서 이 값이 한 자리로 나와야 나머지 숫자를 믿을 수 있다.
#
# ⚠️ control 을 '표본 부족' 으로 표시하지 않는다. 표본 부족은 "데이터를 더
#    만들면 해결된다" 는 뜻인데, 단건 조회는 fixture 를 백 번 돌려도 1 이다.
#    그렇게 찍으면 고칠 수 없는 것을 고치라고 시키는 셈이다.
#
# ⚠️ 구분자는 한 글자여야 한다. IFS 는 '문자열' 이 아니라 '문자 집합' 이라
#    IFS='@@' 는 IFS='@' 과 같고, 그러면 '@@' 사이의 빈 칸이 필드로 잡혀
#    열이 통째로 밀린다. jq 식에 '|' 가 들어가므로 ';' 를 쓴다.
# ---------------------------------------------------------------------------
read -r -d '' TARGETS <<'EOF' || true
posts;/api/posts;length;게시글;list
my-apps;/api/my/applications;length;신청;list
chat-rooms;/api/chat/rooms;length;채팅방;list
friends;/api/friends;length;친구;list
notifications;/api/notifications;.items|length;알림;list
users-me;/api/users/me;1;항목;control
EOF

REQS=3
ONLY=""
WORK=""   # mktemp -d 결과. trap 이 함수 밖에서 도므로 전역이어야 한다

# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<EOF
사용법: ./load-test/n-plus-one/probe.sh <fixture|run|reset> [옵션]

  fixture   측정 가능한 양의 데이터를 계정 하나에 몰아준다 (친구·알림·채팅방·신청 각 10~30건)
            회차용 시딩만으로는 채팅방·친구·알림이 0건이라 잴 수가 없다
  run       엔드포인트를 하나씩 두드려 항목 1건당 쿼리 수를 낸다
    --reqs N        엔드포인트당 요청 수 (기본 ${REQS})
    --only a,b      일부만 (키: $(printf '%s' "${TARGETS}" | cut -d';' -f1 | tr '\n' ' '))
  reset     fixture 가 만든 것을 지운다

  대상 계정: ${PROBE_EMAIL} (PROBE_EMAIL 로 바꾼다)
  대상 서버: ${BASE_URL} (BASE_URL 로 바꾼다)
  대상 DB  : $(lt_db_label) (LT_DB_* 로 바꾼다)
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# 프로브 계정 — id 는 DB 에서, 토큰은 시딩이 발급해 둔 것에서 찾는다.
#
# 토큰을 여기서 새로 발급하지 않는 이유: 로그인도 쿼리를 남긴다. 측정 구간
# 안에서 로그인하면 그 쿼리가 결과에 섞인다.
# ---------------------------------------------------------------------------
probe_id() {
  local id
  id=$(psql_exec -c "SELECT id FROM users WHERE email = '${PROBE_EMAIL}';")
  if [[ -z "${id}" ]]; then
    echo "계정이 없다: ${PROBE_EMAIL}" >&2
    echo "  ./load-test/seed/generate.sh 를 먼저 돌린다." >&2
    exit 1
  fi
  printf '%s' "${id}"
}

token_for() {
  local uid="$1" tok
  tok=$(jq -r --argjson id "${uid}" 'map(select(.userId == $id))[0].token // empty' "${TOKENS}")
  # 시딩 작성자(seedauthor)처럼 토큰이 없는 계정을 고를 수 있다. 그때는 첫 계정으로
  # 떨어뜨린다 — 표본이 0 이 되지만, 여기서 죽으면 나머지 엔드포인트도 못 잰다.
  [[ -z "${tok}" ]] && tok=$(jq -r '.[0].token' "${TOKENS}")
  printf '%s' "${tok}"
}

# ---------------------------------------------------------------------------
cmd_fixture() {
  lt_guard_target
  local id; id=$(probe_id)
  echo "대상 $(lt_db_label) · ${PROBE_EMAIL} (id ${id})"
  psql_exec -v probe_id="${id}" -f "${SQL_DIR}/fixture.sql" >/dev/null
  echo "완료 — 친구 30 · 알림 30 · 채팅방 10(멤버 5) · 신청 30"
  echo ""
  echo "⚠ 회차용 시딩 상태가 바뀌었다. 부하 회차를 돌리기 전에 seed/generate.sh 를 다시 돌린다."
}

cmd_reset() {
  lt_guard_target
  local id; id=$(probe_id)
  psql_exec -v probe_id="${id}" -f "${SQL_DIR}/reset.sql" >/dev/null
  echo "프로브 데이터를 지웠다 (${PROBE_EMAIL})"
}

# ---------------------------------------------------------------------------
# 한 엔드포인트에 요청을 N 번 보낸다. 응답 본문은 마지막 것만 남긴다.
# ---------------------------------------------------------------------------
hit() {
  local url="$1" token="$2" n="$3" out="$4" code=""
  local i
  for ((i = 0; i < n; i++)); do
    code=$(curl -s -o "${out}" -w '%{http_code}' "${url}" \
             -H "Authorization: Bearer ${token}")
  done
  printf '%s' "${code}"
}

# ---------------------------------------------------------------------------
cmd_run() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reqs) REQS="${2:-}"; shift 2 ;;
      --only) ONLY="${2:-}"; shift 2 ;;
      *) echo "모르는 인자: $1" >&2; usage ;;
    esac
  done
  [[ "${REQS}" =~ ^[1-9][0-9]*$ ]] || { echo "--reqs 는 1 이상의 정수다" >&2; exit 1; }

  [[ -f "${TOKENS}" ]] || { echo "토큰이 없다: ${TOKENS}"$'\n'"  seed/generate.sh 를 먼저 돌린다." >&2; exit 1; }
  curl -sf -o /dev/null "${BASE_URL}/api/posts" -H "Authorization: Bearer $(jq -r '.[0].token' "${TOKENS}")" \
    || { echo "대상에 붙지 못했다: ${BASE_URL}" >&2; exit 1; }

  # ⚠️ WORK 는 전역이다. local 로 두면 trap 이 도는 시점에는 함수가 이미 끝나
  #    'work: unbound variable' 로 죽는다(set -u). 실제로 그랬다.
  WORK=$(mktemp -d)
  trap 'rm -rf "${WORK}"' EXIT
  local work="${WORK}"

  local pid; pid=$(probe_id)

  # --- 1단계: 표본 확인 ---------------------------------------------------
  #
  # 측정 전에 각 엔드포인트를 한 번씩 불러 '항목이 몇 개 담기는가' 를 본다.
  # 이 요청들은 스냅샷 이전이라 결과에 안 섞이고, 덤으로 워밍업이 된다
  # (첫 호출의 지연 초기화가 측정 구간에 들어가지 않는다).
  echo "표본 확인 — ${BASE_URL} · ${PROBE_EMAIL}"
  echo ""
  printf '  %-14s %-26s %8s %8s\n' "키" "경로" "상태" "항목"

  local plan="${work}/plan.tsv"
  : > "${plan}"

  local key path itemsjq label role token code items note thin=0
  while IFS=';' read -r key path itemsjq label role; do
    [[ -z "${key}" ]] && continue
    [[ -n "${ONLY}" && ",${ONLY}," != *",${key},"* ]] && continue

    token=$(token_for "${pid}")

    code=$(hit "${BASE_URL}${path}" "${token}" 1 "${work}/body.json")
    if [[ "${code}" == 200 ]]; then
      items=$(jq -r "${itemsjq}" "${work}/body.json" 2>/dev/null || echo 0)
      [[ "${items}" =~ ^[0-9]+$ ]] || items=0
    else
      items=0
    fi

    # 단건 조회는 '표본 부족' 이 아니라 대조군이다. 고칠 수 있는 것과 고칠 수
    # 없는 것을 같은 말로 적으면, 이미 fixture 를 돌린 사람이 또 돌리게 된다.
    note=""
    if [[ "${role}" == "control" ]]; then
      note="  ← 대조군 (단건 조회. 항목은 항상 1)"
    elif [[ "${code}" != 200 ]]; then
      note="  ← 응답 실패"; thin=1
    elif [[ "${items}" -lt 5 ]]; then
      note="  ← 표본 부족"; thin=1
    fi

    printf '  %-14s %-26s %8s %8s%s\n' "${key}" "${path}" "${code}" "${items}" "${note}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${key}" "${path}" "${label}" "${token}" "${items}" "${role}" >> "${plan}"
  done <<< "${TARGETS}"

  echo ""
  # 안내는 해당될 때만 찍는다. 늘 찍으면 정상인 실행에서도 뭔가 잘못한 것처럼 읽힌다.
  if [[ "${thin}" -eq 1 ]]; then
    echo "  ⚠ '표본 부족' 은 그 계정에 데이터가 없다는 뜻이다 — fixture 를 먼저 돌린다."
    echo "    분모가 한 자리면 '건당 1회'(N+1)와 '상수 1회'(정상)를 못 가른다."
  else
    echo "  표본 정상. 대조군을 뺀 전부가 5건 이상이다."
  fi
  echo ""

  # --- 2단계: 배경 잡음 --------------------------------------------------
  #
  # ⚠️ 이 측정은 "그 창(window) 동안 DB 가 훑인 횟수" 다. 우리 요청만 세는 게
  #    아니라 그 시간에 DB 에 붙은 모든 것을 센다. DB GUI 를 켜 두거나 프런트
  #    탭이 폴링하고 있으면 그것도 들어온다.
  #
  #    큰 응답에서는 묻히지만(/api/posts 는 요청당 4,000 스캔) 가벼운
  #    엔드포인트에서는 잡음이 신호보다 크다. 실제로 /api/users/me 가 요청당
  #    25 스캔에 posts·chat_rooms 까지 훑은 것으로 나온 적이 있다 — 전부 남의
  #    트래픽이었다.
  #
  # 그래서 아무 요청도 안 보내는 구간을 먼저 하나 잰다. 여기서 나온 값이
  # 이 환경의 바닥이다. 빼지는 않는다 — 빼면 '측정값' 이 아니라 '보정값' 이
  # 되고, 나중에 그 숫자를 실측으로 읽게 된다. 대신 얼마나 섞였는지 같이 찍는다.
  local snap="${work}/s0.json" next i=0 t0 t1
  echo "측정 — 먼저 배경 잡음부터. 요청을 보내지 않는다"
  "${QC}" before "${snap}" >/dev/null

  t0=$(date +%s)
  "${QC}" after "${snap}" --reqs 1 --per 1 --save "${work}/s_idle.json" \
    --out "${work}/_idle" --quiet
  t1=$(date +%s)

  local idle_scans idle_secs noise_rate
  idle_scans=$(jq -r '.totalScans' "${work}/_idle/queries.json")
  idle_secs=$(( t1 - t0 )); [[ "${idle_secs}" -lt 1 ]] && idle_secs=1
  noise_rate=$(awk "BEGIN{printf \"%.3f\", ${idle_scans} / ${idle_secs}}")
  snap="${work}/s_idle.json"

  printf '  배경 %s 스캔 / %s초 = 초당 %s\n\n' "${idle_scans}" "${idle_secs}" "${noise_rate}"

  # --- 3단계: 구간별 측정 -------------------------------------------------
  echo "측정 — 엔드포인트당 요청 ${REQS}회"

  local results="${work}/results.tsv"
  : > "${results}"

  while IFS=$'\t' read -r key path label token items role; do
    [[ -z "${key}" ]] && continue
    i=$((i + 1))
    next="${work}/s${i}.json"

    printf '  [%s] %s ' "${i}" "${path}" >&2
    t0=$(date +%s)
    hit "${BASE_URL}${path}" "${token}" "${REQS}" "${work}/body.json" >/dev/null

    # 분모가 0 이면 --per 0 → '건당' 은 null 이 된다. 그래도 '요청당' 은 유효하다.
    "${QC}" after "${snap}" --reqs "${REQS}" --per "${items}" --per-label "${label}" \
      --save "${next}" --out "${work}/${key}" --quiet
    t1=$(date +%s)

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "${key}" "${path}" "${label}" "${items}" "${work}/${key}/queries.json" "$(( t1 - t0 ))" \
      "${role}" >> "${results}"
    snap="${next}"
  done < "${plan}"

  render_summary "${results}" "${noise_rate}"
}

# ---------------------------------------------------------------------------
render_summary() {
  local results="$1" noise_rate="$2"
  local bar; bar=$(printf '═%.0s' {1..78})
  local sep; sep=$(printf '─%.0s' {1..78})
  local dirty=0

  echo ""
  echo "${bar}"
  echo " N+1 프로브 결과 — 엔드포인트당 요청 ${REQS}회"
  printf ' 배경 잡음 초당 %s 스캔 (우리 요청이 아닌 것)\n' "${noise_rate}"
  echo "${bar}"
  echo ""
  echo "  경로                            항목      요청당       건당   잡음   판정"

  # ⚠️ 소수 계산과 비교는 전부 jq 안에서 끝내고, 셸에는 '정수' 만 꺼내 온다.
  #    셸에서 awk 로 소수를 다루다가 한 번 깨졌는데, 하필 그 awk 가 인자 없이
  #    떠서 루프의 stdin(results 파일)을 통째로 삼켰다. 표가 한 줄로 뭉개지고
  #    나머지 엔드포인트가 통째로 사라진다 — 조용히 틀리는 쪽이라 더 나쁘다.
  local key path label items file secs line
  local perreq peritem_x100 noise_pct verdict top
  while IFS=$'\t' read -r key path label items file secs role; do
    [[ -f "${file}" ]] || continue

    # perreq: 표시용 문자열 / peritem_x100, noise_pct: 판정용 정수
    line=$(jq -r --argjson rate "${noise_rate}" --argjson secs "${secs}" '
        ([.tables[] | select(.perItem != null) | .perItem] | add // 0) as $pi
        | ($rate * $secs) as $noise
        | [ (.scansPerRequest * 10 | round / 10),
            ($pi * 100 | round),
            (if .totalScans > 0 then ($noise / .totalScans * 100 | round) else 100 end)
          ] | @tsv' "${file}" < /dev/null)
    IFS=$'\t' read -r perreq peritem_x100 noise_pct <<< "${line}"

    # 판정 — 항목 하나마다 쿼리가 한 번 이상 더 나가면 N+1 이다.
    # 0.5(=50) 는 여유다. 조건부로만 나가는 쿼리(예: 상태가 APPROVED 일 때만)는
    # 항목의 절반에만 걸려도 N+1 이기 때문이다.
    #
    # ⚠️ 잡음 판정을 N+1 판정보다 먼저 한다. 잡음이 절반인 구간에서 나온
    #    '건당 2회' 는 N+1 의 증거가 아니라 남의 트래픽이다.
    # 대조군을 맨 앞에서 거른다. 단건 조회는 잡음 비중이 늘 높게 나오는데
    # (신호가 원래 몇 개 안 되니까) 그걸 '판정보류' 로 찍으면 매번 뜬다.
    if [[ "${role}" == "control" ]]; then
      verdict="대조군"
    elif [[ "${noise_pct}" -ge 20 ]]; then
      verdict="판정보류"; dirty=1
    elif [[ "${items}" -lt 5 ]]; then
      verdict="표본부족"
    elif [[ "${peritem_x100}" -ge 50 ]]; then
      verdict="⚠ N+1"
    else
      verdict="정상"
    fi

    printf '  %-30s %7s %11s %10s %5s%%   %s\n' \
      "${path}" "${items}" "${perreq}" \
      "$(( peritem_x100 / 100 )).$(printf '%02d' $(( peritem_x100 % 100 )))" \
      "${noise_pct}" "${verdict}"
  done < "${results}"

  echo ""
  echo "${sep}"
  echo " 건당 = 응답에 담긴 항목 하나마다 DB 를 몇 번 더 훑었나. 0 에 가까우면 정상이다."
  echo " 잡음 = 그 구간 스캔 중 우리 요청이 아닌 것의 추정 비중."
  echo ""
  echo " 어느 테이블이 범인인지:"
  while IFS=$'\t' read -r key path label items file secs role; do
    [[ -f "${file}" ]] || continue
    top=$(jq -r '[.tables[] | select(.perItem != null and .perItem >= 0.5)
                 | "\(.table) \(.perItem * 100 | round / 100)회"] | join(" · ")' "${file}")
    [[ -n "${top}" ]] && printf '   %-28s %s\n' "${path}" "${top}"
  done < "${results}"

  if [[ "${dirty}" -eq 1 ]]; then
    echo ""
    echo " ⚠ '판정보류' 가 있다 — 그 구간은 남의 트래픽이 20% 를 넘었다."
    echo ""
    echo "   먼저 --reqs 를 올려 본다. 잡음은 창 길이에 비례하고 신호는 요청 수에"
    echo "   비례하므로, 요청을 늘리면 비중이 내려간다 (5회 → 40회로 31%가 6%가 된 적이 있다)."
    echo "   그래도 남는데 '요청당' 이 한 자리라면, 잡음이 큰 게 아니라 신호가 작은 것이다"
    echo "   — 항목이 30개인데 요청당 7 스캔이면 그 자체로 '항목에 안 비례한다' 는 답이다."
    echo ""
    echo "   숫자가 크면서 잡음도 크면 DB 에 붙은 것을 끊고 다시 잰다. 흔한 원인:"
    echo "     · DB GUI(DBeaver·TablePlus)의 자동 새로고침"
    echo "     · 프런트엔드 탭의 폴링 (/api/notifications 는 시계가 부른다)"
    echo "     · cleanup/steady-state.sh 나 진행 중인 회차"
    echo "   확인:  SELECT state, count(*) FROM pg_stat_activity WHERE datname='duo' GROUP BY 1;"
  fi
  echo "${bar}"
}

# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
CMD="$1"; shift
case "${CMD}" in
  fixture) cmd_fixture "$@" ;;
  run)     cmd_run "$@" ;;
  reset)   cmd_reset "$@" ;;
  -h|--help) usage ;;
  *) echo "모르는 명령: ${CMD}" >&2; usage ;;
esac
