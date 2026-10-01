#!/usr/bin/env bash
# 러너에서 실행된다. 입력을 검증하고, 설정값을 변수 선언으로 만들어 remote.sh 앞에 붙인 뒤 SSM 으로 보낸다.
set -euo pipefail

check() {   # check <이름> <값> <정규식>
  if ! printf '%s' "$2" | LC_ALL=C grep -qE "$3"; then
    echo "::error::$1 형식이 올바르지 않다: $2"
    exit 1
  fi
}
check run_as "$RUN_AS" '^[a-z_][a-z0-9_-]*$'
check compose_file "$COMPOSE_FILE" '^[A-Za-z0-9._-]+$'
check compose_env_file "$COMPOSE_ENV_FILE" '^[A-Za-z0-9._-]+$'
check env_file "$ENV_FILE" '^[A-Za-z0-9._-]+$'
check service "$SERVICE" '^[A-Za-z0-9._-]+$'
check image_env_var "$IMAGE_ENV_VAR" '^[A-Z_][A-Z0-9_]*$'
check image_name "$IMAGE_NAME" '^[a-z0-9][a-z0-9._/-]*$'
check image_digest "$IMAGE_DIGEST" '^sha256:[0-9a-f]{64}$'
[ -z "$PRE_DEPLOY_SERVICE" ] || check pre_deploy_service "$PRE_DEPLOY_SERVICE" '^[A-Za-z0-9._-]+$'
[ -z "$ENV_SSM_PREFIX" ] || check env_ssm_prefix "$ENV_SSM_PREFIX" '^/[A-Za-z0-9_./-]+$'
[ -z "$ENV_REQUIRED_KEYS" ] || check env_required_keys "$ENV_REQUIRED_KEYS" '^[A-Za-z0-9_ ]+$'

# COMPOSE_B64·IMAGE 는 아래 ${!v} 간접 참조로 원격 스크립트에 넘어간다.
# shellcheck disable=SC2034
COMPOSE_B64=""
if [ -n "$COMPOSE_SOURCE" ]; then
  case "$COMPOSE_SOURCE" in
    /*|*..*) echo "::error::compose_source 는 레포 안의 상대 경로여야 한다: $COMPOSE_SOURCE"; exit 1 ;;
  esac
  src="$GITHUB_WORKSPACE/$COMPOSE_SOURCE"
  [ -f "$src" ] || { echo "::error::compose_source 파일이 없다: $COMPOSE_SOURCE (actions/checkout 을 먼저 실행할 것)"; exit 1; }
  # SSM 명령 파라미터 크기 한도 안에 들도록 제한한다.
  [ "$(wc -c < "$src")" -le 32768 ] || { echo "::error::compose_source 가 32KB 를 넘는다"; exit 1; }
  # shellcheck disable=SC2034
  COMPOSE_B64=$(base64 -w0 "$src")
fi

account=$(aws sts get-caller-identity --query Account --output text)
# shellcheck disable=SC2034
IMAGE="${account}.dkr.ecr.${AWS_REGION}.amazonaws.com/${IMAGE_NAME}@${IMAGE_DIGEST}"

payload=$(
  {
    for v in COMPOSE_DIR COMPOSE_FILE COMPOSE_ENV_FILE COMPOSE_B64 ENV_SSM_PREFIX ENV_FILE \
             ENV_REQUIRED_KEYS AWS_CLI_IMAGE AWS_REGION SERVICE PRE_DEPLOY_SERVICE \
             IMAGE_ENV_VAR IMAGE HEALTH_URL HEALTH_RETRIES; do
      printf '%s=%q\n' "$v" "${!v}"
    done
    cat "$(dirname "$0")/remote.sh"
  } | base64 -w0
)

command_id=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunShellScript \
  --comment "gha ${GITHUB_REPOSITORY} run ${GITHUB_RUN_ID}" \
  --parameters "commands=[\"echo ${payload} | base64 -d | sudo -iu ${RUN_AS} bash -s\"]" \
  --query Command.CommandId --output text)

echo "command_id=${command_id}" >> "$GITHUB_OUTPUT"
echo "SSM CommandId: ${command_id}"
