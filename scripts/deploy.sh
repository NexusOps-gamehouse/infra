#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ================================================================
# Compose files
#
# 운영 배포에서는 반드시 기본 compose만 사용한다.
# docker-compose.local.yml은 개발자 PC 전용이며 EC2에서는 사용하지 않는다.
# ================================================================

APP_FILE="docker-compose.yml"
OBSERVE_FILE="docker-compose.observability.yml"


APP_CONTAINERS=(
  "gamehouse-rabbitmq"
  "gamehouse-backend"
  "gamehouse-frontend"
)


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

        docker logs \
          --tail=100 \
          "${container}" || true

        return 1
        ;;

    esac

    echo "${container}: ${status:-waiting}"

    sleep 5

  done


  echo "${container}: health check timed out"

  docker logs \
    --tail=100 \
    "${container}" || true

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

    if grep -Eq \
      '"status"[[:space:]]*:[[:space:]]*"UP"' \
      <<< "${response}"; then

      echo "Backend actuator: UP"

      return 0
    fi

    echo "Backend actuator: waiting"

    sleep 5

  done


  echo "Backend actuator health check timed out"

  echo "${response}"

  docker logs \
    --tail=100 \
    gamehouse-backend || true

  return 1
}


echo "========================================"
echo "GameHouse deployment started"
echo "========================================"

cd "${INFRA_DIR}"


# ================================================================
# 1. Update infra repository
# ================================================================

echo "[1/9] Updating infra repository..."

if [[ "$(id -u)" -eq 0 ]]; then

  sudo -u ssm-user -H \
    git -C "${INFRA_DIR}" \
    pull --ff-only origin develop

else

  git pull --ff-only origin develop

fi


# ================================================================
# 2. Validate Compose
#
# IMPORTANT:
# Local compose 파일은 검증/실행 대상이 아니다.
# AWS는 RDS를 사용한다.
# ================================================================

echo "[2/9] Validating Docker Compose..."

docker compose \
  -f "${APP_FILE}" \
  config >/dev/null

docker compose \
  -f "${OBSERVE_FILE}" \
  config >/dev/null


# ================================================================
# 3. Pull application images
# ================================================================

echo "[3/9] Pulling Docker images..."

docker compose \
  -f "${APP_FILE}" \
  pull


# ================================================================
# 4. Start application stack
# ================================================================

echo "[4/9] Starting application containers..."

docker compose \
  -f "${APP_FILE}" \
  up -d \
  --remove-orphans


# ================================================================
# 5. Container health
# ================================================================

echo "[5/9] Checking container health..."

for container in "${APP_CONTAINERS[@]}"; do

  if ! wait_for_health "${container}"; then

    echo "Deployment failed."

    docker compose \
      -f "${APP_FILE}" \
      ps

    docker compose \
      -f "${APP_FILE}" \
      logs --tail=100

    exit 1

  fi

done


# ================================================================
# 6. Spring actuator
#
# 여기서 DB 연결까지 포함한 애플리케이션 기동 상태를 확인한다.
# RDS 연결 실패도 이 단계에서 배포 실패로 감지한다.
# ================================================================

echo "[6/9] Checking backend actuator..."

if ! wait_for_actuator; then

  echo "Deployment failed."

  docker compose \
    -f "${APP_FILE}" \
    ps

  docker compose \
    -f "${APP_FILE}" \
    logs --tail=100 backend

  exit 1

fi


# ================================================================
# 7. Observability
# ================================================================

echo "[7/9] Starting observability stack..."

docker compose \
  -f "${OBSERVE_FILE}" \
  pull

docker compose \
  -f "${OBSERVE_FILE}" \
  up -d \
  --remove-orphans


# ================================================================
# 8. Prometheus config refresh
# ================================================================

echo "[8/9] Recreating Prometheus to apply config..."

docker compose \
  -f "${OBSERVE_FILE}" \
  up -d \
  --force-recreate \
  prometheus


# ================================================================
# 9. Observability health
# ================================================================

echo "[9/9] Checking observability container health..."

for container in "${OBSERVE_CONTAINERS[@]}"; do

  if ! wait_for_health "${container}"; then

    echo "Observability stack failed to start."
    echo "Application is running, but monitoring is degraded."

    docker compose \
      -f "${OBSERVE_FILE}" \
      ps

    docker compose \
      -f "${OBSERVE_FILE}" \
      logs --tail=100

    exit 1

  fi

done


docker compose \
  -f "${APP_FILE}" \
  ps

docker compose \
  -f "${OBSERVE_FILE}" \
  ps


echo "========================================"
echo "Deployment succeeded"
echo "========================================"

exit 0