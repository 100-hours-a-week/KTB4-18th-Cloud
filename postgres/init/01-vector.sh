#!/usr/bin/env bash
set -Eeuo pipefail
: "${POSTGRES_APP_USER:?Set POSTGRES_APP_USER}"
: "${POSTGRES_APP_PASSWORD:?Set POSTGRES_APP_PASSWORD}"
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 \
  --set app_user="$POSTGRES_APP_USER" --set app_password="$POSTGRES_APP_PASSWORD" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'app_user', :'app_password') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO %I', current_database(), :'app_user') \gexec
SELECT format('GRANT USAGE, CREATE ON SCHEMA public TO %I', :'app_user') \gexec
SQL
