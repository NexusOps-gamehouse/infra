#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINERS=(
  "gamehouse-rabbitmq"
  "gamehouse-backend"
  "gamehouse-frontend"
)

# 관측 스택은 별도 compose 프로젝트(name: gamehouse-observe)라 기본 파일만 보는
# `docker compose` 명령에 잡히지 않는다. -f 로 명시해야 한다.
#
# 순서가 중요하다. 이 스택은 gamehouse_backend-net 을 external 로 참조하므로
# 본 스택이 먼저 떠 있어야 한다. 그래서 본 스택 기동/헬스체크가 끝난 뒤에 올린다.
OBSERVE_FILE="docker-compose.observability.yml"

# 관측 컨테이너에는 healthcheck 를 정의하지 않았으므로
# wait_for_health 는 .State.Status(=running) 로 판정한다.
OBSERVE_CONTAINERS=(
  "gamehouse-cadvisor"
  "gamehouse-node-exporter"
  "gamehouse-prometheus"
  "gamehouse-grafana"
  "gamehouse-postgres-exporter"
)

wait_for_health() {
  local container="$1"
  local status=""

  echo "Checking ${container}..."

  for _ in $(seq 1 36); do
    status="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "${container}" 2>/dev/null || true
    )"

    case "${status}" in
      healthy|running)
        echo "${container}: ${status}"
        return 0
        ;;

      unhealthy|exited|dead)
        echo "${container}: ${status}"
        docker logs --tail=100 "${container}" || true
        return 1
        ;;
    esac

    echo "${container}: ${status:-waiting}"
    sleep 5
  done

  echo "${container}: health check timed out"
  docker logs --tail=100 "${container}" || true
  return 1
}

wait_for_actuator() {
  local response=""

  echo "Checking backend actuator..."

  for _ in $(seq 1 30); do
    response="$(
      curl \
        --fail \
        --silent \
        --show-error \
        --max-time 5 \
        http://127.0.0.1:8081/actuator/health \
        2>/dev/null || true
    )"

    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' <<< "${response}"; then
      echo "Backend actuator: UP"
      return 0
    fi

    echo "Backend actuator: waiting"
    sleep 5
  done

  echo "Backend actuator health check timed out"
  echo "${response}"
  docker logs --tail=100 gamehouse-backend || true
  return 1
}

echo "========================================"
echo "GameHouse deployment started"
echo "========================================"

cd "${INFRA_DIR}"

echo "[1/9] Updating infra repository..."

if [[ "$(id -u)" -eq 0 ]]; then
  sudo -u ssm-user -H \
    git -C "${INFRA_DIR}" pull --ff-only origin develop
else
  git pull --ff-only origin develop
fi

echo "[2/9] Validating Docker Compose..."

# 두 파일 모두 검증한다. .env 에 GF_ADMIN_PASSWORD 같은 필수값이 빠져 있으면
# 컨테이너를 건드리기 전에 여기서 멈추는 편이 안전하다.
docker compose config >/dev/null
docker compose -f "${OBSERVE_FILE}" config >/dev/null

echo "[3/9] Pulling Docker images..."

docker compose pull

echo "[4/9] Starting containers..."

docker compose up -d --remove-orphans

echo "[5/9] Checking container health..."

for container in "${CONTAINERS[@]}"; do
  if ! wait_for_health "${container}"; then
    echo "Deployment failed."

    docker compose ps
    docker compose logs --tail=100

    exit 1
  fi
done

echo "[6/9] Checking backend actuator..."

if ! wait_for_actuator; then
  echo "Deployment failed."

  docker compose ps
  docker compose logs --tail=100 backend

  exit 1
fi

# ---------------------------------------------------------------------------
# 관측 스택
#
# 여기까지 왔다면 앱은 이미 정상 기동한 상태다. 아래에서 실패해도 앱은 살아 있고,
# "관측이 깨졌다"는 사실만 파이프라인에 빨간불로 알리는 것이 목적이다.
#
# up -d 는 설정과 이미지가 그대로면 컨테이너를 재생성하지 않는다(멱등).
# 따라서 backend/frontend 배포에서 매번 같이 돌려도 부담이 없고,
# prometheus.yml 이나 datasources.yml 이 바뀐 배포에서만 실제로 교체된다.
#
# 참고: Grafana 대시보드 JSON 은 dashboards.yml 의 updateIntervalSeconds: 30
#       덕분에 재기동 없이도 반영되지만, prometheus.yml 은 사정이 다르다.
#       아래 [8/9] 참고.
# ---------------------------------------------------------------------------
echo "[7/9] Starting observability stack..."

# cadvisor 가 :latest 태그라 pull 할 때마다 상위 버전이 내려올 수 있다.
# 배포 재현성을 위해 고정 태그로 되돌리는 것을 권장한다.
docker compose -f "${OBSERVE_FILE}" pull
docker compose -f "${OBSERVE_FILE}" up -d --remove-orphans

# ---------------------------------------------------------------------------
# prometheus.yml 다시 읽히기
#
# 이 파일은 bind mount 다. 내용이 바뀌어도 compose 입장에서는 "설정이 그대로"이므로
# 위의 up -d 가 컨테이너를 재생성하지 않는다. 그 결과 디스크의 파일은 최신인데
# Prometheus 프로세스는 기동 시 읽은 옛 설정을 계속 들고 도는 상태가 된다.
# 새 수집 대상(job)을 추가해도 대시보드에 나타나지 않는 원인이 이것이다.
#
# SIGHUP 은 --web.enable-lifecycle 과 무관하게 항상 동작한다.
# (그 플래그는 HTTP 엔드포인트 /-/reload 만 통제한다)
# 재기동이 아니라 설정만 다시 읽는 것이라 수집 공백이 생기지 않는다.
#
# 설정이 깨져 있으면 Prometheus 는 옛 설정을 유지한 채 로그에만 남기고 넘어간다.
# 조용히 실패하므로 반드시 결과를 확인한다.
# ---------------------------------------------------------------------------
echo "[8/9] Reloading Prometheus config..."

docker kill -s HUP gamehouse-prometheus >/dev/null

sleep 3

if curl -fsS --max-time 5 http://127.0.0.1:19090/metrics 2>/dev/null \
     | grep -q '^prometheus_config_last_reload_successful 1'; then
  echo "Prometheus config reloaded"
else
  echo "::error::Prometheus config reload failed - 옛 설정으로 계속 동작 중입니다"
  docker logs --tail=50 gamehouse-prometheus || true
  exit 1
fi

echo "[9/9] Checking observability container health..."

for container in "${OBSERVE_CONTAINERS[@]}"; do
  if ! wait_for_health "${container}"; then
    echo "Observability stack failed to start."
    echo "The application itself is running - only monitoring is degraded."

    docker compose -f "${OBSERVE_FILE}" ps
    docker compose -f "${OBSERVE_FILE}" logs --tail=100

    exit 1
  fi
done

docker compose ps
docker compose -f "${OBSERVE_FILE}" ps

# 롤백 방식을 만든 뒤 활성화하는 것을 권장합니다.
# docker image prune -f

echo "========================================"
echo "Deployment succeeded"
echo "========================================"

exit 0
