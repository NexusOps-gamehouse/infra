#!/usr/bin/env bash
# ===========================================================================
# post 의 커넥션 풀을 초 단위로 받아 CSV 로 쌓는다.
#
#   ./sample-pool.sh results/R1-pool.csv &
#
# [왜 Prometheus 를 안 쓰나]
# 수집 주기가 30초다(로컬·운영 동일). 브로커 공백이 35~90초라 그 구간에 점이
# 1~3개뿐이고, 고갈과 회복이 계단으로 뭉개져 판정에 못 쓴다. 실제로 1회차가
# 그래서 버려졌다.
#
# actuator 를 직접 긁으면 주기를 우리가 정한다. 운영 Prometheus 설정을
# 건드리지 않아도 되는 것이 더 중요하다.
#
# [사전 준비]
#   kubectl -n gamehouse port-forward svc/post 18182:8180 &
#
# ⚠️ 파드가 여러 개면 port-forward 는 그 중 하나에만 붙는다. 즉 이 CSV 는
#    **한 파드 기준**이다. 풀은 파드마다 따로이므로 고갈 여부 판정에는
#    그대로 유효하지만, "전체 커넥션 수" 로 읽으면 안 된다.
# ===========================================================================
set -Eeuo pipefail

OUT="${1:?사용법: $0 <출력.csv>}"
PORT="${POOL_PORT:-18182}"
INTERVAL="${POOL_INTERVAL:-2}"

# 필요한 지표만 받는다. 전체 응답은 150 KB 라, 2초 간격 10분이면 44 MB 를
# 끌어온다 — 정작 쓰는 건 여섯 줄인데 부하 트래픽의 30배가 된다.
# includedNames 로 거르면 690 바이트다.
# ⚠️ 여기 적는 건 **미터 이름**이지 Prometheus 에 찍히는 이름이 아니다.
#    hikaricp_connections_timeout_total 로 적으면 안 잡힌다 — _total 은
#    counter 를 렌더링할 때 붙는 접미사다. tomcat_threads_busy 도 마찬가지.
NAMES="hikaricp_connections_active,hikaricp_connections_idle"
NAMES="$NAMES,hikaricp_connections_pending,hikaricp_connections_max"
NAMES="$NAMES,hikaricp_connections_timeout,tomcat_threads_busy"
URL="http://localhost:${PORT}/actuator/prometheus?includedNames=${NAMES}"

command -v curl >/dev/null || { echo "curl 이 필요하다" >&2; exit 2; }

mkdir -p "$(dirname "$OUT")"
echo "ts_utc,ts_local,active,idle,pending,max,timeout_total,tomcat_busy" > "$OUT"

echo "수집 시작 → $OUT (${INTERVAL}초 간격, 포트 $PORT)" >&2

while true; do
  body="$(curl -s --max-time 3 "$URL" 2>/dev/null || true)"

  # 메트릭 한 줄에서 값만 뽑는다. 없으면 NA — 수집이 끊긴 구간과 값이 0 인
  # 구간을 구분할 수 있어야 한다.
  #
  # ⚠️ 끝의 `|| true` 가 필수다. grep 은 못 찾으면 1 을 돌려주는데, set -e 아래에서
  #    명령치환이 실패하면 대입문 자체가 실패로 잡혀 스크립트가 그 자리에서 죽는다.
  #    포워딩이 잠깐 끊겨 body 가 비면 한 줄도 못 남기고 조용히 끝난다.
  g() { printf '%s' "$body" | grep -E "^$1\{" | head -1 | awk '{print $NF}' || true; }

  a="$(g hikaricp_connections_active)"
  i="$(g hikaricp_connections_idle)"
  p="$(g hikaricp_connections_pending)"
  m="$(g hikaricp_connections_max)"
  t="$(g hikaricp_connections_timeout_total)"
  tb="$(printf '%s' "$body" | grep -E '^tomcat_threads_busy' | head -1 | awk '{print $NF}' || true)"

  # epoch 를 한 번만 읽어 UTC 와 로컬을 같은 시각에서 만든다. 두 번 읽으면
  # 초 경계에서 둘이 어긋나 그라파나 스샷과 대조할 때 1초씩 밀린다.
  now="$(date '+%s')"
  if date -r "$now" '+%H' >/dev/null 2>&1; then
    AT=(-r "$now")          # BSD (macOS)
  else
    AT=(-d "@$now")         # GNU
  fi

  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$(date -u "${AT[@]}" '+%H:%M:%S')" \
    "$(date    "${AT[@]}" '+%H:%M:%S')" \
    "${a:-NA}" "${i:-NA}" "${p:-NA}" "${m:-NA}" "${t:-NA}" "${tb:-NA}" >> "$OUT"

  sleep "$INTERVAL"
done
