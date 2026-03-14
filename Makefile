.DEFAULT_GOAL := help

COMPOSE_DEV     = docker compose -f docker-compose.dev.yml --env-file .env.dev
COMPOSE_STAGING = docker compose -f docker-compose.yml --env-file .env

# Cargar variables del .env.dev para usarlas en targets (ej: db-connect)
ifneq (,$(wildcard .env.dev))
  include .env.dev
  export
endif

DB_CONTAINER = $(COMPOSE_PROJECT_NAME)-db

# =============================================================================
# Ayuda
# =============================================================================

.PHONY: help
help:
	@echo ""
	@echo "Uso: make <comando>"
	@echo ""
	@echo "  Dev"
	@echo "    up            Levantar DB + backend (dev)"
	@echo "    up-build      Levantar reconstruyendo la imagen del backend"
	@echo "    down          Bajar contenedores dev"
	@echo "    down-v        Bajar contenedores dev y eliminar volúmenes"
	@echo "    restart       Reiniciar solo el backend"
	@echo "    logs          Ver logs del backend en tiempo real"
	@echo "    logs-all      Ver logs de todos los servicios"
	@echo "    logs-db       Ver logs de la base de datos"
	@echo "    ps            Ver estado de los contenedores dev"
	@echo "    ps-a          Ver estado incluyendo contenedores detenidos"
	@echo "    shell         Abrir shell dentro del contenedor del backend"
	@echo ""
	@echo "  Base de datos"
	@echo "    db-connect    Abrir psql dentro del contenedor de la DB"
	@echo "    db-logs       Ver logs de la DB en tiempo real"
	@echo "    snapshot      Guardar snapshot de la DB dev"
	@echo "    restore       Restaurar snapshot de la DB dev"
	@echo "    snapshots     Listar snapshots guardados"
	@echo ""
	@echo "  Calidad"
	@echo "    validate      Correr compile + Checkstyle + PMD + tests (Docker)"
	@echo "    validate-fast Correr compile + Checkstyle + PMD sin tests (Docker)"
	@echo "    test          Correr solo los tests"
	@echo "    clean         Eliminar directorio target/"
	@echo ""
	@echo "  Entorno"
	@echo "    reset         Resetear entorno dev desde cero (rebuild incluido)"
	@echo "    reset-db      Resetear solo la DB dev"
	@echo "    reset-fast    Resetear entorno dev sin rebuild de imagen"
	@echo ""
	@echo "  Staging"
	@echo "    staging-up    Levantar entorno staging"
	@echo "    staging-up-build  Levantar staging reconstruyendo la imagen"
	@echo "    staging-down  Bajar entorno staging"
	@echo "    staging-logs  Ver logs del backend staging en tiempo real"
	@echo ""

# =============================================================================
# Dev
# =============================================================================

.PHONY: up
up:
	$(COMPOSE_DEV) up -d

.PHONY: up-build
up-build:
	$(COMPOSE_DEV) up -d --build

.PHONY: down
down:
	$(COMPOSE_DEV) down

.PHONY: down-v
down-v:
	$(COMPOSE_DEV) down -v

.PHONY: restart
restart:
	$(COMPOSE_DEV) restart backend

.PHONY: logs
logs:
	$(COMPOSE_DEV) logs -f backend

.PHONY: logs-all
logs-all:
	$(COMPOSE_DEV) logs -f

.PHONY: logs-db
logs-db:
	$(COMPOSE_DEV) logs -f postgres-db

.PHONY: ps
ps:
	$(COMPOSE_DEV) ps

.PHONY: ps-a
ps-a:
	$(COMPOSE_DEV) ps -a

.PHONY: shell
shell:
	$(COMPOSE_DEV) exec backend sh

# =============================================================================
# Base de datos
# =============================================================================

.PHONY: db-connect
db-connect:
	docker exec -it -e PGPASSWORD=$(POSTGRES_PASSWORD) $(DB_CONTAINER) \
		psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: db-logs
db-logs:
	$(COMPOSE_DEV) logs -f postgres-db

.PHONY: snapshot
snapshot:
	bash scripts/db-snapshot.sh save

.PHONY: restore
restore:
	bash scripts/db-snapshot.sh restore

.PHONY: snapshots
snapshots:
	bash scripts/db-snapshot.sh list

# =============================================================================
# Calidad
# =============================================================================

.PHONY: validate
validate:
	bash scripts/validate-local.sh --java docker

.PHONY: validate-fast
validate-fast:
	bash scripts/validate-local.sh --java docker --no-tests

.PHONY: test
test:
	bash scripts/validate-local.sh --java docker --only tests

.PHONY: clean
clean:
	rm -rf target/

# =============================================================================
# Entorno
# =============================================================================

.PHONY: reset
reset:
	bash scripts/reset-dev.sh

.PHONY: reset-db
reset-db:
	bash scripts/reset-dev.sh --only-db

.PHONY: reset-fast
reset-fast:
	bash scripts/reset-dev.sh --no-build

# =============================================================================
# Staging
# =============================================================================

.PHONY: staging-up
staging-up:
	$(COMPOSE_STAGING) up -d

.PHONY: staging-up-build
staging-up-build:
	$(COMPOSE_STAGING) up -d --build

.PHONY: staging-down
staging-down:
	$(COMPOSE_STAGING) down

.PHONY: staging-logs
staging-logs:
	$(COMPOSE_STAGING) logs -f backend
