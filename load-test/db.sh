#!/usr/bin/env bash
# ===========================================================================
# DB 접속 공통 — seed/generate.sh 와 cleanup/steady-state.sh 가 source 한다.
#
# ⚠️ 이 파일이 존재하는 이유
#    infra/.env 와 .env.local 의 DB_HOST 는 공용 dev RDS 를 가리킨다.
#    (실제 엔드포인트는 .env.local 을 볼 것. 이 저장소는 public 이라 적지 않는다)
#
#    시딩 스크립트가 그 변수를 그대로 주워 쓰면 00-reset.sql 이 팀 공용 개발
#    DB 를 비운다. 그래서 DB_* 를 쓰지 않고 LT_DB_* 만 본다. 이름이 다르면
#    실수로 상속될 수 없다.
#
#    로컬 기본값은 docker-compose.local.yml 의 postgres 다.
#    컨테이너 안에서는 5432 지만 호스트로는 15432 로 나온다.
# ===========================================================================

LT_DB_HOST="${LT_DB_HOST:-localhost}"
LT_DB_PORT="${LT_DB_PORT:-15432}"
LT_DB_NAME="${LT_DB_NAME:-duo}"
LT_DB_USERNAME="${LT_DB_USERNAME:-duo}"

# 비밀번호만 .env.local 에서 가져온다. 호스트는 절대 가져오지 않는다.
if [[ -z "${LT_DB_PASSWORD:-}" ]]; then
  _env_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../.env.local"
  if [[ -f "${_env_local}" ]]; then
    LT_DB_PASSWORD="$(grep -E '^LOCAL_DB_PASSWORD=' "${_env_local}" | head -1 | cut -d= -f2-)"
  fi
fi

# ---------------------------------------------------------------------------
# 가드 — 로컬이 아닌 곳을 지우려면 호스트명을 손으로 다시 쳐야 한다.
#
# 환경변수 하나(LT_ALLOW_REMOTE=1)로 뚫리게 두지 않는 이유는, 그런 플래그는
# 한 번 쓰고 셸에 남아 다음 실행까지 따라오기 때문이다. 호스트명을 그대로
# 복창하게 하면 "지금 무엇을 지우는지"를 매번 확인하게 된다.
# ---------------------------------------------------------------------------
lt_guard_target() {
  case "${LT_DB_HOST}" in
    localhost|127.0.0.1|::1|host.docker.internal) return 0 ;;
  esac

  if [[ "${LT_TARGET_CONFIRM:-}" == "${LT_DB_HOST}" ]]; then
    echo "⚠️  원격 DB 를 대상으로 진행한다: ${LT_DB_HOST}" >&2
    return 0
  fi

  cat >&2 <<EOF

거부 — 로컬이 아닌 DB 다.

  대상: ${LT_DB_HOST}:${LT_DB_PORT}/${LT_DB_NAME}

이 스크립트는 데이터를 지운다(00-reset.sql). 의도한 것이 맞다면 호스트명을
그대로 다시 입력해서 실행한다.

  LT_TARGET_CONFIRM=${LT_DB_HOST} $0

로컬 postgres 를 쓰려는 것이었다면 LT_DB_HOST 를 지우고 다시 실행한다.
(기본값 localhost:15432 = docker-compose.local.yml 의 postgres)

EOF
  exit 1
}

# psql 은 호스트에 있어야 한다.
#
# 컨테이너의 psql 을 docker exec 로 빌려 쓰는 방법도 있지만 쓰지 않는다.
#   · 02-posts.sql 은 \ir 로 옆 파일을 부른다. stdin 으로는 경로를 못 찾으므로
#     sql 디렉터리를 컨테이너에 복사해야 하는데, 그건 컨테이너 파일시스템을
#     건드리는 일이다. 컨테이너는 안 바꾸는 게 원칙이다
#   · docker exec 로 붙으면 컨테이너 내부 접속이라 비밀번호 없이 들어간다.
#     인증을 우회하는 경로를 하나 만드는 셈이다
#   · 컨테이너 이름에 결합된다. compose 프로젝트 이름이 바뀌면 조용히 깨진다
#   · AWS 회차에는 컨테이너가 없다. 로컬과 동작이 갈린다
# 아끼는 것은 설치 한 번뿐이라 값어치가 없다.
if ! command -v psql >/dev/null 2>&1; then
  cat >&2 <<'EOF'
psql 이 필요하다.

  brew install libpq
  echo 'export PATH="/opt/homebrew/opt/libpq/bin:$PATH"' >> ~/.zshrc

(libpq 는 서버 없이 클라이언트만 설치한다. postgresql@16 을 깔 필요 없다)
EOF
  exit 1
fi

# -qtA : 헤더/장식 없이 값만. jq 로 넘기려면 필수다.
psql_exec() {
  PGPASSWORD="${LT_DB_PASSWORD}" psql \
    -h "${LT_DB_HOST}" -p "${LT_DB_PORT}" -U "${LT_DB_USERNAME}" -d "${LT_DB_NAME}" \
    -v ON_ERROR_STOP=1 -qtA "$@"
}

lt_db_label() {
  echo "${LT_DB_HOST}:${LT_DB_PORT}/${LT_DB_NAME}"
}
