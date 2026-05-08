#!/bin/sh
set -e

echo "Waiting for PostgreSQL at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 30); do
  if python -c "import psycopg2; psycopg2.connect(host='${DB_HOST}', port=${DB_PORT}, dbname='${DB_NAME}', user='${DB_USER}', password='${DB_PASSWORD}')" 2>/dev/null; then
    echo "PostgreSQL is ready."
    break
  fi
  echo "  attempt $i/30 — retrying in 2s..."
  sleep 2
done

exec "$@"
