#!/bin/bash
# Creates the hiddenxi database and its two roles. Runs as the postgres superuser,
# because temp_file_limit can only be set by a superuser.
# See docs/04-sandbox-security.md §4. Football grants are added by Flyway (V3).
set -euo pipefail

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres \
  -v owner_password="$HIDDENXI_OWNER_PASSWORD" \
  -v sandbox_password="$HIDDENXI_SANDBOX_PASSWORD" <<'EOSQL'
CREATE ROLE hiddenxi_owner LOGIN PASSWORD :'owner_password';
CREATE DATABASE hiddenxi OWNER hiddenxi_owner;

CREATE ROLE hiddenxi_sandbox LOGIN PASSWORD :'sandbox_password'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT CONNECTION LIMIT 10;
GRANT CONNECT ON DATABASE hiddenxi TO hiddenxi_sandbox;
ALTER ROLE hiddenxi_sandbox SET default_transaction_read_only = on;
ALTER ROLE hiddenxi_sandbox SET statement_timeout = '3s';
ALTER ROLE hiddenxi_sandbox SET idle_in_transaction_session_timeout = '5s';
ALTER ROLE hiddenxi_sandbox SET search_path = football;
ALTER ROLE hiddenxi_sandbox SET work_mem = '16MB';
ALTER ROLE hiddenxi_sandbox SET temp_file_limit = '64MB';

\connect hiddenxi
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
EOSQL
