#!/usr/bin/env bash
# Linux / Docker Compose >= 2.30.0 / AWS CLI / Python 3 / util-linux
set -Eeuo pipefail
umask 077
PROJECT_DIR="${PROJECT_DIR:-/opt/meomuneum}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
MIN_AVAILABLE_MEMORY_MB="${MIN_AVAILABLE_MEMORY_MB:-1024}"
MIN_AVAILABLE_DISK_MB="${MIN_AVAILABLE_DISK_MB:-2048}"
[[ $# == 2 ]] || { echo 'Usage: deploy.sh frontend|backend|ai IMAGE' >&2; exit 2; }
service="$1"
image="$2"
[[ "$service" == frontend || "$service" == backend || "$service" == ai ]] || {
  echo 'Service must be frontend, backend, or ai' >&2; exit 2;
}
[[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9/_-]+(:[a-f0-9]{40}|@sha256:[a-f0-9]{64})$ ]] || {
  echo 'Expected an ECR image with a full commit SHA or digest' >&2; exit 2;
}
for cmd in docker aws python3 flock curl; do command -v "$cmd" >/dev/null; done
[[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ && "$DRAIN_SECONDS" =~ ^[0-9]+$ ]]
[[ "$MIN_AVAILABLE_MEMORY_MB" =~ ^[1-9][0-9]*$ && "$MIN_AVAILABLE_DISK_MB" =~ ^[1-9][0-9]*$ ]]
cd "$PROJECT_DIR"
mkdir -p .state .runtime
chmod 700 .state .runtime
exec 9>.state/deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }

version=$(docker compose version --short)
python3 - "$version" <<'PY'
import re, sys
parts=tuple(map(int,re.findall(r'\d+',sys.argv[1])[:3]))
assert parts >= (2,30,0), 'Docker Compose >= 2.30.0 required'
PY

for name in FRONTEND BACKEND AI; do
  for color in BLUE GREEN; do
    key="${name}_${color}_IMAGE"
    export "$key=nginx:1.28-alpine"
  done
done
frontend_active=''
backend_active=''
ai_active=''
if [[ -s .deploy.env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      ACTIVE_FRONTEND_SLOT) [[ "$value" == blue || "$value" == green ]]; frontend_active="$value" ;;
      ACTIVE_BACKEND_SLOT) [[ "$value" == blue || "$value" == green ]]; backend_active="$value" ;;
      ACTIVE_AI_SLOT) [[ "$value" == blue || "$value" == green ]]; ai_active="$value" ;;
      ACTIVE_SLOT)
        [[ "$value" == blue || "$value" == green ]]
        frontend_active="$value"; backend_active="$value"; ai_active="$value"
        ;;
      FRONTEND_BLUE_IMAGE|FRONTEND_GREEN_IMAGE|BACKEND_BLUE_IMAGE|BACKEND_GREEN_IMAGE|AI_BLUE_IMAGE|AI_GREEN_IMAGE)
        [[ "$value" =~ ^[a-zA-Z0-9./:@_-]+$ ]]; export "$key=$value" ;;
      '') ;;
      *) echo "Unexpected state key: $key" >&2; exit 1 ;;
    esac
  done < .deploy.env
fi

upper=$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')
active_var="${service}_active"
previous="${!active_var}"
slot=blue
[[ "$previous" != blue ]] || slot=green
slot_upper=$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')
image_key="${upper}_${slot_upper}_IMAGE"
export "$image_key=$image"

compose() { docker compose --env-file /dev/null -f compose.yml "$@"; }
for color in blue green; do
  for app in backend ai; do
    [[ -f ".runtime/$app-$color.env" ]] || touch ".runtime/$app-$color.env"
  done
done

if [[ "$service" == backend || "$service" == ai ]]; then
  database=mysql
  [[ "$service" != ai ]] || database=postgres
  if [[ ! -s ".runtime/$database.env" ]]; then
    aws ssm get-parameters-by-path --region "$AWS_REGION" \
      --path "/meomuneum/v1/$database" --recursive --with-decryption --output json \
      | python3 scripts/ssm-env.py ".runtime/$database.env"
  fi
  aws ssm get-parameters-by-path --region "$AWS_REGION" \
    --path "/meomuneum/v1/$service" --recursive --with-decryption --output json \
    | python3 scripts/ssm-env.py ".runtime/$service-$slot.env"
  python3 scripts/database-env.py .runtime "$slot" "$service"
fi

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "${image%%/*}"
compose config --quiet
docker info >/dev/null
disk_available=$(df -Pm "$PROJECT_DIR" | awk 'NR == 2 {print $4}')
[[ "$disk_available" =~ ^[0-9]+$ && "$disk_available" -ge "$MIN_AVAILABLE_DISK_MB" ]] || {
  echo "Available disk is below ${MIN_AVAILABLE_DISK_MB}MB" >&2; exit 1;
}
if [[ -r /proc/meminfo ]]; then
  memory_available=$(awk '/^MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo)
  [[ "$memory_available" =~ ^[0-9]+$ && "$memory_available" -ge "$MIN_AVAILABLE_MEMORY_MB" ]] || {
    echo "Available memory is below ${MIN_AVAILABLE_MEMORY_MB}MB" >&2; exit 1;
  }
fi
if [[ "$service" == backend ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mysql
elif [[ "$service" == ai ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" postgres
fi
compose pull "$service-$slot"

route=nginx/backend-upstream.conf
[[ "$service" != ai ]] || route=ai-router/default.conf
cp "$route" ".state/$(basename "$route").previous"
committed=false
switched=false
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$committed" != true ]]; then
    echo "[ERROR] $service deployment failed; restoring previous route" >&2
    if [[ "$switched" == true ]]; then
      cp ".state/$(basename "$route").previous" "$route"
      if [[ "$service" == ai && -n "$previous" ]]; then
        compose exec -T ai-router nginx -t && compose exec -T ai-router nginx -s reload || true
      elif [[ "$service" != ai && -n "$previous" ]]; then
        compose exec -T nginx nginx -t && compose exec -T nginx nginx -s reload || true
      fi
    fi
    compose stop "$service-$slot" || true
  fi
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$service-$slot"
if [[ "$service" == frontend ]]; then
  frontend_active="$slot"
elif [[ "$service" == backend ]]; then
  backend_active="$slot"
else
  ai_active="$slot"
fi

if [[ "$service" == ai ]]; then
  switched=true
  printf 'upstream ai_active { server ai-%s:8001; }\nserver { listen 8001; location / { proxy_pass http://ai_active; proxy_read_timeout 120s; } }\n' "$slot" > ai-router/default.conf
  compose up -d --no-deps ai-router
  compose exec -T ai-router nginx -t
  compose exec -T ai-router nginx -s reload
  compose exec -T ai-router wget -q -O /dev/null "http://127.0.0.1:8001${AI_HEALTH_PATH:-/health}"
elif [[ -n "$frontend_active" && -n "$backend_active" ]]; then
  switched=true
  printf 'upstream backend_active { server backend-%s:8080; }\nupstream frontend_active { server frontend-%s:8080; }\n' "$backend_active" "$frontend_active" > nginx/backend-upstream.conf
  compose up -d --no-deps nginx
  compose exec -T nginx nginx -t
  compose exec -T nginx nginx -s reload
  if [[ "$service" == backend ]]; then
    curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/actuator/health >/dev/null
    [[ -z "${BACKEND_SMOKE_URL:-}" ]] || curl -fsS --max-time 15 "$BACKEND_SMOKE_URL" >/dev/null
  else
    curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/ >/dev/null
    [[ -z "${FRONTEND_SMOKE_URL:-}" ]] || curl -fsS --max-time 15 "$FRONTEND_SMOKE_URL" >/dev/null
  fi
fi

{
  for key in FRONTEND_BLUE_IMAGE FRONTEND_GREEN_IMAGE BACKEND_BLUE_IMAGE BACKEND_GREEN_IMAGE AI_BLUE_IMAGE AI_GREEN_IMAGE; do
    printf '%s=%s\n' "$key" "${!key}"
  done
  [[ -z "$frontend_active" ]] || printf 'ACTIVE_FRONTEND_SLOT=%s\n' "$frontend_active"
  [[ -z "$backend_active" ]] || printf 'ACTIVE_BACKEND_SLOT=%s\n' "$backend_active"
  [[ -z "$ai_active" ]] || printf 'ACTIVE_AI_SLOT=%s\n' "$ai_active"
} > .state/deploy.env.next
mv .state/deploy.env.next .deploy.env
committed=true
if [[ -n "$previous" ]]; then
  sleep "$DRAIN_SECONDS"
  compose stop -t 30 "$service-$previous" || true
fi
echo "[SUCCESS] $service active slot: $slot"
