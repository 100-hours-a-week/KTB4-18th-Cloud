#!/usr/bin/env bash
# Linux / Docker Compose >= 2.30.0 / AWS CLI / Python 3 / util-linux
# CHANGED: FE·BE는 서비스별 Blue/Green, AI는 router 없는 단일 교체 배포입니다.
set -Eeuo pipefail
umask 077

# =====================================================================
# 1. 환경 변수 및 설정 기본값 정의
# =====================================================================
PROJECT_DIR="${PROJECT_DIR:-/opt/meomuneum}"
AWS_REGION="${AWS_REGION:-ap-northeast-2}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
DRAIN_SECONDS="${DRAIN_SECONDS:-30}"
MIN_AVAILABLE_MEMORY_MB="${MIN_AVAILABLE_MEMORY_MB:-1024}"
MIN_AVAILABLE_DISK_MB="${MIN_AVAILABLE_DISK_MB:-2048}"

# =====================================================================
# 2. 인자(Arguments) 검증 및 형식 체크
# =====================================================================
[[ $# == 2 ]] || { echo 'Usage: deploy.sh frontend|backend|ai IMAGE' >&2; exit 2; }
service="$1"; image="$2"
[[ "$service" == frontend || "$service" == backend || "$service" == ai ]] || { echo 'Service must be frontend, backend, or ai' >&2; exit 2; }

# ECR 이미지 주소 및 커밋 SHA/digest 형식이 올바른지 정규식 검증
[[ "$image" =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9/_-]+(:[a-f0-9]{40}|@sha256:[a-f0-9]{64})$ ]] || {
  echo 'Expected an ECR image with a full commit SHA or digest' >&2; exit 2;
}

# 필수 시스템 명령어 존재 여부 확인
for cmd in docker aws python3 flock curl; do command -v "$cmd" >/dev/null; done

# 주요 설정값들이 올바른 숫자 형식인지 확인
[[ "$HEALTH_TIMEOUT" =~ ^[1-9][0-9]*$ && "$DRAIN_SECONDS" =~ ^[0-9]+$ ]]
[[ "$MIN_AVAILABLE_MEMORY_MB" =~ ^[1-9][0-9]*$ && "$MIN_AVAILABLE_DISK_MB" =~ ^[1-9][0-9]*$ ]]

# =====================================================================
# 3. 배포 동시성 제어 (Locking)
# =====================================================================
cd "$PROJECT_DIR"
mkdir -p .state .runtime
chmod 700 .state .runtime
exec 9>.state/deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; } # 중복 배포 방지

# Docker Compose 버전이 2.30.0 이상인지 파이썬으로 검증
version=$(docker compose version --short)
python3 - "$version" <<'PY'
import re, sys
parts=tuple(map(int,re.findall(r'\d+',sys.argv[1])[:3]))
assert parts >= (2,30,0), 'Docker Compose >= 2.30.0 required'
PY

# =====================================================================
# 4. 기존 상태 로드 및 컴포즈 검증용 Placeholder 설정
# =====================================================================
# 아직 배포되지 않은 슬롯은 Compose 모델 검사용 placeholder 이미지로 채움
for name in FRONTEND BACKEND; do
  for color in BLUE GREEN; do
    key="${name}_${color}_IMAGE"; export "$key=nginx:1.28-alpine"
  done
done
export AI_IMAGE=nginx:1.28-alpine

frontend_active=''; backend_active=''; previous_ai_image=''

# 이전 배포 상태(.deploy.env)가 있다면 읽어와서 슬롯 및 이미지 정보 복원
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

# 도커 컴포즈 실행 래퍼 함수 정의 (--env-file을 비워 독립성 유지)
compose() { docker compose --env-file /dev/null -f compose.yml "$@"; }

# 런타임 환경변수 파일들이 없으면 빈 파일로 생성
for color in blue green; do [[ -f ".runtime/backend-$color.env" ]] || touch ".runtime/backend-$color.env"; done
[[ -f .runtime/ai.env ]] || touch .runtime/ai.env

# =====================================================================
# 5. 배포 대상 슬롯 결정 및 SSM 환경변수 동기화
# =====================================================================
slot='single'; previous=''
if [[ "$service" != ai ]]; then
  # 프론트엔드 또는 백엔드인 경우 Blue/Green 교차 선택
  active_var="${service}_active"; previous="${!active_var}"
  slot=blue; [[ "$previous" != blue ]] || slot=green
  upper=$(printf '%s' "$service" | tr '[:lower:]' '[:upper:]')
  slot_upper=$(printf '%s' "$slot" | tr '[:lower:]' '[:upper:]')
  image_key="${upper}_${slot_upper}_IMAGE"; export "$image_key=$image"
else
  # AI는 단일 배포 대상이므로 이미지 직접 지정
  AI_IMAGE="$image"; export AI_IMAGE
fi

# AWS SSM Parameter Store에서 최신 환경변수 가져오기 (필요한 경우)
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

# =====================================================================
# 6. ECR 로그인, 컴포즈 문법 검증 및 시스템 자원(디스크/메모리) 체크
# =====================================================================
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${image%%/*}"
compose config --quiet
docker info >/dev/null

# 여유 디스크 용량 확인
disk_available=$(df -Pm "$PROJECT_DIR" | awk 'NR == 2 {print $4}')
[[ "$disk_available" =~ ^[0-9]+$ && "$disk_available" -ge "$MIN_AVAILABLE_DISK_MB" ]] || {
  echo "Available disk is below ${MIN_AVAILABLE_DISK_MB}MB" >&2; exit 1;
}

# 여유 메모리 용량 확인
if [[ -r /proc/meminfo ]]; then
  memory_available=$(awk '/^MemAvailable:/ {printf "%d", $2 / 1024}' /proc/meminfo)
  [[ "$memory_available" =~ ^[0-9]+$ && "$memory_available" -ge "$MIN_AVAILABLE_MEMORY_MB" ]] || {
    echo "Available memory is below ${MIN_AVAILABLE_MEMORY_MB}MB" >&2; exit 1;
  }
fi

# =====================================================================
# 7. 의존 서비스(DB) 기동 및 새 이미지 Pull
# =====================================================================
if [[ "$service" == backend ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" mysql
elif [[ "$service" == ai ]]; then
  compose up -d --no-recreate --wait --wait-timeout "$HEALTH_TIMEOUT" postgres
fi

target="$service-$slot"; [[ "$service" != ai ]] || target=ai
compose pull "$target"

committed=false; switched=false; route=deploy/nginx/backend-upstream.conf
[[ "$service" == ai ]] || cp "$route" .state/backend-upstream.conf.previous

# =====================================================================
# 8. 자동 롤백(Rollback) 함수 및 트랩(Trap) 설정
# =====================================================================
rollback() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$committed" != true ]]; then
    echo "[ERROR] $service deployment failed; restoring previous state" >&2
    if [[ "$service" == ai ]]; then
      # AI 배포 실패 시 이전 이미지로 복구 또는 중지
      if [[ -n "$previous_ai_image" ]]; then
        AI_IMAGE="$previous_ai_image"; export AI_IMAGE
        compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" ai || true
      else
        compose stop ai || true
      fi
    else
      # FE/BE 배포 실패 시 Nginx 업스트림 설정 복원 후 리로드
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

# =====================================================================
# 9. 신규 컨테이너 실행 및 Health / Readiness 검증
# =====================================================================
compose up -d --no-deps --wait --wait-timeout "$HEALTH_TIMEOUT" "$target"

if [[ "$service" == ai ]]; then
  # AI는 별도의 readiness 엔드포인트(DB 연결 및 음악 트랙/말뭉치 통계 준비 상태) 호출 검증
  compose exec -T ai python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8001/readiness', timeout=3)"
else
  # FE 또는 BE 슬롯 갱신
  if [[ "$service" == frontend ]]; then frontend_active="$slot"; else backend_active="$slot"; fi

  # FE와 BE 둘 다 최신 상태 조합이 맞춰졌을 때 Nginx 라우팅 전환 수행
  if [[ -n "$frontend_active" && -n "$backend_active" ]]; then
    switched=true
    printf 'upstream backend_active { server backend-%s:8080; }\nupstream frontend_active { server frontend-%s:8080; }\n' \
      "$backend_active" "$frontend_active" > "$route"

    compose up -d --no-deps nginx
    compose exec -T nginx nginx -t
    compose exec -T nginx nginx -s reload

    # 전환 후 헬스 체크 및 스모크 테스트 실행
    if [[ "$service" == backend ]]; then
      curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/actuator/health >/dev/null
      [[ -z "${BACKEND_SMOKE_URL:-}" ]] || curl -fsS --max-time 15 "$BACKEND_SMOKE_URL" >/dev/null
    else
      curl -fsS --retry 10 --retry-connrefused --retry-delay 2 --max-time 5 http://127.0.0.1/ >/dev/null
      [[ -z "${FRONTEND_SMOKE_URL:-}" ]] || curl -fsS --max-time 15 "$FRONTEND_SMOKE_URL" >/dev/null
    fi
  fi
fi

# =====================================================================
# 10. 배포 성공 처리 (상태 저장, 기존 슬롯 드레인 및 정리)
# =====================================================================
{
  for key in FRONTEND_BLUE_IMAGE FRONTEND_GREEN_IMAGE BACKEND_BLUE_IMAGE BACKEND_GREEN_IMAGE; do printf '%s=%s\n' "$key" "${!key}"; done
  printf 'AI_IMAGE=%s\n' "$AI_IMAGE"
  [[ -z "$frontend_active" ]] || printf 'ACTIVE_FRONTEND_SLOT=%s\n' "$frontend_active"
  [[ -z "$backend_active" ]] || printf 'ACTIVE_BACKEND_SLOT=%s\n' "$backend_active"
} > .state/deploy.env.next
mv .state/deploy.env.next .deploy.env
committed=true

# 이전 슬롯에 대한 트래픽 드레인 대기 후 안전하게 종료
if [[ "$service" != ai && -n "$previous" ]]; then
  sleep "$DRAIN_SECONDS"
  compose stop -t 30 "$service-$previous" || true
fi

echo "[SUCCESS] $service deployed"
