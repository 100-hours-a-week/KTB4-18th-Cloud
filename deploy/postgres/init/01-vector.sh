#!/usr/bin/env bash
# 빈 PostgreSQL volume을 처음 만들 때 pgvector와 AI 일반 계정을 준비합니다.
# docker-entrypoint-initdb.d 특성상 기존 volume에는 다시 실행되지 않습니다.
set -Eeuo pipefail
: "${POSTGRES_APP_USER:?Set POSTGRES_APP_USER}"
: "${POSTGRES_APP_PASSWORD:?Set POSTGRES_APP_PASSWORD}"
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 \
  --set app_user="$POSTGRES_APP_USER" --set app_password="$POSTGRES_APP_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
-- 관리자 계정과 분리된 AI 애플리케이션 로그인 계정을 생성합니다.
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'app_user') \gexec
SQL
