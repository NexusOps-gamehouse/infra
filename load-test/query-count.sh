#!/usr/bin/env bash
# ===========================================================================
# 쿼리 수 측정 — N+1 을 '증상' 이 아니라 '숫자' 로 확정한다.
#
# ⚠️ 왜 k6 만으로는 안 되는가
#    회차 D 는 게시글을 300 → 10,000 건으로 늘리며 지연을 본다. 그런데 글 수를
#    늘리면 세 가지가 '동시에' 커진다.
#      · toDto() 가 글마다 날리는 부수 쿼리 수   ← N+1
#      · 응답 크기 (PostDto 1,014B × 글 수)
#      · JSON 직렬화 + 송신 비용
#    셋 다 글 수에 선형이라, p95 가 10배가 돼도 밖에서는 범인을 못 가른다.
#    이 스크립트가 그 셋 중 첫 번째만 따로 센다.
#
# 방식 — pg_stat_reset() 을 쓰지 않는다.
#    reset 은 superuser 권한이 필요하고(RDS 에서 갈린다), 무엇보다 그 DB 의
#    통계를 통째로 날린다. autovacuum 판단 근거까지 지우는 셈이라 부작용이
#    측정 범위 밖으로 나간다. 대신 회차 전후로 카운터를 '찍어서 빼는' 방식을
#    쓴다. 읽기 전용이므로 db.sh 의 lt_guard_target 도 필요 없다.
#
# 무엇을 세는가 — pg_stat_user_tables 의 seq_scan + idx_scan.
#    "그 테이블을 훑은 횟수" 다. 쿼리 한 개가 그 테이블을 한 번 보면 1 이고,
#    조인이면 참여 테이블마다 1 이다. 즉 '문장 수' 가 아니라 '테이블 접근 수'
#    인데, N+1 판별에는 오히려 이쪽이 맞다 — 조인 한 방으로 바꾸면 이 숫자가
#    떨어지는 것이 곧 목표이기 때문이다.
#
# 사용법
#   # k6 회차와 함께 (run.sh 가 이 두 줄을 대신 해 준다)
#   ./load-test/run.sh round-d --queries
#
#   # 단발 요청 하나를 재고 싶을 때
#   ./load-test/query-count.sh before
#   curl -s -o /dev/null localhost:8080/api/posts -H "Authorization: Bearer $TOKEN"
#   ./load-test/query-count.sh after --reqs 1
#
# ⚠️ 재는 동안 다른 트래픽이 없어야 한다. cleanup/steady-state.sh 가 돌고
#    있으면 그 DELETE 도 카운터에 섞인다. 회차 D 는 시나리오 1 단독(쓰기 없음)
#    이라 정리 잡을 안 켜도 되고, 그래서 이 측정에 가장 알맞은 회차다.
# ===========================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SNAP="${SCRIPT_DIR}/results/.pgstat-before.json"

# shellcheck source=./db.sh
source "${SCRIPT_DIR}/db.sh"

command -v jq >/dev/null 2>&1 || { echo "jq 가 없다." >&2; exit 1; }

usage() {
  cat >&2 <<EOF
사용법:
  ./load-test/query-count.sh before [스냅샷파일]
  ./load-test/query-count.sh after  [스냅샷파일] [--reqs N] [--out 디렉토리]

  before   현재 카운터를 파일로 찍는다 (기본: results/.pgstat-before.json)
  after    지금 값에서 그 파일을 빼서 회차 동안의 증가분을 낸다
    --reqs N          그 사이에 보낸 요청 수. 나눠서 '요청당' 을 낸다 (기본 1)
    --per N           '건당' 열의 분모. 응답에 담긴 항목 수 (기본: 현재 게시글 수)
    --per-label 라벨  그 분모의 이름. 출력에만 쓴다 (기본: 게시글)
    --out 디렉토리    queries.txt · queries.json 을 그 안에 남긴다
    --save 파일       after 스냅샷을 남긴다. 다음 구간의 before 로 쓴다
    --quiet           표를 찍지 않는다. --out / --save 는 그대로 동작한다

대상 DB: LT_DB_* 로 바꾼다 (기본 $(lt_db_label))
EOF
  exit 1
}

# ---------------------------------------------------------------------------
# 통계 반영을 기다린다 — 이 스크립트에서 가장 중요한 부분이다.
#
# ⚠️ PostgreSQL 15+ 는 각 백엔드가 자기 통계를 로컬에 모아 두었다가 공유
#    메모리로 '나중에' 넘긴다. 트랜잭션이 끝나도 직전 반영으로부터 1초
#    (PGSTAT_MIN_INTERVAL) 안이면 미루고, 백엔드가 유휴로 들어가면 최대
#    10초(PGSTAT_IDLE_INTERVAL) 뒤에야 넘긴다.
#
#    HikariCP 가 커넥션을 물고 있어서 회차가 끝나도 백엔드는 죽지 않고 유휴로
#    남는다. 그래서 회차 직후에 읽으면 대부분이 아직 안 넘어와 있다.
#
#    실측(2026-08-14, PG 16.14) — GET /api/posts 5회:
#      요청 직후에 읽음      2 scans      → "N+1 없음" 이라는 결론이 나온다
#      15초 뒤에 읽음    6,139 scans      → applications 만 글 1건당 3.0회
#    3,000배 차이다. 기다리지 않으면 이 스크립트는 틀린 답을 자신 있게 낸다.
#
# 그래서 최소 대기(기본 12초 = IDLE_INTERVAL 10초 + 여유)를 무조건 채우고,
# 그 다음 값이 멈출 때까지 더 본다. '값이 안 변한다' 만으로는 못 끝낸다 —
# 아직 아무것도 안 넘어온 구간에서도 값은 그대로이기 때문이다.
# ---------------------------------------------------------------------------
SETTLE_MIN="${LT_SETTLE_MIN:-12}"
SETTLE_MAX="${LT_SETTLE_MAX:-40}"

total_scans() {
  psql_exec -c "SELECT coalesce(sum(seq_scan + idx_scan), 0) FROM pg_stat_user_tables;"
}

settle() {
  [[ "${SETTLE_MIN}" -eq 0 && "${SETTLE_MAX}" -eq 0 ]] && return 0

  printf '통계 반영을 기다린다 (최소 %s초)…' "${SETTLE_MIN}" >&2
  [[ "${SETTLE_MIN}" -gt 0 ]] && sleep "${SETTLE_MIN}"

  local prev cur stable=0 waited="${SETTLE_MIN}"
  prev=$(total_scans)
  while [[ "${waited}" -lt "${SETTLE_MAX}" ]]; do
    sleep 2; waited=$((waited + 2))
    cur=$(total_scans)
    if [[ "${cur}" == "${prev}" ]]; then
      stable=$((stable + 1))
      [[ "${stable}" -ge 2 ]] && break   # 4초간 변화 없음
    else
      stable=0
    fi
    prev="${cur}"
    printf '.' >&2
  done
  printf ' %s초\n' "${waited}" >&2
}

# ---------------------------------------------------------------------------
# 스냅샷 한 장
#
# posts 건수를 같이 담는다. N+1 판별의 핵심 열이 '요청당 스캔 ÷ 글 수' 인데,
# 그 분모를 나중에 meta.json 에서 찾으면 회차 중 시나리오 5 가 만든 글이
# 빠진다. 잴 때 세는 것이 유일하게 맞다.
# ---------------------------------------------------------------------------
snapshot() {
  local tables posts
  tables=$(psql_exec -c "
    SELECT coalesce(json_agg(t ORDER BY t.relname), '[]'::json) FROM (
      SELECT relname,
             coalesce(seq_scan, 0) + coalesce(idx_scan, 0) AS scans,
             coalesce(seq_scan, 0)                         AS seq_scan,
             coalesce(idx_scan, 0)                         AS idx_scan,
             coalesce(n_tup_ins, 0) + coalesce(n_tup_upd, 0)
               + coalesce(n_tup_del, 0)                    AS writes
      FROM pg_stat_user_tables
    ) t;" | jq -c '.')

  posts=$(psql_exec -c "SELECT count(*) FROM posts;")

  jq -n \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg db "$(lt_db_label)" \
    --argjson posts "${posts}" \
    --argjson tables "${tables}" \
    '{at: $at, db: $db, posts: $posts, tables: $tables}'
}

# ---------------------------------------------------------------------------
cmd_before() {
  local out="${1:-${DEFAULT_SNAP}}"
  mkdir -p "$(dirname "${out}")"
  # before 도 기다린다. 회차 직전 활동(시딩·토큰 발급)의 통계가 아직 안 넘어온
  # 상태로 찍으면, 그것들이 회차 중에 넘어와 우리 델타에 얹힌다.
  settle
  snapshot > "${out}"
  echo "before  $(lt_db_label) · 게시글 $(jq -r '.posts' "${out}")건 → ${out}"
}

# ---------------------------------------------------------------------------
cmd_after() {
  local before="${DEFAULT_SNAP}" reqs=1 outdir="" save="" quiet=0
  local per="" per_label="게시글"

  # 위치 인자(스냅샷 파일)는 있어도 되고 없어도 된다.
  if [[ $# -gt 0 && "$1" != --* ]]; then before="$1"; shift; fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reqs)      reqs="${2:-}"; shift 2 ;;
      --out)       outdir="${2:-}"; shift 2 ;;
      --save)      save="${2:-}"; shift 2 ;;
      --per)       per="${2:-}"; shift 2 ;;
      --per-label) per_label="${2:-}"; shift 2 ;;
      --quiet)     quiet=1; shift ;;
      *) echo "모르는 인자: $1" >&2; usage ;;
    esac
  done

  if [[ ! -f "${before}" ]]; then
    echo "before 스냅샷이 없다: ${before}" >&2
    echo "  ./load-test/query-count.sh before 를 먼저 돌린다." >&2
    exit 1
  fi

  # 0 으로 나누지 않는다. 회차가 시작도 못 하고 죽으면 http_reqs 가 0 으로 와서
  # 여기로 온다. jq 의 나눗셈은 그 자리에서 예외라 메시지가 무슨 뜻인지 알 수 없다.
  [[ "${reqs}" =~ ^[0-9]+$ ]] || { echo "--reqs 는 정수다: '${reqs}'" >&2; exit 1; }
  if [[ "${reqs}" -eq 0 ]]; then
    echo "요청이 0 건이다 — 잴 것이 없다. 회차가 시작되지 못한 것인지 먼저 본다." >&2
    exit 1
  fi

  # 분모 — '항목 하나당 쿼리 몇 개' 의 그 '항목' 이다.
  #
  # ⚠️ 엔드포인트마다 비례하는 대상이 다르다. 목록 조회는 게시글 수지만
  #    /api/friends 는 친구 수, /api/chat/rooms 는 방 수다. 분모를 게시글로
  #    고정하면 다른 API 에서는 그 열이 아무 뜻도 없는 숫자가 된다.
  #    안 주면 현재 게시글 수를 쓴다(목록 조회 기준).
  [[ -z "${per}" ]] && per="-1"
  [[ "${per}" =~ ^-?[0-9]+$ ]] || { echo "--per 는 정수다: '${per}'" >&2; exit 1; }

  local after_json delta
  settle
  after_json=$(snapshot)

  # ⚠️ 회차 중에 만들어진 테이블(before 에 없던 것)도 잡는다. 없으면 0 으로 둔다.
  #    반대로 after 에서 사라진 테이블은 무시한다 — 지워진 테이블의 증가분은
  #    셀 방법이 없고, 그런 회차는 어차피 폐기 대상이다.
  delta=$(jq -n \
    --argjson b "$(cat "${before}")" \
    --argjson a "${after_json}" \
    --argjson reqs "${reqs}" \
    --argjson perArg "${per}" \
    --arg perLabel "${per_label}" \
    '
      ($b.tables | INDEX(.relname)) as $B
      | ($a.tables | INDEX(.relname)) as $A
      | (if $perArg < 0 then $a.posts else $perArg end) as $per
      | [ $A | to_entries[]
          | ($B[.key] // {scans:0, seq_scan:0, idx_scan:0, writes:0}) as $p
          | { table:   .key,
              scans:   (.value.scans    - $p.scans),
              seqScan: (.value.seq_scan - $p.seq_scan),
              idxScan: (.value.idx_scan - $p.idx_scan),
              writes:  (.value.writes   - $p.writes) }
          | . + { perRequest: (.scans / $reqs),
                  perItem:    (if $per > 0 then (.scans / $reqs / $per) else null end) }
        ]
      | sort_by(-.scans) as $rows
      | { db: $a.db, from: $b.at, to: $a.at,
          requests: $reqs, posts: $a.posts,
          per: $per, perLabel: $perLabel,
          totalScans: ([$rows[].scans] | add // 0),
          scansPerRequest: (([$rows[].scans] | add // 0) / $reqs),
          tables: $rows }
    ')

  local text
  text=$(render "${delta}")
  [[ "${quiet}" -eq 0 ]] && echo "${text}"

  if [[ -n "${outdir}" ]]; then
    mkdir -p "${outdir}"
    printf '%s\n' "${delta}" | jq '.' > "${outdir}/queries.json"
    printf '%s\n' "${text}" > "${outdir}/queries.txt"
  fi

  # after 스냅샷을 남긴다. 여러 엔드포인트를 줄줄이 잴 때, 이 after 가 다음
  # 구간의 before 가 된다 — 그래야 구간마다 12초씩 두 번 기다리지 않는다.
  if [[ -n "${save}" ]]; then
    mkdir -p "$(dirname "${save}")"
    printf '%s\n' "${after_json}" > "${save}"
  fi
}

# ---------------------------------------------------------------------------
# 출력
#
# 한글은 터미널에서 두 칸을 먹는데 printf 는 한 글자로 센다. 그래서 머리글은
# 폭을 손으로 맞춘 문자열을 그대로 찍고, 숫자 행만 printf 로 정렬한다.
# ---------------------------------------------------------------------------
render() {
  local d="$1"
  local bar; bar=$(printf '═%.0s' {1..76})
  local sep; sep=$(printf '─%.0s' {1..76})

  local reqs total per db pern perlabel
  reqs=$(jq -r '.requests'         <<<"${d}")
  total=$(jq -r '.totalScans'      <<<"${d}")
  per=$(jq -r '.scansPerRequest'   <<<"${d}")
  db=$(jq -r '.db'                 <<<"${d}")
  pern=$(jq -r '.per'              <<<"${d}")
  perlabel=$(jq -r '.perLabel'     <<<"${d}")

  {
    echo "${bar}"
    echo " 쿼리 수 — pg_stat_user_tables 델타"
    printf ' %s · 요청 %s건 · 분모 %s %s건\n' \
      "${db}" "$(comma "${reqs}")" "${perlabel}" "$(comma "${pern}")"
    echo "${bar}"
    echo ""
    # '건당' 의 분모는 위 머리글이 말한다. 열 이름에 라벨을 넣으면 라벨 길이마다
    # 표 폭이 달라져서, 여러 엔드포인트의 출력을 나란히 놓고 볼 수가 없다.
    #        테이블(22)              스캔(14)     요청당(12)     건당(12)  쓰기(10)
    echo "  테이블                          스캔       요청당        건당      쓰기"

    # 스캔이 0 인 테이블은 안 찍는다. 이 구간이 건드리지도 않은 테이블이다.
    while IFS=$'\t' read -r name scans perreq peritem writes; do
      [[ -z "${name}" ]] && continue
      printf '  %-22s %12s %10s %11s %9s\n' \
        "${name}" "$(comma "${scans}")" \
        "$(printf '%.1f' "${perreq}")" \
        "$(printf '%.3f' "${peritem}")" \
        "$(comma "${writes}")"
    done < <(jq -r '.tables[] | select(.scans > 0)
                    | [.table, .scans, .perRequest, (.perItem // 0), .writes]
                    | @tsv' <<<"${d}")

    echo ""
    echo "${sep}"
    printf ' 합계   요청당 스캔 %s 개 (총 %s)\n' "$(printf '%.1f' "${per}")" "$(comma "${total}")"
    echo ""

    # --- 판정 -------------------------------------------------------------
    # 여기서 확정하지 않는다. 한 구간의 절대값만으로는 "원래 무거운 API" 와
    # 구분되지 않기 때문이다. 확정은 항목 수를 바꾼 두 측정의 비교다.
    local suspects
    suspects=$(jq -r --arg L "${perlabel}" \
                  '.tables[] | select(.perItem != null and .perItem >= 0.5)
                   | "   · \(.table)  — \($L) 1건당 \(.perItem * 100 | round / 100) 회"' <<<"${d}")

    if [[ -n "${suspects}" ]]; then
      printf ' ⚠ N+1 로 의심되는 테이블 — 요청당 접근이 %s 수에 비례한다\n' "${perlabel}"
      echo "${suspects}"
      echo ""
      printf '   건당 열이 0 에 가깝지 않다는 것은, 응답에 담긴 %s 하나마다\n' "${perlabel}"
      echo "   그 테이블을 다시 훑었다는 뜻이다. 조인 한 번이면 이 값이 0 이 된다."
    else
      printf ' %s 수에 비례해 접근하는 테이블은 없다 (건당 < 0.5).\n' "${perlabel}"
    fi

    if [[ "${pern}" -lt 5 ]]; then
      echo ""
      printf ' ⚠ 분모가 %s건뿐이다. 이 표본으로는 "건당 1회" 와 "상수 1회" 를 못 가른다.\n' "${pern}"
      echo "   그 계정·자원에 데이터를 더 만든 뒤 다시 잰다."
    fi

    echo ""
    printf ' 확정 — %s 수를 바꿔 두 번 재고 두 열을 비교한다\n' "${perlabel}"
    echo "   (목록 조회라면 ./load-test/seed/grow.sh 3000 → 같은 회차 재실행)"
    echo "     요청당이 비례해 늘고 · 건당이 그대로  → N+1 확정"
    echo "     요청당이 그대로                       → 지연의 원인은 응답 크기 쪽이다"
    echo "${bar}"
  }
}

# 1234567 → 1,234,567. 소수는 정수부만 끊는다.
comma() {
  local n="${1%%.*}"
  printf '%s' "${n}" | sed -e :a -e 's/\(.*[0-9]\)\([0-9]\{3\}\)/\1,\2/;ta'
}

# ---------------------------------------------------------------------------
[[ $# -ge 1 ]] || usage
CMD="$1"; shift
case "${CMD}" in
  before) cmd_before "$@" ;;
  after)  cmd_after "$@" ;;
  -h|--help) usage ;;
  *) echo "모르는 명령: ${CMD}" >&2; usage ;;
esac
