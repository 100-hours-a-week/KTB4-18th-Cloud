#!/usr/bin/env bash
# Linux / Docker Compose >= 2.30.0 / AWS CLI / Python 3 / util-linux
# FE·BE는 서비스별 Blue/Green, AI는 단일 교체 방식으로 배포합니다.
set -Eeuo pipefail
umask 077

# Defaults
PROJECT_DIR="${PROJECT_DIR:-/opt/meomuneum}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
MIN_AVAILABLE_MEMORY_MB="${MIN_AVAILABLE_MEMORY_MB:-1024}"
MIN_AVAILABLE_DISK_MB="${MIN_AVAILABLE_DISK_MB:-2048}"

# Input validation
[[ $# == 2 ]] || { echo 'Usage: deploy.sh frontend|backend|ai IMAGE' >&2; exit 2; }
service="$1"; image="$2"
[[ "$service" == frontend || "$service" == backend || "$service" == ai ]] || { echo 'Service must be frontend, backend, or ai' >&2; exit 2; }

[[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9/_-]+(:[a-f0-9]{40}-[a-f0-9]{12}|@sha256:[a-f0-9]{64})$ ]] || {
  echo 'Expected an ECR image with a source-cloud commit tag or digest' >&2; exit 2;
}

for cmd in docker aws python3 flock curl; do command -v "$cmd" >/dev/null; done

[[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ && "$DRAIN_SECONDS" =~ ^[0-9]+$ ]]
[[ "$MIN_AVAILABLE_MEMORY_MB" =~ ^[1-9][0-9]*$ && "$MIN_AVAILABLE_DISK_MB" =~ ^[1-9][0-9]*$ ]]

# Runtime setup
cd "$PROJECT_DIR"
mkdir -p .state .runtime
chmod 700 .state .runtime
exec 9>.state/deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; } # 중복 배포 방지

version=$(docker compose version --short)
python3 - "$version" <<'PY'
import re, sys
parts=tuple(map(int,re.findall(r'\d+',sys.argv[1])[:3]))
assert parts >= (2,30,0), 'Docker Compose >= 2.30.0 required'
PY

# Compose validation needs an image value for slots that have not been deployed yet.
for name in FRONTEND BACKEND; do
  for color in BLUE GREEN; do
    key="${name}_${color}_IMAGE"; export "$key=nginx:1.28-alpine"
  done
done
export AI_IMAGE=nginx:1.28-alpine

frontend_active=''; backend_active=''; previous_ai_image=''

if [[ -s .deploy.env ]]; then
  while IFS='=' read -r key value; do
    case "$key" in
      ACTIVE_FRONTEND_SLOT) [[ "$value" == blue || "$value" == green ]]; frontend_active="$value" ;;
      ACTIVE_BACKEND_SLOT) [[ "$value" == blue || "$value" == green ]]; backend_active="$value" ;;
      FRONTEND_BLUE_IMAGE|FRONTEND_GREEN_IMAGE|BACKEND_BLUE_IMAGE|BACKEND_GREEN_IMAGE)
        [[ "$value" =~ ^[a-zA-Z0-9./:@_-]+$ ]]; export "$key=$value" ;;
      AI_IMAGE) [[ "$value" =~ ^[a-zA-Z0-9./:@_-]+$ ]]; AI_IMAGE="$value"; previous_ai_image="$value"; export AI_IMAGE ;;
      '') ;;
      *) echo "Unexpected state key: $key" >&2; exit 1 ;;
    esac
  done < .deploy.env
fi

compose() { docker compose --env-file /dev/null -f compose.yml "$@"; }

for color in blue green; do [[ -f ".runtime/backend-$color.env" ]] || touch ".runtime/backend-$color.env"; done
[[ -f .runtime/ai.env ]] || touch .runtime/ai.env

# Target slot and runtime environment
slot='single'; previous=''
if [[ "$service" != ai ]]; then
  active_var="${service}_active"; previous="${!active_var}"
  slot=blue; [[ "$previous" != blue ]] || slot=green
  upper=$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')
  slot_upper=$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')
  image_key="${upper}_${slot_upper}_IMAGE"; export "$image_key=$image"
else
  AI_IMAGE="$image"; export AI_IMAGE
fi

if [[ "$service" == backend || "$service" == ai ]]; then
  database=mysql; [[ "$service" != ai ]] || database=postgres
  if [[ ! -s ".runtime/$database.env" ]]; then
    aws ssm get-parameters-by-path --region "$AWS_REGION" --path "/meomuneum/v1/$database" \
      --recursive --with-decryption --output json | python3 deploy/scripts/ssm-env.py ".runtime/$database.env"
  fi
  runtime_env=".runtime/$service-$slot.env"; [[ "$service" != ai ]] || runtime_env=.runtime/ai.env
  aws ssm get-parameters-by-path --region "$AWS_REGION" --path "/meomuneum/v1/$service" \
    --recursive --with-decryption --output json | python3 deploy/scripts/ssm-env.py "$runtime_env"
  python3 deploy/scripts/database-env.py .runtime "$slot" "$service"
fi

# Preflight checks
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${image%%/*}"
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

# Start dependencies and pull the release image.
if [[ "$service" == backend ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mysql
elif [[ "$service" == ai ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" postgres
fi

target="$service-$slot"; [[ "$service" != ai ]] || target=ai
compose pull "$target"

committed=false; switched=false; route=deploy/nginx/backend-upstream.conf
[[ "$service" == ai ]] || cp "$route" .state/backend-upstream.conf.previous

# Restore the last healthy route or image when deployment fails.
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$committed" != true ]]; then
    echo "[ERROR] $service deployment failed; restoring previous state" >&2
    if [[ "$service" == ai ]]; then
      if [[ -n "$previous_ai_image" ]]; then
        AI_IMAGE="$previous_ai_image"; export AI_IMAGE
        compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" ai || true
      else
        compose stop ai || true
      fi
    else
      if [[ "$switched" == true ]]; then
        cp .state/backend-upstream.conf.previous "$route"
        if compose exec -T nginx nginx -t; then compose exec -T nginx nginx -s reload || true; fi
      fi
      compose stop "$target" || true
    fi
  fi
  exit "$status"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Deploy and verify
compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$target"

if [[ "$service" == ai ]]; then
  compose exec -T ai python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8001/readiness', timeout=3)"
else
  if [[ "$service" == frontend ]]; then frontend_active="$slot"; else backend_active="$slot"; fi

  # The first route is created only after both frontend and backend are available.
  if [[ -n "$frontend_active" && -n "$backend_active" ]]; then
    switched=true
    printf 'upstream backend_active { server backend-%s:8080; }\nupstream frontend_active { server frontend-%s:8080; }\n' \
      "$backend_active" "$frontend_active" > "$route"

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
fi

# Commit state only after every check passes.
{
  for key in FRONTEND_BLUE_IMAGE FRONTEND_GREEN_IMAGE BACKEND_BLUE_IMAGE BACKEND_GREEN_IMAGE; do printf '%s=%s\n' "$key" "${!key}"; done
  printf 'AI_IMAGE=%s\n' "$AI_IMAGE"
  [[ -z "$frontend_active" ]] || printf 'ACTIVE_FRONTEND_SLOT=%s\n' "$frontend_active"
  [[ -z "$backend_active" ]] || printf 'ACTIVE_BACKEND_SLOT=%s\n' "$backend_active"
} > .state/deploy.env.next
mv .state/deploy.env.next .deploy.env
committed=true

if [[ "$service" != ai && -n "$previous" ]]; then
  sleep "$DRAIN_SECONDS"
  compose stop -t 30 "$service-$previous" || true
fi

echo "[SUCCESS] $service deployed"
