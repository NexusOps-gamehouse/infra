#!/usr/bin/env bash
# infra/.env.k8s.local 의 외부 API 키를 kind 클러스터의 Secret 으로 밀어 넣는다.
#
# 왜 필요한가:
#   k8s/overlays/local 의 Secret 패치는 전부 더미다. 이 저장소는 public 이라 실제 키를
#   커밋할 수 없기 때문이다. 그래서 지금까지는 키가 필요할 때마다 파일을 찾아 직접
#   고치거나 kubectl create secret 을 손으로 쳐야 했고, 그렇게 넣은 값은 다음
#   `kubectl apply -k` 때 더미로 되돌아갔다.
#
# 왜 .env 가 아니라 별도 파일인가:
#   .env 는 compose 용이다. compose 는 구 모놀리스 backend 하나만 띄우므로 match 가
#   없고 LLM_API_KEY 가 의미 없다. 반대로 .env 의 DB_HOST/FRONTEND_* 는 kind 에서
#   의미가 없다. 어느 값이 어느 런타임에 쓰이는지 파일로 갈라 둔다.
#
#   다만 RIOT_API_KEY 처럼 양쪽이 같은 키를 쓰는 경우까지 두 번 적게 하지는 않는다 —
#   .env.k8s.local 에 없으면 .env 로 폴백하고, 어느 파일에서 읽었는지 출력한다.
#
# 사용법:
#   cp .env.k8s.local.example .env.k8s.local   # 그 뒤 값 채우기
#   ./scripts/k8s-local-secrets.sh
#   (k8s-local-up.sh 가 마지막 단계에서 자동으로 호출한다)
#
# ⚠️ DB/JWT/RabbitMQ 는 일부러 안 건드린다. kind 의 in-cluster postgres 는
#    k8s/overlays/local/postgres.yaml 의 계정으로 부트스트랩되므로, compose 용
#    .env 값(다른 DB 를 가리킨다)으로 덮어쓰면 오히려 연결이 깨진다.
#    여기서 다루는 건 "클러스터 밖 서비스를 부르는 실제 키"뿐이다.

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRIMARY="${INFRA_DIR}/.env.k8s.local"
FALLBACK="${INFRA_DIR}/.env"
NS="gamehouse"

# 키 이름:Secret 이름:재시작할 Deployment
MAPPINGS=(
  "RIOT_API_KEY:riot-secret:riot"
  "LLM_API_KEY:match-llm-secret:match"
)

if [ ! -f "${PRIMARY}" ] && [ ! -f "${FALLBACK}" ]; then
  echo "  infra/.env.k8s.local 이 없다 — 더미 키를 그대로 둔다."
  echo "  실제 키를 쓰려면: cp infra/.env.k8s.local.example infra/.env.k8s.local"
  exit 0
fi

# .env 계열을 source 하지 않고 파싱한다. compose 용 파일까지 폴백으로 읽으므로
# 이 스크립트가 모르는 변수가 셸에 풀리는 걸 막고, 값에 든 따옴표/공백도 살린다.
read_env() {
  [ -f "$1" ] || return 0
  python3 - "$1" "$2" <<'PY'
import sys, io
key = sys.argv[2]
for line in io.open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, _, v = line.partition("=")
    if k.strip() != key:
        continue
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    sys.stdout.write(v)
    break
PY
}

# placeholder 로 취급할 값들 — .example 을 복사만 하고 안 채운 경우다.
is_placeholder() {
  case "$1" in
    ""|dummy_key|CHANGE_ME|replace-with-*|change-me-*) return 0 ;;
    *) return 1 ;;
  esac
}

PATCHED=()
SKIPPED=()

for m in "${MAPPINGS[@]}"; do
  IFS=: read -r KEY SECRET DEPLOY <<<"$m"

  VALUE="$(read_env "${PRIMARY}" "${KEY}")"
  SOURCE=".env.k8s.local"
  if is_placeholder "${VALUE}"; then
    VALUE="$(read_env "${FALLBACK}" "${KEY}")"
    SOURCE=".env"
  fi

  if is_placeholder "${VALUE}"; then
    SKIPPED+=("${KEY}")
    continue
  fi

  if ! kubectl -n "${NS}" get secret "${SECRET}" >/dev/null 2>&1; then
    echo "  ⚠️  Secret ${SECRET} 이 없다 — 먼저 kubectl apply -k 가 돌아야 한다. 건너뛴다."
    continue
  fi

  # stringData 는 쓰기 전용 필드라 merge patch 로 넣으면 API 서버가 base64 로
  # 인코딩해 data 에 반영한다. 값에 든 특수문자 때문에 셸 인용이 깨지지 않도록
  # JSON 은 python 으로 만든다.
  PATCH="$(python3 -c 'import json,sys; print(json.dumps({"stringData":{sys.argv[1]:sys.argv[2]}}))' "${KEY}" "${VALUE}")"
  kubectl -n "${NS}" patch secret "${SECRET}" --type=merge -p "${PATCH}" >/dev/null

  # env 는 파드 기동 시점에 한 번만 주입된다 — Secret 만 고치면 이미 떠 있는
  # 파드는 옛 값을 계속 쓴다. 그래서 롤아웃을 다시 돌린다.
  if kubectl -n "${NS}" get deployment "${DEPLOY}" >/dev/null 2>&1; then
    kubectl -n "${NS}" rollout restart deployment/"${DEPLOY}" >/dev/null
  fi

  PATCHED+=("${KEY} → ${SECRET}  (${SOURCE} 에서 읽음, ${#VALUE}자)")
done

if [ ${#PATCHED[@]} -gt 0 ]; then
  echo "  주입됨:"
  printf '    %s\n' "${PATCHED[@]}"
fi
if [ ${#SKIPPED[@]} -gt 0 ]; then
  echo "  더미 유지 (.env.k8s.local / .env 어디에도 실제 값이 없다):"
  printf '    %s\n' "${SKIPPED[@]}"
fi
