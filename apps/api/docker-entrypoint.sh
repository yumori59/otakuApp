#!/bin/sh
set -e

echo "Generating Prisma client..."
npx prisma generate

echo "Applying database schema..."
until npx prisma db push --accept-data-loss; do
  echo "Database not ready, retrying in 2s..."
  sleep 2
done

echo "Database schema is up to date."
exec "$@"
