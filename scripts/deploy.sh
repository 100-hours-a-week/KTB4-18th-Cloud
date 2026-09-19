#!/usr/bin/env bash
# Linux / Docker Compose >= 2.30.0 / AWS CLI / Python 3 / util-linux
set -Eeuo pipefail
umask 077
PROJECT_DIR="${PROJECT_DIR:-/opt/meomuneum}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
[[ $# == 3 ]] || { echo 'Usage: deploy.sh FRONTEND_IMAGE BACKEND_IMAGE AI_IMAGE' >&2; exit 2; }
images=("$1" "$2" "$3")
for image in "${images[@]}"; do
  [[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9/_-]+(:[a-f0-9]{40}|@sha256:[a-f0-9]{64})$ ]] || {
    echo 'Expected an ECR image with a full commit SHA or digest' >&2; exit 2;
  }
done
for cmd in docker aws python3 flock curl; do command -v "$cmd" >/dev/null; done
[[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ && "$DRAIN_SECONDS" =~ ^[0-9]+$ ]]
cd "$PROJECT_DIR"
mkdir -p .state .runtime
chmod 700 .state .runtime
exec 9>.state/deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
# Fail before changing a running service if the required raw env format is unsupported.
version=$(docker compose version --short)
python3 - "$version" <<'PY'
import re, sys
parts=tuple(map(int,re.findall(r'\d+',sys.argv[1])[:3]))
assert parts >= (2,30,0), 'Docker Compose >= 2.30.0 required'
PY
previous=''
if [[ -s .deploy.env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      ACTIVE_SLOT) [[ "$value" == blue || "$value" == green ]]; previous="$value" ;;
      FRONTEND_BLUE_IMAGE|FRONTEND_GREEN_IMAGE|BACKEND_BLUE_IMAGE|BACKEND_GREEN_IMAGE|AI_BLUE_IMAGE|AI_GREEN_IMAGE)
        [[ "$value" =~ ^[a-zA-Z0-9./:@_-]+$ ]]; export "$key=$value" ;;
      '') ;;
      *) echo "Unexpected state key: $key" >&2; exit 1 ;;
    esac
  done < .deploy.env
  [[ -n "$previous" ]]
fi
slot=blue
[[ "$previous" != blue ]] || slot=green
index=0
for service in frontend backend ai; do
  upper=$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')
  for color in blue green; do
    key="${upper}_$(printf '%s' "$color" | tr '[:lower:]' '[:upper:]')_IMAGE"
    if [[ "$color" == "$slot" || -z "${!key:-}" ]]; then export "$key=${images[$index]}"; fi
  done
  index=$((index+1))
done
compose() { docker compose --env-file /dev/null -f compose.yml "$@"; }
# Every service must have an env file for Compose model validation; unused slots stay empty.
for color in blue green; do
  for service in backend ai; do
    [[ -f ".runtime/$service-$color.env" ]] || touch ".runtime/$service-$color.env"
  done
done
# DB initialization credentials are persistent, not rotated by an application deploy.
for database in mysql postgres; do
  if [[ ! -s ".runtime/$database.env" ]]; then
    aws ssm get-parameters-by-path --region "$AWS_REGION" \
      --path "/meomuneum/v1/$database" --recursive --with-decryption --output json \
      | python3 scripts/ssm-env.py ".runtime/$database.env"
  fi
done
for service in backend ai; do
  aws ssm get-parameters-by-path --region "$AWS_REGION" \
    --path "/meomuneum/v1/$service" --recursive --with-decryption --output json \
    | python3 scripts/ssm-env.py ".runtime/$service-$slot.env"
done
python3 scripts/database-env.py .runtime "$slot"
for image in "${images[@]}"; do
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${image%%/*}"
done
compose config --quiet
# Databases are shared by both slots. Never recreate or stop them in an app deploy.
compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mysql postgres
compose pull "frontend-$slot" "backend-$slot" "ai-$slot" nginx ai-router
cp nginx/backend-upstream.conf .state/backend-upstream.previous
cp ai-router/default.conf .state/ai-router.previous
committed=false
switched=false
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$committed" != true ]]; then
    echo '[ERROR] Deployment failed; restoring previous routes' >&2
    if [[ "$switched" == true ]]; then
      cp .state/backend-upstream.previous nginx/backend-upstream.conf
      cp .state/ai-router.previous ai-router/default.conf
      if [[ -n "$previous" ]]; then
        # Keep both slots running if route restoration fails.
        if ! compose exec -T nginx nginx -t || ! compose exec -T nginx nginx -s reload \
          || ! compose exec -T ai-router nginx -t || ! compose exec -T ai-router nginx -s reload; then
          echo '[ERROR] Route rollback failed. Both slots retained for recovery.' >&2
          exit 1
        fi
      else
        compose stop nginx ai-router || true
      fi
    fi
    compose stop "frontend-$slot" "backend-$slot" "ai-$slot" || true
  fi
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" \
  "ai-$slot" "backend-$slot" "frontend-$slot"
# Directory mounts ensure atomic rename does not leave Nginx reading the old inode.
switched=true
printf 'upstream backend_active { server backend-%s:8080; }\nupstream frontend_active { server frontend-%s:8080; }\n' "$slot" "$slot" > nginx/backend-upstream.conf
printf 'upstream ai_active { server ai-%s:8000; }\nserver { listen 8000; location / { proxy_pass http://ai_active; proxy_read_timeout 120s; } }\n' "$slot" > ai-router/default.conf
compose up -d --no-deps nginx ai-router
compose exec -T ai-router nginx -t
compose exec -T nginx nginx -t
compose exec -T ai-router nginx -s reload
compose exec -T nginx nginx -s reload
# Mandatory checks through the actual proxies, with bounded retries.
curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/actuator/health >/dev/null
curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/ >/dev/null
compose exec -T ai-router wget -q -O /dev/null "http://127.0.0.1:8000${AI_HEALTH_PATH:-/health}"
for url in "${BACKEND_SMOKE_URL:-}" "${FRONTEND_SMOKE_URL:-}"; do
  [[ -z "$url" ]] || curl -fsS --max-time 15 "$url" >/dev/null
done
{
  for key in FRONTEND_BLUE_IMAGE FRONTEND_GREEN_IMAGE BACKEND_BLUE_IMAGE BACKEND_GREEN_IMAGE AI_BLUE_IMAGE AI_GREEN_IMAGE; do
    printf '%s=%s\n' "$key" "${!key}"
  done
  printf 'ACTIVE_SLOT=%s\n' "$slot"
} > .state/deploy.env.next
mv .state/deploy.env.next .deploy.env
committed=true
if [[ -n "$previous" ]]; then
  sleep "$DRAIN_SECONDS"
  compose stop -t 30 "frontend-$previous" "backend-$previous" "ai-$previous" || true
fi
echo "[SUCCESS] Active slot: $slot"
