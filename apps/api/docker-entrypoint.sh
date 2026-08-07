#!/bin/sh
set -e

echo "Generating Prisma client..."
npx prisma generate

if [ "$NODE_ENV" = "production" ]; then
  echo "NODE_ENV=production: skipping automatic 'prisma db push' at container start."
  echo "Apply schema changes explicitly (prisma migrate deploy / db push) before deploying."
else
  echo "Applying database schema..."
  until npx prisma db push --accept-data-loss; do
    echo "Database not ready, retrying in 2s..."
    sleep 2
  done
  echo "Database schema is up to date."
fi

exec "$@"
