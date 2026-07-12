#!/bin/sh
# ============================================================
# Provision a database + dedicated role for an application.
#   ./create-app-db.sh <app_name> <password>
# Example: ./create-app-db.sh gymmate 'S3cureP@ss'
# Creates: role "gymmate" owning database "gymmate_db"
# Idempotent — safe to re-run.
# ============================================================
set -eu

APP="$1"
PASS="$2"
DB="${APP}_db"
SUPER="${POSTGRES_SUPERUSER:-postgres}"

docker exec -i postgres psql -U "$SUPER" -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${APP}') THEN
      CREATE ROLE ${APP} LOGIN PASSWORD '${PASS}';
   ELSE
      ALTER ROLE ${APP} WITH LOGIN PASSWORD '${PASS}';
   END IF;
END
\$\$;
SELECT 'CREATE DATABASE ${DB} OWNER ${APP}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB}')\gexec
REVOKE ALL ON DATABASE ${DB} FROM PUBLIC;
GRANT ALL PRIVILEGES ON DATABASE ${DB} TO ${APP};
SQL

# PG15+ no longer grants CREATE on schema public to the db owner implicitly.
# Hand the app role ownership of its own public schema so migrations
# (EF Core / Flyway) can create objects.
docker exec -i postgres psql -U "$SUPER" -v ON_ERROR_STOP=1 -d "$DB" <<SQL
GRANT ALL ON SCHEMA public TO ${APP};
ALTER SCHEMA public OWNER TO ${APP};
SQL

echo "OK: database '${DB}' owned by role '${APP}'."
echo "    Host=postgres;Port=5432;Database=${DB};Username=${APP};Password=***"
