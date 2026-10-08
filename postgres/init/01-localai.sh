#!/bin/sh
# Runs once on first start of the postgres volume: separate DB + role for LocalAI auth data.
set -eu
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v pw="$LOCALAI_DB_PASS" <<'SQL'
CREATE ROLE localai LOGIN PASSWORD :'pw';
CREATE DATABASE localai OWNER localai;
SQL
