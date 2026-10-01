#!/usr/bin/env bash
# 러너에서 실행된다. SSM 명령이 끝날 때까지 기다리고 출력과 결과를 남긴다.
set -euo pipefail

invocation() {
  aws ssm get-command-invocation --command-id "$COMMAND_ID" --instance-id "$INSTANCE_ID" "$@"
}

deadline=$(( $(date +%s) + COMMAND_TIMEOUT ))
while :; do
  status=$(invocation --query Status --output text)
  case "$status" in
    Pending|InProgress|Delayed) ;;
    *) break ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::error::SSM 명령이 ${COMMAND_TIMEOUT}초 안에 끝나지 않았다 (마지막 상태 ${status})"
    exit 1
  fi
  sleep 5
done

invocation --query '{Status:Status,ResponseCode:ResponseCode}' --output table
echo "--- stdout ---"
invocation --query StandardOutputContent --output text
echo "--- stderr ---"
invocation --query StandardErrorContent --output text

code=$(invocation --query ResponseCode --output text)
if [ "$status" != "Success" ] || [ "$code" != "0" ]; then
  echo "::error::배포 실패 (Status ${status}, ResponseCode ${code})"
  exit 1
fi
