#!/usr/bin/env bash
# =============================================================================
# validate-local.sh — Validación local completa antes de hacer push
# =============================================================================
#
# QUÉ HACE:
#   Corre exactamente los mismos checks que el pipeline de GitHub Actions,
#   en el mismo orden. Si algo falla acá, va a fallar en el CI también.
#   Muestra un resumen final con el resultado de cada paso.
#
#   Pasos (igual que el CI):
#     1. compile      — Compila el proyecto (mvn compile)
#     2. checkstyle   — Verifica convenciones de estilo
#     3. pmd          — Detecta bugs potenciales y malas prácticas
#     4. tests        — Ejecuta todos los tests (necesita DB corriendo)
#
#   Nota: si compile falla, los pasos siguientes no se ejecutan — no tiene
#   sentido correr Checkstyle o PMD sobre código que ni compila.
#
# MODOS DE JAVA:
#   El script ofrece tres modos para garantizar que usás JDK 17 (igual que CI).
#   Al correrlo sin flags te pregunta cuál querés usar.
#
#   --java local
#     Usa el Java que tenés instalado en el sistema.
#     PRO:     El más rápido. Sin overhead ni instalaciones extra.
#     CONTRA:  Si tu Java no es 17, los resultados pueden diferir del CI.
#     CUÁNDO:  Sabés que tenés JDK 17 instalado y querés la ejecución más rápida.
#
#   --java sdkman
#     Usa SDKMAN para activar JDK 17. Si SDKMAN no está instalado, el script
#     lo instala automáticamente. Si JDK 17 no está en SDKMAN, lo descarga.
#     PRO:     Garantiza JDK 17 sin tocar la instalación global del sistema.
#              Una vez instalado, es tan rápido como el modo local.
#     CONTRA:  La primera vez tarda por la descarga de SDKMAN y/o JDK 17.
#     CUÁNDO:  Trabajás con múltiples proyectos Java con distintas versiones.
#
#   --java docker
#     Corre el build dentro de un contenedor maven:3.9-eclipse-temurin-17,
#     la misma imagen base que usa el Dockerfile del proyecto.
#     PRO:     Garantía total de entorno idéntico al CI. No requiere Java ni
#              Maven instalados en el sistema.
#     CONTRA:  Más lento — Docker tiene overhead de arranque. El cache de Maven
#              se monta en ~/.m2 para no redescargar dependencias cada vez.
#     CUÁNDO:  Primera vez que alguien clona el repo, o en entornos donde no
#              querés instalar nada fuera de Docker.
#
# USO:
#   bash scripts/validate-local.sh                           # pregunta el modo Java
#   bash scripts/validate-local.sh --java local              # usa Java del sistema
#   bash scripts/validate-local.sh --java sdkman             # usa SDKMAN (JDK 17)
#   bash scripts/validate-local.sh --java docker             # usa Docker
#   bash scripts/validate-local.sh --java docker --no-cache  # Docker sin cache ~/.m2
#   bash scripts/validate-local.sh --no-tests                # sin tests (más rápido)
#   bash scripts/validate-local.sh --only checkstyle         # solo un paso
#   bash scripts/validate-local.sh --only pmd
#   bash scripts/validate-local.sh --only tests
#
# CACHÉ DE MAVEN (solo aplica a modo docker):
#   Por defecto se monta ~/.m2 como volumen para reutilizar dependencias entre
#   ejecuciones. Si el cache está corrupto o desactualizado y el build falla con
#   errores raros (ClassNotFoundException, checksum mismatch, etc.), usá
#   --no-cache para ignorarlo completamente y descargar todo desde cero.
#
# REQUISITOS:
#   - Para tests: la DB dev debe estar corriendo (el script ofrece levantarla)
#
# IDEMPOTENTE: sí. No modifica ningún archivo fuera de target/ y ~/.m2/
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

RUN_TESTS=true
ONLY_STEP=""
JAVA_MODE=""
NO_CACHE=false

i=1
while [ $i -le $# ]; do
  arg="${!i}"
  case "$arg" in
    --no-tests)  RUN_TESTS=false ;;
    --no-cache)  NO_CACHE=true ;;
    --java)
      i=$((i + 1))
      if [ $i -gt $# ]; then
        error "--java requiere un valor: local, sdkman o docker."
      fi
      JAVA_MODE="${!i}"
      ;;
    --only)
      i=$((i + 1))
      if [ $i -gt $# ]; then
        error "--only requiere un valor: compile, checkstyle, pmd o tests."
      fi
      ONLY_STEP="${!i}"
      case "$ONLY_STEP" in
        compile|checkstyle|pmd|tests) ;;
        *) error "Valor inválido para --only: '$ONLY_STEP'. Usá: compile, checkstyle, pmd o tests." ;;
      esac
      ;;
    --help|-h)
      sed -n '/^# QUÉ HACE/,/^# ===/p' "$0" | grep -v "^# ===" | sed 's/^# //' | sed 's/^#//'
      exit 0
      ;;
    *)
      error "Flag desconocido: '$arg'. Usá --help para ver las opciones."
      ;;
  esac
  i=$((i + 1))
done

if [ ! -f "pom.xml" ]; then
  error "No se encontró pom.xml en: $PROJECT_ROOT\n  Asegurate de correr el script desde la raíz del proyecto."
fi

if ! $RUN_TESTS && [ "$ONLY_STEP" = "tests" ]; then
  error "--no-tests y --only tests son contradictorios."
fi

pick_java_mode() {
  echo ""
  echo -e "${BOLD}¿Cómo querés correr el build?${NC}"
  echo ""
  printf "  ${CYAN}1)${NC} local   — Java instalado en el sistema\n"
  printf "         ${DIM}PRO: más rápido.  CON: no garantiza JDK 17.${NC}\n"
  echo ""
  printf "  ${CYAN}2)${NC} sdkman  — JDK 17 via SDKMAN (se instala si no está)\n"
  printf "         ${DIM}PRO: garantiza JDK 17, no toca el Java del sistema.${NC}\n"
  printf "         ${DIM}CON: primera vez descarga SDKMAN y/o JDK 17 (~200MB).${NC}\n"
  echo ""
  printf "  ${CYAN}3)${NC} docker  — Contenedor maven:3.9-eclipse-temurin-17\n"
  printf "         ${DIM}PRO: entorno idéntico al CI, sin instalar Java/Maven.${NC}\n"
  printf "         ${DIM}CON: más lento por overhead de Docker.${NC}\n"
  echo ""
  read -rp "Elegí una opción (1/2/3): " choice
  case "$choice" in
    1) JAVA_MODE="local" ;;
    2) JAVA_MODE="sdkman" ;;
    3) JAVA_MODE="docker" ;;
    *) error "Opción inválida. Ingresá 1, 2 o 3." ;;
  esac
}

[ -z "$JAVA_MODE" ] && pick_java_mode

USE_DOCKER=false
MVN=""

fix_target_permissions() {
  if [ -d "target" ] && find target/ -maxdepth 3 -user root 2>/dev/null | grep -q .; then
    error "target/ contiene archivos creados por Docker como root.\n  Eliminá el directorio y volvé a correr el script:\n  sudo rm -rf target/"
  fi
}

setup_local() {
  fix_target_permissions
  if ! command -v java &>/dev/null; then
    error "Java no encontrado en el sistema.\n  Instalá JDK 17 o usá --java sdkman o --java docker."
  fi

  local java_version
  java_version=$(java -version 2>&1 | head -1 | grep -oP '(?<=version ")\d+' || echo "?")
  if [ "$java_version" != "17" ] && [ "$java_version" != "?" ]; then
    warn "Tu Java es versión $java_version, el CI usa JDK 17."
    warn "Los resultados pueden diferir. Considerá usar --java sdkman o --java docker."
    echo ""
    read -rp "¿Continuar igual con Java $java_version? (s/N): " CONTINUE_ANYWAY
    [[ "$CONTINUE_ANYWAY" =~ ^[sS]$ ]] || { info "Cancelado. Usá --java sdkman para garantizar JDK 17."; exit 0; }
  fi

  if [ -f "./mvnw" ]; then
    MVN="./mvnw"
  elif command -v mvn &>/dev/null; then
    MVN="mvn"
  else
    error "Maven no encontrado.\n  Instalá Maven, usá el wrapper (mvnw), o usá --java docker."
  fi
}

setup_sdkman() {
  fix_target_permissions
  local sdkman_dir="${SDKMAN_DIR:-$HOME/.sdkman}"

  if [ ! -f "$sdkman_dir/bin/sdkman-init.sh" ]; then
    step "Instalando SDKMAN"
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
      error "SDKMAN requiere curl o wget para instalarse."
    fi
    warn "Primera vez: instalando SDKMAN (~30s)..."
    if command -v curl &>/dev/null; then
      curl -s "https://get.sdkman.io" | bash
    else
      wget -qO- "https://get.sdkman.io" | bash
    fi
    success "SDKMAN instalado"
  fi

  export SDKMAN_DIR="$sdkman_dir"
  # shellcheck disable=SC1091
  source "$sdkman_dir/bin/sdkman-init.sh"

  local installed_17
  installed_17=$(sdk list java 2>/dev/null \
    | grep -E "17\.[0-9]+\.[0-9]+-tem" \
    | grep -E "installed|current" \
    | awk '{print $NF}' \
    | head -1 || true)

  if [ -z "$installed_17" ]; then
    step "Instalando JDK 17 (Temurin) via SDKMAN"
    warn "Primera vez: descargando JDK 17 (~200MB)..."
    sdk install java 17.0.13-tem
    installed_17="17.0.13-tem"
  fi

  sdk use java "$installed_17" > /dev/null 2>&1
  success "JDK activo: $installed_17"

  if [ -f "./mvnw" ]; then
    MVN="./mvnw"
  elif command -v mvn &>/dev/null; then
    MVN="mvn"
  else
    info "Maven no encontrado. Instalando via SDKMAN..."
    sdk install maven 2>/dev/null || true
    MVN="mvn"
  fi
}

setup_docker() {
  if ! command -v docker &>/dev/null; then
    error "Docker no está instalado. Instalalo desde https://docs.docker.com/get-docker/"
  fi
  if ! docker info &>/dev/null; then
    error "Docker está instalado pero no está corriendo. Iniciá Docker Desktop o el servicio."
  fi
  USE_DOCKER=true

  if $NO_CACHE; then
    warn "Modo --no-cache: Maven va a descargar todas las dependencias desde cero."
  fi
}

case "$JAVA_MODE" in
  local)  setup_local ;;
  sdkman) setup_sdkman ;;
  docker) setup_docker ;;
  *)
    error "Modo inválido: '$JAVA_MODE'.\n  Valores válidos: local, sdkman, docker."
    ;;
esac

if $NO_CACHE && ! $USE_DOCKER; then
  warn "--no-cache solo aplica al modo docker. Se ignora con --java $JAVA_MODE."
fi

declare -A RESULTS
declare -a STEPS_ORDER
COMPILE_FAILED=false

run_step() {
  local name="$1"
  local label="$2"
  shift 2
  local cmd=("$@")

  STEPS_ORDER+=("$name")

  # --only: saltar pasos no pedidos explícitamente
  if [ -n "$ONLY_STEP" ] && [ "$ONLY_STEP" != "$name" ]; then
    RESULTS[$name]="skip"
    return
  fi

  # Si compile falló no tiene sentido correr los pasos siguientes
  if $COMPILE_FAILED && [ "$name" != "compile" ]; then
    RESULTS[$name]="blocked"
    return
  fi

  step "$label"
  local start
  start=$(date +%s)

  if "${cmd[@]}" 2>&1; then
    local elapsed=$(( $(date +%s) - start ))
    RESULTS[$name]="ok:${elapsed}s"
    success "$label completado en ${elapsed}s"
  else
    local elapsed=$(( $(date +%s) - start ))
    RESULTS[$name]="fail:${elapsed}s"
    echo -e "${RED}[ERROR]${NC} $label falló"
    if [ "$name" = "compile" ]; then
      COMPILE_FAILED=true
      warn "Compilación fallida — se omiten los pasos siguientes."
    fi
  fi
}

check_db_for_tests() {
  if [ ! -f ".env.dev" ]; then
    warn ".env.dev no encontrado — los tests pueden fallar si la DB no está configurada."
    return
  fi

  set -a; source .env.dev; set +a

  local db_container="${COMPOSE_PROJECT_NAME:-coop-financiera-dev}-db"

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${db_container}$"; then
    echo ""
    warn "La DB dev no está corriendo. Los tests van a fallar sin ella."
    echo ""
    read -rp "¿Levantar la DB ahora? (s/N): " START_DB
    if [[ "$START_DB" =~ ^[sS]$ ]]; then
      docker compose -f docker-compose.dev.yml --env-file .env.dev up -d postgres-db
      info "Esperando que la DB esté lista..."
      local retries=20
      until docker exec "$db_container" pg_isready -U "${POSTGRES_USER:-dev-user}" &>/dev/null; do
        retries=$((retries - 1))
        [ $retries -le 0 ] && error "La DB no levantó a tiempo."
        printf "."
        sleep 2
      done
      echo ""
      success "DB lista"
    else
      warn "Continuando sin DB — los tests van a fallar."
    fi
  else
    success "DB dev corriendo"
  fi
}

load_test_env() {
  if [ -f ".env.dev" ]; then
    set -a; source .env.dev; set +a
    export SPRING_DATASOURCE_URL="jdbc:postgresql://localhost:${POSTGRES_PORT:-5433}/${POSTGRES_DB:-coop-db-dev}"
    export SPRING_DATASOURCE_USERNAME="${POSTGRES_USER:-dev-user}"
    export SPRING_DATASOURCE_PASSWORD="${POSTGRES_PASSWORD:-dev-password}"
    export SPRING_PROFILES_ACTIVE="test"
  fi
}

mvn_cmd() {
  if $USE_DOCKER; then
    # Directorio temporal para que el entrypoint de la imagen pueda escribir /root
    local tmp_home
    tmp_home=$(mktemp -d)

    local docker_args=(
      --rm
      # Correr como el usuario actual evita que Docker cree archivos como root en target/
      --user "$(id -u):$(id -g)"
      # El entrypoint de la imagen intenta escribir en /root — montamos un tmpdir para silenciar el warning
      -v "$tmp_home":/root
      -v "$PROJECT_ROOT":/workspace
      --network host
      -w /workspace
      -e SPRING_DATASOURCE_URL="${SPRING_DATASOURCE_URL:-}"
      -e SPRING_DATASOURCE_USERNAME="${SPRING_DATASOURCE_USERNAME:-}"
      -e SPRING_DATASOURCE_PASSWORD="${SPRING_DATASOURCE_PASSWORD:-}"
      -e SPRING_PROFILES_ACTIVE="${SPRING_PROFILES_ACTIVE:-test}"
    )
    local mvn_repo_flag=""
    if ! $NO_CACHE; then
      local m2_cache="$HOME/.m2"
      mkdir -p "$m2_cache"
      # Montar en /var/maven/.m2 (no /root/.m2) ya que el usuario no es root
      docker_args+=(-v "$m2_cache":/var/maven/.m2)
      mvn_repo_flag="-Dmaven.repo.local=/var/maven/.m2"
    fi
    local exit_code=0
    docker run "${docker_args[@]}" maven:3.9-eclipse-temurin-17-alpine mvn $mvn_repo_flag "$@" || exit_code=$?
    rm -rf "$tmp_home"
    return $exit_code
  else
    $MVN "$@"
  fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         Validación local — CI pre-check          ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

if $USE_DOCKER; then
  if $NO_CACHE; then
    info "Modo Java : docker (maven:3.9-eclipse-temurin-17) — sin caché"
  else
    info "Modo Java : docker (maven:3.9-eclipse-temurin-17) — con caché ~/.m2"
  fi
else
  info "Modo Java : $JAVA_MODE"
  info "Maven     : $($MVN --version 2>/dev/null | head -1 || echo 'no detectado')"
  info "Java      : $(java -version 2>&1 | head -1 || echo 'no detectado')"
fi

[ -n "$ONLY_STEP" ]  && info "Modo      : solo '$ONLY_STEP'"
! $RUN_TESTS && [ -z "$ONLY_STEP" ] && info "Modo      : sin tests"

if $RUN_TESTS && { [ -z "$ONLY_STEP" ] || [ "$ONLY_STEP" = "tests" ]; }; then
  step "Verificando DB para tests"
  check_db_for_tests
fi

load_test_env

run_step "compile"    "Compilación" mvn_cmd compile -B -q
run_step "checkstyle" "Checkstyle"  mvn_cmd checkstyle:check -B
run_step "pmd"        "PMD"         mvn_cmd pmd:check -B

if $RUN_TESTS; then
  run_step "tests" "Tests" mvn_cmd test -B -q
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    Resumen                       ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
echo ""

ALL_OK=true
for step_name in "${STEPS_ORDER[@]}"; do
  result="${RESULTS[$step_name]}"
  case "$result" in
    ok:*)
      elapsed="${result#ok:}"
      printf "  ${GREEN}✓${NC}  %-15s ${DIM}%s${NC}\n" "$step_name" "$elapsed"
      ;;
    fail:*)
      elapsed="${result#fail:}"
      printf "  ${RED}✗${NC}  %-15s ${DIM}%s${NC}\n" "$step_name" "$elapsed"
      ALL_OK=false
      ;;
    blocked)
      printf "  ${YELLOW}–${NC}  %-15s ${DIM}(no ejecutado — compile falló)${NC}\n" "$step_name"
      ALL_OK=false
      ;;
    skip)
      printf "  ${DIM}–  %-15s (omitido)${NC}\n" "$step_name"
      ;;
  esac
done

echo ""

if $ALL_OK; then
  echo -e "  ${GREEN}${BOLD}Todo pasa. Podés hacer push sin miedo.${NC}"
else
  echo -e "  ${RED}${BOLD}Hay errores. Corregílos antes de hacer push.${NC}"
  echo ""
  echo -e "  ${DIM}Tip: corré solo el paso que falla con --only <paso>${NC}"
  echo -e "  ${DIM}Ej:  bash scripts/validate-local.sh --only checkstyle${NC}"
  exit 1
fi

echo ""
