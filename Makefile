.PHONY: up down logs db-only api-dev prisma-push health

COMPOSE_PROJECT_NAME ?= meigicho

# Docker Compose（DB + API）
up:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) docker compose up --build -d

down:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) docker compose down

logs:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) docker compose logs -f api db

# DB のみ起動（ホストで API を開発する場合）
db-only:
	COMPOSE_PROJECT_NAME=$(COMPOSE_PROJECT_NAME) docker compose up -d db

# ホストで NestJS を watch 起動（要: make db-only と npm install）
api-dev:
	cd apps/api && cp -n .env.example .env 2>/dev/null || true && npm run start:dev

# スキーマを DB に反映
prisma-push:
	cd apps/api && cp -n .env.example .env 2>/dev/null || true && npm run prisma:push

health:
	curl -s http://localhost:8080/health | cat
	@echo ""
	curl -s http://localhost:8080/readyz | cat
	@echo ""
