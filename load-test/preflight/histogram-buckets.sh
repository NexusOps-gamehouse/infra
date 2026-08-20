#!/usr/bin/env bash
# ===========================================================================
# 히스토그램 버킷 경계 확인.
#
# 설계 문서의 핵심 결정 하나가 "임계값은 버킷 경계에서만 고른다" 이다.
#   application.yml
#     distribution.slo.http.server.requests: 50ms, 100ms, 200ms, 500ms, 1s, 2s, 5s
#
# histogram_quantile() 은 버킷 사이를 선형 보간한다. 경계에 없는 값
# (예: 300ms)을 임계값으로 쓰면 p95 가 실제와 다르게 나온다. 그래서
# SLO 를 200ms / 500ms / 1s 로 잡았다 — 전부 경계 위의 값이다.
#
# 이 스크립트는 설정 파일이 아니라 '실제로 내보내는 le 값'을 본다.
# 설정을 바꿨는데 재배포를 안 했거나, 프로파일이 달라 적용이 안 된 경우를
# 여기서 잡는다.
# ===========================================================================

set -Eeuo pipefail

ACTUATOR="${ACTUATOR:-http://localhost:8081/actuator/prometheus}"
EXPECTED=(0.05 0.1 0.2 0.5 1.0 2.0 5.0)

echo "대상: ${ACTUATOR}"
BODY=$(curl -sf "${ACTUATOR}") || { echo "응답 없음 — backend 가 떠 있는가" >&2; exit 1; }

echo ""
echo "── http_server_requests_seconds_bucket 의 le 값 ──"
ACTUAL=$(echo "${BODY}" | grep '^http_server_requests_seconds_bucket{' \
  | sed -E 's/.*le="([^"]*)".*/\1/' | sort -u -g)

if [[ -z "${ACTUAL}" ]]; then
  cat >&2 <<EOF
_bucket 메트릭이 없다.

percentiles-histogram 이 꺼져 있다는 뜻이고, 이 상태로는
histogram_quantile() 이 항상 빈 결과를 낸다 = p95 패널이 전부 빈다.

application.yml 확인:
  management.metrics.distribution.percentiles-histogram.http.server.requests: true
EOF
  exit 1
fi

echo "${ACTUAL}" | sed 's/^/  le=/'

echo ""
echo "── SLO 로 쓸 수 있는가 ──"
MISSING=0
for want in "${EXPECTED[@]}"; do
  if echo "${ACTUAL}" | grep -qx "${want}"; then
    printf '  ✅ %-6s 경계 있음\n' "${want}s"
  else
    printf '  ❌ %-6s 없음 — 이 값을 임계값으로 쓰면 보간이 섞인다\n' "${want}s"
    MISSING=1
  fi
done

echo ""
echo "── 시계열 개수 (카디널리티) ──"
BUCKETS=$(echo "${BODY}" | grep -c '^http_server_requests_seconds_bucket{' || true)
URIS=$(echo "${BODY}" | grep '^http_server_requests_seconds_bucket{' \
  | sed -E 's/.*uri="([^"]*)".*/\1/' | sort -u | wc -l | tr -d ' ')
echo "  bucket 시계열 : ${BUCKETS}"
echo "  uri 종류      : ${URIS}"
echo "  uri 당 버킷   : $(( URIS > 0 ? BUCKETS / URIS : 0 ))"
echo ""
echo "회차 중에 이 값이 계속 늘면 uri 가 묶이지 않고 있다는 뜻이다."
echo "prometheus_tsdb_head_series 와 함께 본다."

exit "${MISSING}"
