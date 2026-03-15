#!/usr/bin/env bash
# =============================================================================
# db-snapshot.sh — Snapshots de la base de datos dev
# =============================================================================
#
# QUÉ HACE:
#   Permite guardar y restaurar snapshots de la base de datos del entorno dev.
#   Los snapshots son archivos SQL completos guardados en snapshots/ con
#   timestamp. Son portables: podés pasarle el .sql a un compañero.
#
# CUÁNDO USARLO:
#   ANTES de:
#     - Probar una migración de Flyway destructiva (DROP COLUMN, ALTER TABLE)
#     - Hacer cambios de schema que sean difíciles de revertir
#     - Experimentar con datos que tardaste en cargar manualmente
#   DESPUÉS:
#     - Cargaste datos de prueba y querés poder volver a ese estado
#     - Querés compartir un estado de la DB con un compañero
#
# USO:
#   bash scripts/db-snapshot.sh save                       # snapshot con timestamp
#   bash scripts/db-snapshot.sh save "algun-nombre"        # con nombre descriptivo
#   bash scripts/db-snapshot.sh restore                    # elige de la lista
#   bash scripts/db-snapshot.sh restore nombre.sql         # restaura uno específico
#   bash scripts/db-snapshot.sh list                       # lista todos los snapshots
#   bash scripts/db-snapshot.sh delete                     # elimina snapshots viejos
#
# DÓNDE SE GUARDAN:
#   snapshots/ (en la raíz del proyecto, ignorado por git)
#
# IDEMPOTENTE: sí. Guardar siempre crea un archivo nuevo (nunca sobreescribe).
#   Restaurar siempre parte de la DB vacía antes de aplicar el dump.
#
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${BOLD}── $* ──────────────────────────────────────${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

SNAPSHOTS_DIR="$PROJECT_ROOT/snapshots"
COMPOSE_FILE="docker-compose.dev.yml"
ENV_FILE=".env.dev"

if ! command -v docker &>/dev/null; then
  error "Docker no está instalado. Instalalo desde https://docs.docker.com/get-docker/"
fi

if ! docker info &>/dev/null; then
  error "Docker está instalado pero no está corriendo. Iniciá Docker Desktop o el servicio."
fi

if [ ! -f "$COMPOSE_FILE" ]; then
  error "No se encontró $COMPOSE_FILE en: $PROJECT_ROOT"
fi

if [ ! -f "$ENV_FILE" ]; then
  error "$ENV_FILE no encontrado. Ejecutá primero: cp .env.dev.example .env.dev"
fi

set -a; source "$ENV_FILE"; set +a

COMPOSE_CMD=(docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE")
DB_CONTAINER=$("${COMPOSE_CMD[@]}" ps -q postgres-db 2>/dev/null || echo "")
POSTGRES_USER="${POSTGRES_USER:-dev-user}"
POSTGRES_DB="${POSTGRES_DB:-coop-db-dev}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-dev-password}"
APP_PORT="${APP_PORT:-8801}"

mkdir -p "$SNAPSHOTS_DIR"

is_db_running() {
  [ -n "$("${COMPOSE_CMD[@]}" ps -q postgres-db 2>/dev/null)" ]
}

is_backend_running() {
  [ -n "$("${COMPOSE_CMD[@]}" ps -q backend 2>/dev/null)" ]
}

require_db() {
  if ! is_db_running; then
    error "La DB no está corriendo.\n  Levantála con: docker compose -f $COMPOSE_FILE --env-file $ENV_FILE up -d postgres-db"
  fi
  DB_CONTAINER=$("${COMPOSE_CMD[@]}" ps -q postgres-db)
}

run_psql() {
  docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
    psql -U "$POSTGRES_USER" "$@"
}

get_snapshot_files() {
  local -n arr=$1
  arr=()
  for f in "$SNAPSHOTS_DIR"/*.sql; do
    [ -e "$f" ] && arr+=("$f")
  done
}

list_snapshots() {
  local -a files
  get_snapshot_files files

  if [ ${#files[@]} -eq 0 ]; then
    return 1
  fi

  local i=1
  for f in "${files[@]}"; do
    local name size fdate
    name=$(basename "$f")
    size=$(du -sh "$f" | cut -f1)
    fdate=$(stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1 || echo "—")
    printf "  ${CYAN}%2d)${NC} %-52s ${DIM}%s  %s${NC}\n" "$i" "$name" "$size" "$fdate"
    i=$((i + 1))
  done
  return 0
}

pick_snapshot() {
  local -a files
  get_snapshot_files files

  if [ ${#files[@]} -eq 0 ]; then
    error "No hay snapshots guardados. Creá uno con: bash scripts/db-snapshot.sh save"
  fi

  echo ""
  echo -e "${BOLD}Snapshots disponibles:${NC}"
  list_snapshots
  echo ""
  read -rp "Elegí un número: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#files[@]}" ]; then
    error "Opción inválida. Ingresá un número entre 1 y ${#files[@]}."
  fi
  PICKED="${files[$((choice - 1))]}"
}

cmd_save() {
  local label="${1:-}"
  local timestamp
  timestamp=$(date +"%Y-%m-%d_%H-%M-%S")

  local FILENAME
  if [ -n "$label" ]; then
    label=$(echo "$label" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_')
    FILENAME="${timestamp}_${label}.sql"
  else
    FILENAME="${timestamp}.sql"
  fi

  local filepath="$SNAPSHOTS_DIR/$FILENAME"
  local tmpfile="${filepath}.tmp"

  step "Guardando snapshot"
  require_db

  info "DB       : $POSTGRES_DB"
  info "Archivo  : snapshots/$FILENAME"
  echo ""

  if docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
      pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
      > "$tmpfile"; then
    mv "$tmpfile" "$filepath"
    local size
    size=$(du -sh "$filepath" | cut -f1)
    success "Snapshot guardado — $size"
    echo ""
    echo -e "  Para restaurarlo después:"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh restore $FILENAME${NC}"
  else
    rm -f "$tmpfile"
    error "pg_dump falló. El snapshot no fue guardado."
  fi
}

cmd_restore() {
  local target="${1:-}"
  local filepath

  if [ -n "$target" ]; then
    if [ -f "$target" ]; then
      filepath="$target"
    elif [ -f "$SNAPSHOTS_DIR/$target" ]; then
      filepath="$SNAPSHOTS_DIR/$target"
    else
      error "No se encontró el snapshot: $target\n  Archivos disponibles: bash scripts/db-snapshot.sh list"
    fi
  else
    pick_snapshot
    filepath="$PICKED"
  fi

  step "Restaurando snapshot"

  local filename size
  filename=$(basename "$filepath")
  size=$(du -sh "$filepath" | cut -f1)

  info "Snapshot   : $filename ($size)"
  info "DB destino : $POSTGRES_DB"
  echo ""
  warn "Esto va a REEMPLAZAR todos los datos actuales de la DB dev."
  read -rp "¿Continuar? (s/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }

  require_db

  local backend_was_running=false
  if is_backend_running; then
    backend_was_running=true
    info "Bajando backend para liberar conexiones..."
    "${COMPOSE_CMD[@]}" stop backend 2>/dev/null || true
    trap '"${COMPOSE_CMD[@]}" start backend 2>/dev/null || true' EXIT INT TERM
  fi

  info "Cerrando conexiones activas a la DB..."
  run_psql -d postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$POSTGRES_DB' AND pid <> pg_backend_pid();" \
    > /dev/null 2>&1 || true

  info "Limpiando DB..."
  run_psql -d postgres -c "DROP DATABASE IF EXISTS \"$POSTGRES_DB\";" > /dev/null
  run_psql -d postgres -c "CREATE DATABASE \"$POSTGRES_DB\";" > /dev/null

  info "Aplicando snapshot..."
  if docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$DB_CONTAINER" \
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 \
      < "$filepath" > /dev/null; then
    success "Snapshot restaurado"
  else
    echo ""
    error "La restauración falló. La DB puede estar en estado inconsistente.\n  Revisá el snapshot o hacé un reset completo con: bash scripts/reset-dev.sh"
  fi

  if $backend_was_running; then
    info "Volviendo a levantar el backend..."
    "${COMPOSE_CMD[@]}" start backend > /dev/null

    info "Esperando que el backend reporte estado 'healthy'..."
    local retries=40
    until [ "$("${COMPOSE_CMD[@]}" ps -q backend | xargs docker inspect -f '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]; do
      retries=$((retries - 1))
      if [ $retries -le 0 ]; then
        echo ""
        error "El backend no levantó correctamente. Revisá los logs:\n  docker compose -f $COMPOSE_FILE logs --tail=50 backend"
      fi
      printf "."
      sleep 3
    done
    echo ""
    success "Backend listo en http://localhost:${APP_PORT}"
  fi

  trap - EXIT INT TERM
  echo ""
  success "Restauración completada."
}

cmd_list() {
  step "Snapshots guardados"

  if ! list_snapshots; then
    warn "No hay snapshots todavía."
    echo ""
    echo -e "  Creá uno con: ${CYAN}bash scripts/db-snapshot.sh save${NC}"
  fi

  echo ""
  local total
  total=$(du -sh "$SNAPSHOTS_DIR" 2>/dev/null | cut -f1 || echo "0")
  echo -e "  Espacio total usado: ${DIM}$total${NC}"
}

cmd_delete() {
  step "Eliminar snapshots"

  local -a files
  get_snapshot_files files

  if [ ${#files[@]} -eq 0 ]; then
    info "No hay snapshots para eliminar."
    exit 0
  fi

  echo -e "${BOLD}Snapshots disponibles:${NC}"
  list_snapshots
  echo ""
  echo -e "  ${DIM}(escribí 'all' para eliminar todos)${NC}"
  read -rp "Elegí un número (o 'all'): " choice

  if [ "$choice" = "all" ]; then
    read -rp "¿Eliminar TODOS los snapshots? (s/N): " CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] || { info "Cancelado."; exit 0; }
    rm -f "$SNAPSHOTS_DIR"/*.sql
    success "Todos los snapshots eliminados."
  elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#files[@]}" ]; then
    local target="${files[$((choice - 1))]}"
    rm -f "$target"
    success "Eliminado: $(basename "$target")"
  else
    error "Opción inválida. Ingresá un número entre 1 y ${#files[@]}, o 'all'."
  fi
}

COMMAND="${1:-}"

case "$COMMAND" in
  save)    cmd_save "${2:-}" ;;
  restore) cmd_restore "${2:-}" ;;
  list)    cmd_list ;;
  delete)  cmd_delete ;;
  --help|-h)
    sed -n '/^# QUÉ HACE/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# //' | sed 's/^#//'
    ;;
  "")
    echo -e "${BOLD}db-snapshot.sh${NC} — Snapshots de la base de datos dev"
    echo ""
    echo "Uso:"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh save${NC}                       # snapshot con timestamp"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh save 'antes-migracion'${NC}     # con nombre descriptivo"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh restore${NC}                    # elegir de la lista"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh restore archivo.sql${NC}        # restaurar uno específico"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh list${NC}                       # ver todos los snapshots"
    echo -e "  ${CYAN}bash scripts/db-snapshot.sh delete${NC}                     # eliminar snapshots"
    echo ""
    ;;
  *)
    error "Comando desconocido: '$COMMAND'. Usá --help para ver las opciones."
    ;;
esac
