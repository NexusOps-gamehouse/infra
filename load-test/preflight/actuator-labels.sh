#!/usr/bin/env bash
# ===========================================================================
# 대상 JVM 의 실제 특성 확인 — 회차 결과를 해석하는 근거.
#
# 원래는 대시보드가 쓸 라벨 이름을 확인하려고 만들었다(id="G1 Old Gen" 처럼
# 추측해서 쿼리하면 패널이 빈 채로 뜨므로). 대시보드를 쓰지 않기로 한 뒤에도
# 남긴 이유는, 여기서 나온 것이 라벨 이름이 아니라 환경 자체였기 때문이다.
#
#   · GC 종류    — Serial 이면 major GC 가 stop-the-world 단일 스레드다.
#                  회차 A 에서 p95 가 주기적으로 튀면 원인이 여기일 수 있다
#   · 힙 크기    — 페이징 없는 목록 조회와 곱해서 회차 D 의 OOM 시점을 가늠한다
#   · uri 라벨   — /api/posts/{id} 로 묶이지 않으면 게시글 수만큼 시계열이
#                  생겨 actuator 응답 자체가 커진다
#
# 회차 전에 한 번만 돌리면 된다.
#
# 대상은 앱 포트(8080)가 아니라 management 포트다. application.yml 에서
# management.server.port=8081 로 분리해 두었다.
# ===========================================================================

set -Eeuo pipefail

ACTUATOR="${ACTUATOR:-http://localhost:8081/actuator/prometheus}"

echo "대상: ${ACTUATOR}"
if ! curl -sf "${ACTUATOR}" -o /dev/null; then
  cat >&2 <<EOF

응답이 없다. 확인할 것:
  · backend 컨테이너가 떠 있는가
  · management 포트가 127.0.0.1:8081 로 바인딩돼 있는가
    (docker-compose.yml 기준. 외부 노출은 하지 않는다)
EOF
  exit 1
fi

BODY=$(curl -s "${ACTUATOR}")

section() { echo ""; echo "── $1 ──"; }

section "jvm_memory_used_bytes 의 area / id"
echo "${BODY}" | grep '^jvm_memory_used_bytes{' \
  | sed -E 's/^jvm_memory_used_bytes\{([^}]*)\}.*/\1/' \
  | sed -E 's/application="[^"]*",?//' \
  | sort -u

section "힙 영역만 (대시보드 힙 패널이 쓰는 것)"
echo "${BODY}" | grep '^jvm_memory_used_bytes{.*area="heap"' \
  | sed -E 's/.*id="([^"]*)".*/  id="\1"/' | sort -u

section "GC 이름 (jvm_gc_pause_seconds)"
echo "${BODY}" | grep '^jvm_gc_pause_seconds_count{' \
  | sed -E 's/.*(action="[^"]*").*(cause="[^"]*").*/  \1 \2/' | sort -u | head -10

section "HikariCP 풀 이름"
echo "${BODY}" | grep '^hikaricp_connections{' \
  | sed -E 's/.*pool="([^"]*)".*/  pool="\1"/' | sort -u

section "http_server_requests 의 uri 라벨 (카디널리티 확인)"
URI_COUNT=$(echo "${BODY}" | grep -c '^http_server_requests_seconds_count{' || true)
echo "  현재 시계열 수: ${URI_COUNT}"
echo "${BODY}" | grep '^http_server_requests_seconds_count{' \
  | sed -E 's/.*uri="([^"]*)".*/  \1/' | sort -u | head -20
echo ""
echo "⚠️ uri 가 /api/posts/{id} 처럼 템플릿으로 묶여 있어야 한다."
echo "   실제 ID 가 그대로 보이면 시계열이 글 수만큼 늘어난다."

section "공통 태그"
# grep -m1 을 쓰면 파이프 앞의 echo 가 SIGPIPE 로 죽고, pipefail 때문에
# 파이프라인 전체가 실패로 잡혀 || 가 잘못 실행된다. head -1 로 받는다.
echo "${BODY}" | grep -o 'application="[^"]*"' | head -1 || true

section "GC 종류 — 대시보드 힙 패널의 id 라벨이 여기서 갈린다"
if echo "${BODY}" | grep -q 'id="Tenured Gen"'; then
  echo "  Serial GC (Eden Space / Survivor Space / Tenured Gen)"
  echo ""
  echo "  ⚠️ G1 이 아니다. 컨테이너에 CPU 2개 미만 또는 메모리 1792MB 미만이"
  echo "     할당되면 JVM 이 Serial GC 를 고른다."
  echo "     · 대시보드에서 id=\"G1 Old Gen\" 으로 쿼리하면 패널이 빈다"
  echo "     · Serial GC 는 Full GC 가 stop-the-world 단일 스레드다."
  echo "       회차 A 의 p95 우상향과 회차 D 의 OOM 시점 해석에 직접 영향을 준다"
elif echo "${BODY}" | grep -q 'id="G1 Old Gen"'; then
  echo "  G1 GC (G1 Eden Space / G1 Survivor Space / G1 Old Gen)"
else
  echo "  위 'jvm_memory_used_bytes 의 area / id' 목록을 그대로 쓴다"
fi
