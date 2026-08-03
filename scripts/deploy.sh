#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONTAINERS=(
  "gamehouse-db"
  "gamehouse-rabbitmq"
  "gamehouse-backend"
  "gamehouse-frontend"
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

echo "[1/6] Updating infra repository..."

if [[ "$(id -u)" -eq 0 ]]; then
  sudo -u ssm-user -H \
    git -C "${INFRA_DIR}" pull --ff-only origin develop
else
  git pull --ff-only origin develop
fi

echo "[2/6] Validating Docker Compose..."

docker compose config >/dev/null

echo "[3/6] Pulling Docker images..."

docker compose pull

echo "[4/6] Starting containers..."

docker compose up -d --remove-orphans

echo "[5/6] Checking container health..."

for container in "${CONTAINERS[@]}"; do
  if ! wait_for_health "${container}"; then
    echo "Deployment failed."

    docker compose ps
    docker compose logs --tail=100

    exit 1
  fi
done

echo "[6/6] Checking backend actuator..."

if ! wait_for_actuator; then
  echo "Deployment failed."

  docker compose ps
  docker compose logs --tail=100 backend

  exit 1
fi

docker compose ps

# 롤백 방식을 만든 뒤 활성화하는 것을 권장합니다.
# docker image prune -f

echo "========================================"
echo "Deployment succeeded"
echo "========================================"

exit 0