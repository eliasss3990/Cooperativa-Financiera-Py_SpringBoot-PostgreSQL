.DEFAULT_GOAL := help

COMPOSE_DEV     = docker compose -f docker-compose.dev.yml --env-file .env.dev
COMPOSE_STAGING = docker compose -f docker-compose.yml --env-file .env

# Cargar variables del .env.dev para usarlas en los targets que lo necesiten
ifneq (,$(wildcard .env.dev))
  include .env.dev
  export
endif

# =============================================================================
# Ayuda Autodocumentada
# =============================================================================

.PHONY: help
help: ## Muestra este menú de ayuda
	@echo ""
	@echo "Uso: make \033[36m<comando>\033[0m"
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-30s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
	@echo ""

##@ Desarrollo (Local)

.PHONY: dev-start-all
dev-start-all: ## Levanta la base de datos y el backend en segundo plano
	$(COMPOSE_DEV) up -d

.PHONY: dev-start-with-rebuild
dev-start-with-rebuild: ## Reconstruye la imagen del backend y levanta todo
	$(COMPOSE_DEV) up -d --build

.PHONY: dev-stop-all
dev-stop-all: ## Detiene y apaga todos los contenedores de desarrollo
	$(COMPOSE_DEV) down

.PHONY: dev-stop-and-delete-volumes
dev-stop-and-delete-volumes: ## Detiene los contenedores y BORRA los datos de la base de datos (volúmenes)
	$(COMPOSE_DEV) down -v

.PHONY: dev-restart-backend
dev-restart-backend: ## Reinicia únicamente el contenedor del backend
	$(COMPOSE_DEV) restart backend

.PHONY: dev-show-logs-backend
dev-show-logs-backend: ## Muestra los logs del backend en tiempo real
	$(COMPOSE_DEV) logs -f backend

.PHONY: dev-show-logs-all
dev-show-logs-all: ## Muestra los logs de todos los servicios juntos en tiempo real
	$(COMPOSE_DEV) logs -f

.PHONY: dev-status-containers
dev-status-containers: ## Muestra qué contenedores están corriendo actualmente
	$(COMPOSE_DEV) ps

.PHONY: dev-open-backend-shell
dev-open-backend-shell: ## Abre una terminal (shell) dentro del contenedor del backend
	$(COMPOSE_DEV) exec backend sh

##@ Base de Datos (Vía Scripts)

.PHONY: db-open-psql-console
db-open-psql-console: ## Abre la consola interactiva de PostgreSQL dentro del contenedor
	$(COMPOSE_DEV) exec -e PGPASSWORD="$(POSTGRES_PASSWORD)" postgres-db \
		psql -U $(POSTGRES_USER) -d $(POSTGRES_DB)

.PHONY: db-show-logs
db-show-logs: ## Muestra los logs específicos de la base de datos
	$(COMPOSE_DEV) logs -f postgres-db

.PHONY: db-snapshot-save
db-snapshot-save: ## Guarda un snapshot de la DB dev (llama a db-snapshot.sh save)
	@bash scripts/db-snapshot.sh save

.PHONY: db-snapshot-restore
db-snapshot-restore: ## Restaura la DB desde un snapshot (llama a db-snapshot.sh restore)
	@bash scripts/db-snapshot.sh restore

.PHONY: db-snapshot-list
db-snapshot-list: ## Lista todos los snapshots guardados (llama a db-snapshot.sh list)
	@bash scripts/db-snapshot.sh list

.PHONY: db-snapshot-delete
db-snapshot-delete: ## Elimina snapshots guardados (llama a db-snapshot.sh delete)
	@bash scripts/db-snapshot.sh delete

##@ Calidad de Código (Maven)

.PHONY: qa-run-all-checks
qa-run-all-checks: ## Compila, pasa linters (Checkstyle, PMD) y ejecuta los tests
	$(COMPOSE_DEV) exec backend ./mvnw clean verify checkstyle:check pmd:check

.PHONY: qa-run-linters-only
qa-run-linters-only: ## Compila y pasa linters sin ejecutar los tests
	$(COMPOSE_DEV) exec backend ./mvnw clean compile checkstyle:check pmd:check -DskipTests

.PHONY: qa-run-tests-only
qa-run-tests-only: ## Ejecuta únicamente los tests unitarios
	$(COMPOSE_DEV) exec backend ./mvnw test

.PHONY: qa-clean-build-folder
qa-clean-build-folder: ## Elimina la carpeta target/ generada por Maven
	$(COMPOSE_DEV) exec backend ./mvnw clean

##@ Limpieza y Reseteo (Vía Scripts)

.PHONY: env-reset-full
env-reset-full: ## Borra todo, reconstruye imágenes y levanta el entorno desde cero
	@bash scripts/reset-dev.sh

.PHONY: env-reset-database-only
env-reset-database-only: ## Borra la DB, la inicializa limpia y reinicia el backend
	@bash scripts/reset-dev.sh --only-db

.PHONY: env-reset-skip-rebuild
env-reset-skip-rebuild: ## Resetea el entorno limpio pero sin reconstruir la imagen del backend
	@bash scripts/reset-dev.sh --no-build

##@ Entorno de Pruebas (Staging)

.PHONY: staging-start
staging-start: ## Levanta el entorno de staging
	$(COMPOSE_STAGING) up -d

.PHONY: staging-start-with-rebuild
staging-start-with-rebuild: ## Reconstruye la imagen y levanta el entorno de staging
	$(COMPOSE_STAGING) up -d --build

.PHONY: staging-stop
staging-stop: ## Apaga el entorno de staging
	$(COMPOSE_STAGING) down

.PHONY: staging-show-logs-backend
staging-show-logs-backend: ## Muestra los logs del backend de staging en tiempo real
	$(COMPOSE_STAGING) logs -f backend
