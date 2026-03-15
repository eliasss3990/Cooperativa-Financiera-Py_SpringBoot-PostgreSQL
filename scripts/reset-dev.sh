#!/usr/bin/env bash
# =============================================================================
# reset-dev.sh — Reseteo completo del entorno de desarrollo
# =============================================================================
#
# QUÉ HACE:
#   Baja los contenedores dev, elimina todos los volúmenes (incluyendo la base
#   de datos), reconstruye la imagen del backend desde cero y vuelve a levantar
#   todo. Flyway corre automáticamente al iniciar y aplica todas las migraciones
#   sobre la DB vacía.
#
# CUÁNDO USARLO:
#   - La DB quedó en estado inconsistente (Flyway no puede aplicar migraciones)
#   - Cambiaste el schema y querés empezar con datos limpios
#   - El backend no levanta y sospechás que es un problema de estado acumulado
#   - Alguien cambió el pom.xml o el Dockerfile y tu imagen está desactualizada
#   - Querés un entorno 100% fresco como si fuera la primera vez que lo levantás
#
# CUÁNDO NO USARLO:
#   - Si tenés datos de prueba valiosos en la DB — hacé un snapshot antes
#     con: bash scripts/db-snapshot.sh save
#   - Si solo cambiaste código Java — basta con reiniciar el backend solo:
#     docker compose -f docker-compose.dev.yml restart backend
#
# USO:
#   bash scripts/reset-dev.sh              # reset completo (recomendado)
#   bash scripts/reset-dev.sh --no-build   # no reconstruye la imagen (más rápido)
#   bash scripts/reset-dev.sh --only-db    # solo resetea la DB, no toca la imagen
#
# IDEMPOTENTE: sí. Podés correrlo N veces seguidas y el resultado es el mismo.
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

BUILD=true
ONLY_DB=false

for arg in "$@"; do
  case $arg in
    --no-build) BUILD=false ;;
    --only-db)  ONLY_DB=true; BUILD=false ;;
    --help|-h)
      sed -n '/^# QUÉ HACE/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      error "Flag desconocido: '$arg'. Usá --help para ver las opciones."
      ;;
  esac
done

step "Verificaciones"

if ! command -v docker &>/dev/null; then
  error "Docker no está instalado. Instalalo desde https://docs.docker.com/get-docker/"
fi

if ! docker info &>/dev/null; then
  error "Docker está instalado pero no está corriendo. Iniciá Docker Desktop o el servicio."
fi

if [ ! -f "docker-compose.dev.yml" ]; then
  error "No se encontró docker-compose.dev.yml en: $PROJECT_ROOT"
fi

if [ ! -f ".env.dev" ]; then
  warn ".env.dev no encontrado."
  if [ -f ".env.dev.example" ]; then
    cp .env.dev.example .env.dev
    success ".env.dev creado desde .env.dev.example."
    warn "Revisá las credenciales en .env.dev antes de continuar."
    echo ""
    read -rp "Presioná Enter para continuar una vez que revisaste el archivo..."
  else
    error ".env.dev.example tampoco existe. No se puede continuar."
  fi
fi

set -a; source .env.dev; set +a

COMPOSE_CMD=(docker compose -f docker-compose.dev.yml --env-file .env.dev)
APP_PORT="${APP_PORT:-8801}"
APP_DEBUG_PORT="${APP_DEBUG_PORT:-5005}"

BACKEND_STOPPED_BY_US=false
cleanup_on_exit() {
  if $BACKEND_STOPPED_BY_US; then
    echo ""
    warn "Script interrumpido. Volviendo a levantar el backend..."
    "${COMPOSE_CMD[@]}" start backend 2>/dev/null || true
  fi
}
trap cleanup_on_exit EXIT INT TERM

success "Docker corriendo"
info "Proyecto : ${COMPOSE_PROJECT_NAME:-coop-dev}"
info "Puerto   : $APP_PORT"
info "DB       : ${POSTGRES_DB:-coop-db-dev}"

echo ""
if $ONLY_DB; then
  warn "Esto va a ELIMINAR todos los datos de la base de datos dev."
  warn "El backend va a reiniciarse para que Flyway reconstruya el schema."
else
  warn "Esto va a ELIMINAR todos los contenedores y volúmenes del entorno dev."
  warn "Todos los datos de la DB se van a perder."
fi
echo ""
read -rp "¿Continuar? (s/N): " CONFIRM
[[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }

step "Ejecutando limpieza"

if $ONLY_DB; then
  if [ -n "$("${COMPOSE_CMD[@]}" ps -q backend 2>/dev/null)" ]; then
    info "Bajando backend para liberar conexiones a la DB..."
    "${COMPOSE_CMD[@]}" stop backend 2>/dev/null || true
    BACKEND_STOPPED_BY_US=true
  fi

  DB_CONTAINER=$("${COMPOSE_CMD[@]}" ps -q postgres-db)
  info "Cerrando conexiones y recreando base de datos..."
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$POSTGRES_DB' AND pid <> pg_backend_pid();" > /dev/null 2>&1 || true
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\";" > /dev/null
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\";" > /dev/null

  success "Base de datos reseteada a estado de fábrica"
else
  info "Bajando todos los contenedores y eliminando volúmenes..."
  "${COMPOSE_CMD[@]}" down -v --remove-orphans 2>/dev/null || true
  success "Contenedores y volúmenes eliminados"
fi

if $BUILD; then
  step "Reconstruyendo imagen del backend"
  info "Esto puede tardar unos minutos (compilación Maven incluida)..."
  "${COMPOSE_CMD[@]}" build --no-cache backend
  success "Imagen reconstruida"
fi

step "Levantando entorno"

if $ONLY_DB; then
  info "Levantando backend (Flyway va a reconstruir el schema)..."
  "${COMPOSE_CMD[@]}" start backend
  BACKEND_STOPPED_BY_US=false
else
  info "Levantando DB y backend..."
  "${COMPOSE_CMD[@]}" up -d
fi

step "Esperando que los servicios estén listos"

if ! $ONLY_DB; then
  info "Esperando DB (Docker Healthcheck)..."
  RETRIES=30
  until [ "$("${COMPOSE_CMD[@]}" ps -q postgres-db | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]; do
    RETRIES=$((RETRIES - 1))
    [ $RETRIES -le 0 ] && error "La DB no levantó a tiempo. Revisá los logs:\n  docker compose -f docker-compose.dev.yml logs postgres-db"
    printf "."
    sleep 2
  done
  echo ""
  success "DB lista"
fi

info "Esperando backend (Docker Healthcheck)..."
RETRIES=40
until [ "$("${COMPOSE_CMD[@]}" ps -q backend | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]; do
  RETRIES=$((RETRIES - 1))
  if [ $RETRIES -le 0 ]; then
    echo ""
    error "El backend no levantó correctamente. Revisá los logs:\n  docker compose -f docker-compose.dev.yml logs --tail=50 backend"
  fi
  printf "."
  sleep 3
done
echo ""
success "Backend listo"

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║       Entorno dev reseteado correctamente        ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  App:    ${CYAN}http://localhost:${APP_PORT}${NC}"
echo -e "  Health: ${CYAN}http://localhost:${APP_PORT}/actuator/health${NC}"
echo -e "  Debug:  ${CYAN}localhost:${APP_DEBUG_PORT}${NC}  (conectá el IDE acá)"
echo ""
echo -e "  Ver logs en tiempo real:"
echo -e "  ${CYAN}docker compose -f docker-compose.dev.yml logs -f backend${NC}"

BACKEND_STOPPED_BY_US=false
