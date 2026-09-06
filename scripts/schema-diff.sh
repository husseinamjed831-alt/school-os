#!/usr/bin/env bash
# HAMURA — schema diff: Production <-> Staging <-> Repo migrations.
# Requires: psql, and connection strings for prod + staging (Session pooler).
# Never runs DDL. Read-only pg_dump --schema-only.
#
#   PROD_DB_URL=...  STAGING_DB_URL=...  ./scripts/schema-diff.sh
#
set -euo pipefail

OUT=${OUT:-./_schema-diff}
mkdir -p "$OUT"

dump() { # $1 url  $2 label
  pg_dump --schema-only --no-owner --no-privileges \
    --schema=public --schema=auth \
    "$1" \
  | sed -E 's/^-- Dumped .*$//' > "$OUT/$2.sql"
  echo "wrote $OUT/$2.sql"
}

# 1. Repo baseline: apply sql/001..NNN to a scratch local PG, dump it.
if [ -n "${LOCAL_SCRATCH_URL:-}" ]; then
  for f in $(ls sql/0*.sql | sort); do
    case "$f" in *_rollback.sql) continue;; esac
    psql -v ON_ERROR_STOP=1 "$LOCAL_SCRATCH_URL" -f "$f" >/dev/null
  done
  dump "$LOCAL_SCRATCH_URL" repo
fi

[ -n "${PROD_DB_URL:-}" ]    && dump "$PROD_DB_URL"    prod
[ -n "${STAGING_DB_URL:-}" ] && dump "$STAGING_DB_URL" staging

echo
echo "=== prod vs staging ==="
diff -u "$OUT/prod.sql" "$OUT/staging.sql" || true
echo
echo "=== staging vs repo ==="
[ -f "$OUT/repo.sql" ] && { diff -u "$OUT/staging.sql" "$OUT/repo.sql" || true; }
echo
echo "A representative staging clone => 'prod vs staging' is empty."
