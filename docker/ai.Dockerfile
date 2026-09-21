# syntax=docker/dockerfile:1
# Cloud 저장소에서 AI 소스를 이미지로 만드는 전용 Dockerfile입니다.
# uv 바이너리만 공식 이미지에서 가져오고 Python runtime은 별도로 구성합니다.
FROM ghcr.io/astral-sh/uv:0.8.22 AS uv
FROM python:3.12-slim
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_LINK_MODE=copy PATH="/app/.venv/bin:$PATH"
COPY pyproject.toml uv.lock ./
# CHANGED: uv 다운로드 cache를 재사용하되 운영 dependency만 설치합니다.
RUN --mount=type=cache,target=/root/.cache/uv uv sync --frozen --no-dev --no-install-project
COPY . .
# AI 앱의 실제 ASGI module:object. CI 입력으로 override할 수 있습니다.
ARG AI_APP_MODULE=backend.main:app
ENV AI_APP_MODULE=${AI_APP_MODULE}
RUN python -c "import importlib,os; m,a=os.environ['AI_APP_MODULE'].split(':'); assert callable(getattr(importlib.import_module(m),a))"
# CHANGED: 숫자 UID/GID를 명시적으로 생성하고 앱 디렉터리 권한을 제한합니다.
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid 10001 app && chown -R app:app /app
USER 10001:10001
EXPOSE 8001
# CHANGED: readiness가 PostgreSQL과 필수 테이블까지 확인하므로 배포 판정에 사용합니다.
HEALTHCHECK --interval=10s --timeout=4s --start-period=30s --retries=12 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8001/readiness', timeout=3)" || exit 1
ENV UVICORN_WORKERS=1
CMD ["sh", "-c", "exec uvicorn \"$AI_APP_MODULE\" --host 0.0.0.0 --port 8001 --workers \"$UVICORN_WORKERS\""]
