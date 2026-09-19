# syntax=docker/dockerfile:1
FROM ghcr.io/astral-sh/uv:0.8.22 AS uv
FROM python:3.12-slim
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 UV_LINK_MODE=copy PATH="/app/.venv/bin:$PATH"
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY . .
# 현재 upstream에는 ASGI 코드가 없음. 구현 후 실제 module:object 지정.
ARG AI_APP_MODULE=main:app
ENV AI_APP_MODULE=${AI_APP_MODULE}
RUN python -c "import importlib,os; m,a=os.environ['AI_APP_MODULE'].split(':'); assert callable(getattr(importlib.import_module(m),a))"
USER 10001:10001
EXPOSE 8000
CMD ["sh", "-c", "exec uvicorn \"$AI_APP_MODULE\" --host 0.0.0.0 --port 8000"]
