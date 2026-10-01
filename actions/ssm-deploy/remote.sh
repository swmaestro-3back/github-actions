#!/usr/bin/env bash
# 서버에서 실행된다. send.sh 가 맨 앞에 설정값(변수 선언)을 붙여 SSM 으로 보낸다.
set -euo pipefail
umask 077
cd "$COMPOSE_DIR"

ts=$(date +%Y%m%d-%H%M%S)
backed=()
created=()

compose() { docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

backup() {   # 바꾸기 전에 원본을 남긴다. 없던 파일은 롤백 때 지운다.
  if [ -f "$1" ]; then
    cp -p "$1" "$1.bak-$ts"
    backed+=("$1")
    ls -1t "$1".bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f --
  else
    created+=("$1")
  fi
}

restore_files() {
  local f
  for f in ${backed[@]+"${backed[@]}"}; do cp -p "$f.bak-$ts" "$f"; done
  for f in ${created[@]+"${created[@]}"}; do rm -f "$f"; done
}

abort() {   # 컨테이너를 바꾸기 전 실패: 파일만 되돌린다
  echo "배포 중단: $1"
  restore_files
  exit 1
}

rollback() {   # 컨테이너를 바꾼 뒤 실패: 파일을 되돌리고 이전 상태로 다시 띄운다
  echo "배포 실패: $1"
  restore_files
  if compose up -d "$SERVICE"; then
    echo "이전 설정으로 롤백했다"
  else
    echo "롤백도 실패했다. 수동 확인 필요"
  fi
  exit 1
}

# 1. SSM → env 파일
if [ -n "$ENV_SSM_PREFIX" ]; then
  params=$(mktemp)
  trap 'rm -f "$params"' EXIT
  if command -v aws >/dev/null 2>&1; then
    aws ssm get-parameters-by-path --region "$AWS_REGION" --path "$ENV_SSM_PREFIX" \
      --recursive --with-decryption --output json > "$params" || abort "SSM 조회 실패"
  else
    docker run --rm --network host -e AWS_REGION="$AWS_REGION" "$AWS_CLI_IMAGE" \
      ssm get-parameters-by-path --region "$AWS_REGION" --path "$ENV_SSM_PREFIX" \
      --recursive --with-decryption --output json > "$params" || abort "SSM 조회 실패"
  fi

  backup "$ENV_FILE"
  python3 - "$params" "$ENV_FILE.next" "$ENV_REQUIRED_KEYS" <<'PY' || abort "env 파일 생성 실패"
import json, re, sys

src, out, required = sys.argv[1], sys.argv[2], sys.argv[3].split()
values = {}
for p in json.load(open(src)).get("Parameters", []):
    key = p["Name"].rsplit("/", 1)[-1]
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        sys.exit(f"변수 이름으로 쓸 수 없는 파라미터: {p['Name']}")
    if key in values:
        sys.exit(f"같은 변수 이름이 두 번 나온다: {key}")
    # 작은따옴표 안의 값은 compose 가 그대로 읽는다. 작은따옴표가 든 값만 표현할 수 없다.
    if "'" in p["Value"]:
        sys.exit(f"작은따옴표가 든 값은 지원하지 않는다: {key}")
    values[key] = p["Value"]

if not values:
    sys.exit("파라미터가 하나도 없다. 경로를 확인할 것")
missing = [k for k in required if k not in values]
if missing:
    sys.exit("없는 필수 키: " + " ".join(missing))

with open(out, "w") as f:
    for k in sorted(values):
        f.write(f"{k}='{values[k]}'\n")
print(f"env 파일 생성: {len(values)}개 키 — " + " ".join(sorted(values)))
PY
  mv "$ENV_FILE.next" "$ENV_FILE"
fi

# 2. 이미지 변수
[ "$ENV_FILE" = "$COMPOSE_ENV_FILE" ] && [ -n "$ENV_SSM_PREFIX" ] || backup "$COMPOSE_ENV_FILE"
touch "$COMPOSE_ENV_FILE"
grep -v "^${IMAGE_ENV_VAR}=" "$COMPOSE_ENV_FILE" > "$COMPOSE_ENV_FILE.next" || true
printf '%s=%s\n' "$IMAGE_ENV_VAR" "$IMAGE" >> "$COMPOSE_ENV_FILE.next"
mv "$COMPOSE_ENV_FILE.next" "$COMPOSE_ENV_FILE"

# 3. compose 파일
if [ -n "$COMPOSE_B64" ]; then
  printf '%s' "$COMPOSE_B64" | base64 -d > "$COMPOSE_FILE.next"
  docker compose --env-file "$COMPOSE_ENV_FILE" -f "$COMPOSE_FILE.next" config -q \
    || { rm -f "$COMPOSE_FILE.next"; abort "compose 파일 검증 실패"; }
  backup "$COMPOSE_FILE"
  mv "$COMPOSE_FILE.next" "$COMPOSE_FILE"
  echo "compose 파일 교체: $COMPOSE_FILE"
else
  compose config -q || abort "compose 파일 검증 실패"
fi

# 4. 이미지 받기 · 사전 작업
compose pull -q "$SERVICE" ${PRE_DEPLOY_SERVICE:+"$PRE_DEPLOY_SERVICE"} || abort "이미지 pull 실패"
if [ -n "$PRE_DEPLOY_SERVICE" ]; then
  compose run --rm --no-deps "$PRE_DEPLOY_SERVICE" || abort "사전 작업 실패: $PRE_DEPLOY_SERVICE"
fi

# 5. 교체 · 검증
compose up -d "$SERVICE" || rollback "compose up 실패"
compose ps "$SERVICE"

cid=$(compose ps -q "$SERVICE")
[ -n "$cid" ] || rollback "컨테이너가 실행 중이 아니다"
running=$(docker inspect --format '{{.Config.Image}}' "$cid")
[ "$running" = "$IMAGE" ] || rollback "실행 중인 이미지가 배포 대상과 다르다 (기대 $IMAGE, 실제 $running)"
echo "이미지 확인: $running"

if [ -n "$HEALTH_URL" ]; then
  for i in $(seq 1 "$HEALTH_RETRIES"); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH_URL" || true)
    if [ "$code" = "200" ]; then
      echo "health OK after $i attempts"
      exit 0
    fi
    sleep 3
  done
  docker logs --tail 30 "$cid" 2>&1 | grep -v -E '^\s+at ' || true
  rollback "health check 실패: $HEALTH_URL"
fi