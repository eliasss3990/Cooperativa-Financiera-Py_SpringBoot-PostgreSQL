#!/usr/bin/env bash
# =============================================================================
# git-sync.sh — Sincronización inteligente del repositorio
# =============================================================================
#
# QUÉ HACE:
#   Automatiza la rutina diaria de actualizar tu repositorio local de Git.
#   Hace fetch, limpia referencias obsoletas (prune) y hace pull usando rebase
#   y autostash (para no perder tus cambios no commiteados y mantener el
#   historial limpio).
#
# CUÁNDO USARLO:
#   - Al arrancar tu día de trabajo para bajarte lo último.
#   - Antes de crear una rama nueva (asegurate de estar en develop/main).
#   - Cuando sabes que un compañero pusheó cambios y los necesitas.
#
# USO:
#   bash scripts/git-sync.sh           # Actualiza la rama actual de forma segura
#   bash scripts/git-sync.sh --clean   # Actualiza y limpia ramas locales obsoletas
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

CLEAN_BRANCHES=false

for arg in "$@"; do
  case $arg in
    --clean) CLEAN_BRANCHES=true ;;
    --help|-h)
      sed -n '/^# QUÉ HACE/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      error "Flag desconocido: '$arg'. Usá --help para ver las opciones."
      ;;
  esac
done

step "Verificaciones de Git"

if ! command -v git &>/dev/null; then
  error "Git no está instalado o no está en el PATH."
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  error "Este directorio no es un repositorio Git."
fi

CURRENT_BRANCH=$(git branch --show-current)
if [ -z "$CURRENT_BRANCH" ]; then
  error "No estás en ninguna rama (Detached HEAD). Hacé checkout a una rama primero."
fi

info "Rama actual: ${BOLD}$CURRENT_BRANCH${NC}"

step "Sincronizando con el servidor"

info "Descargando novedades del servidor (fetch + prune)..."
git fetch --all --prune --quiet
success "Fetch completado."

UPSTREAM=$(git rev-parse --abbrev-ref @{upstream} 2>/dev/null || true)

if [ -z "$UPSTREAM" ]; then
  warn "La rama '$CURRENT_BRANCH' no tiene un tracking remoto configurado."
  warn "No se puede hacer pull. Solo se actualizó el caché local (fetch)."
else
  info "Actualizando rama desde ${BOLD}$UPSTREAM${NC}..."

  # Usamos rebase y autostash para mantener el historial lineal sin perder cambios locales
  if git pull --rebase --autostash; then
    success "Repositorio actualizado correctamente."
  else
    echo ""
    warn "Hubo conflictos al intentar aplicar los cambios (Rebase falló)."
    info "Abortando el proceso automático para proteger tu código..."
    git rebase --abort >/dev/null 2>&1 || true
    echo ""
    error "Resolvé los conflictos manualmente ejecutando:\n  ${CYAN}git pull --rebase${NC}"
  fi
fi

if $CLEAN_BRANCHES; then
  step "Limpieza de ramas locales"

  # Busca ramas locales cuyo remote tracking branch diga "[gone]"
  # (significa que en GitHub/GitLab ya la borraron)
  GONE_BRANCHES=$(git branch -vv | grep ': gone]' | awk '{print $1}' || true)

  if [ -z "$GONE_BRANCHES" ]; then
    info "Tu repositorio local está limpio. No hay ramas obsoletas."
  else
    echo -e "${BOLD}Las siguientes ramas ya no existen en el servidor:${NC}"
    echo -e "${DIM}$GONE_BRANCHES${NC}"
    echo ""
    read -rp "¿Querés eliminarlas de tu PC local? (s/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[sS]$ ]]; then
      for b in $GONE_BRANCHES; do
        git branch -D "$b" >/dev/null
        success "Rama eliminada: $b"
      done
    else
      info "Limpieza omitida."
    fi
  fi
fi

echo ""
echo -e "${GREEN}${BOLD}¡Todo listo!${NC}"
