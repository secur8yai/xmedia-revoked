#!/usr/bin/env bash
# XMedia Installer — Single-command Docker installer for XMedia.
#
# Usage (root, Ubuntu x86_64):
#   curl -fsSL https://raw.githubusercontent.com/secur8yai/xmedia-revoked/main/install.sh | sudo bash
#
# XMedia is licensed commercial software. After install, set
# XMEDIA_LICENSE_KEY in /opt/xmedia/.env to a vendor-issued token; the
# container will refuse to start in XMEDIA_PROFILE=production without it.
#
# Options:
#   --version=vX.Y.Z      Pin a specific release tag (default: :latest)
#   --port=NNNN           Host port to expose the UI on (default: 8080)
#   --force               Remove any existing compose stack first (keeps volumes)
#   --purge               With --force: also remove the postgres_data volume
#   --upgrade             Pull the pinned image and recreate the stack
#   --uninstall           Stop and remove containers (keeps volumes)
#
set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================
DEFAULT_IMAGE_REPO="ghcr.io/secur8yai/xmedia"
POSTGRES_IMAGE="postgres:16.8-alpine"
INSTALL_DIR="/opt/xmedia"
LOCK_FILE="${INSTALL_DIR}/.install.lock"
LOG_FILE="/var/log/xmedia-install.log"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
ENV_FILE="${INSTALL_DIR}/.env"
MAIN_PORT=8080

# Resource detection results — populated by detect_host_resources() at
# runtime. Floor of 1 GB for OS reservation, floor of 1 GB for the container
# (so a 2 GB host still gets a viable container claim, not OOM bait).
HOST_RAM_GB=0
HOST_CPUS=0
TARGET_MEM_GB=0
GOMEM_GB=0

# =============================================================================
# Logging
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
: > "$LOG_FILE" 2>/dev/null || LOG_FILE=/tmp/xmedia-install.log
log_info()  { echo -e "${BLUE}[INFO]${NC}  $*"  | tee -a "$LOG_FILE"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }

# =============================================================================
# Usage
# =============================================================================
usage() {
  cat <<'USAGE'
XMedia Installer (Docker, Ubuntu x86_64)

Usage:
  install.sh [OPTIONS]

Options:
  --port=PORT           Host port for the UI (default: 8080)
  --version=TAG         Pin a release tag, e.g. v0.6.0 (default: :latest)
  --force               Remove existing stack and reinstall (preserves data volumes)
  --purge               With --force: also remove data volumes
  --upgrade             Pull the pinned image and recreate containers
  --uninstall           Stop the stack and remove containers (preserves volumes)
  -h, --help            Show this help
USAGE
}

# =============================================================================
# Argument parsing
# =============================================================================
PORT=""
XMEDIA_RELEASE_TAG=""
FORCE=false
PURGE=false
UPGRADE=false
UNINSTALL=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --port=*)     PORT="${1#*=}"; shift ;;
    --version=*)  XMEDIA_RELEASE_TAG="${1#*=}"; shift ;;
    --force)      FORCE=true; shift ;;
    --purge)      PURGE=true; shift ;;
    --upgrade)    UPGRADE=true; shift ;;
    --uninstall)  UNINSTALL=true; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# =============================================================================
# Pre-flight
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
  fi
  log_ok "Running as root"
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_warn "Cannot detect OS (no /etc/os-release); continuing"
    return
  fi
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" ]]; then
    log_warn "Untested OS (${ID:-unknown}). XMedia is verified on Ubuntu 22.04+ x86_64"
  fi
  local arch
  arch="$(uname -m)"
  if [[ "${arch}" != "x86_64" && "${arch}" != "amd64" ]]; then
    log_warn "Host arch is ${arch}; XMedia only publishes linux/amd64 (x86_64 — Intel or AMD CPUs)"
  fi
  log_ok "OS check passed (${ID:-unknown} ${arch})"
}

check_prereqs() {
  local missing=()
  for cmd in curl openssl; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    log_info "Installing prerequisites: ${missing[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
  fi
  log_ok "Prerequisites available"
}

check_lock() {
  mkdir -p "$INSTALL_DIR"
  if [[ -f "$LOCK_FILE" ]]; then
    local pid
    pid="$(cat "$LOCK_FILE" 2>/dev/null || echo)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      log_error "Another install is already running (pid=$pid)"
      exit 1
    fi
    log_warn "Removing stale lock file"
    rm -f "$LOCK_FILE"
  fi
  echo $$ > "$LOCK_FILE"
}

cleanup() { rm -f "$LOCK_FILE"; }
trap cleanup EXIT

# =============================================================================
# Docker
# =============================================================================
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    log_ok "Docker Engine + Compose v2 already installed"
    return
  fi
  log_info "Installing Docker Engine..."
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  log_ok "Docker installed"
}

# =============================================================================
# Operations that short-circuit main()
# =============================================================================
handle_uninstall() {
  if [[ "$UNINSTALL" != true ]]; then return; fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    ( cd "$INSTALL_DIR" && docker compose down --remove-orphans 2>/dev/null || true )
    log_ok "XMedia uninstalled. Data volumes preserved."
  else
    log_warn "No install found at $INSTALL_DIR"
  fi
  exit 0
}

handle_upgrade() {
  if [[ "$UPGRADE" != true ]]; then return; fi
  if [[ ! -f "$COMPOSE_FILE" ]]; then
    log_error "No install found at $INSTALL_DIR — run install.sh without --upgrade first"
    exit 1
  fi
  cd "$INSTALL_DIR"
  docker compose pull
  docker compose up -d --force-recreate
  log_ok "Upgrade complete"
  exit 0
}

handle_force() {
  if [[ "$FORCE" != true ]]; then return; fi
  if [[ -f "$COMPOSE_FILE" ]]; then
    cd "$INSTALL_DIR"
    if [[ "$PURGE" == true ]]; then
      docker compose down -v --remove-orphans 2>/dev/null || true
      log_warn "Purged containers and data volumes"
      rm -f "$COMPOSE_FILE" "$ENV_FILE"
    else
      docker compose down --remove-orphans 2>/dev/null || true
      log_ok "Stopped existing stack (volumes preserved)"
      rm -f "$COMPOSE_FILE"
      # Keep .env — it contains XMEDIA_VAULT_PASSPHRASE.
      # Deleting it while volumes survive would permanently lock the vault.
    fi
  fi
}

# =============================================================================
# Host resource detection (90% claim with 1 GB OS reservation)
# =============================================================================
# Detects total RAM + CPU count and computes:
#   TARGET_MEM_GB   — what the container claims (90% of host, OS-reserved)
#   GOMEM_GB        — Go heap soft cap (90% of TARGET_MEM_GB) so the GC
#                     keeps the heap inside the cgroup limit
# Writes results into the module-level variables defined at the top of
# this file. Safe to run on Linux x86_64 / arm64; falls back to 4 GB on
# unrecognised platforms so the install never zeroes out.
detect_host_resources() {
  local ram_kb=0
  local ram_bytes=0
  local target_bytes=0
  local reserved_bytes=$((1024 * 1024 * 1024))  # 1 GB always reserved for OS

  if [[ -r /proc/meminfo ]]; then
    ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  elif command -v sysctl >/dev/null 2>&1 && sysctl -n hw.memsize >/dev/null 2>&1; then
    ram_kb=$(( $(sysctl -n hw.memsize) / 1024 ))
  fi

  if [[ -z "$ram_kb" || "$ram_kb" -le 0 ]]; then
    log_warn "Could not detect host RAM; defaulting to 4 GB"
    ram_kb=$((4 * 1024 * 1024))
  fi

  ram_bytes=$((ram_kb * 1024))
  HOST_RAM_GB=$((ram_kb / 1024 / 1024))

  # 90% of host, but always reserve at least 1 GB for the OS.
  target_bytes=$((ram_bytes * 90 / 100))
  if [[ $((ram_bytes - target_bytes)) -lt $reserved_bytes ]]; then
    target_bytes=$((ram_bytes - reserved_bytes))
  fi
  # Floor the container at 1 GB so a 2 GB host still gets a viable claim.
  if [[ $target_bytes -lt $reserved_bytes ]]; then
    target_bytes=$reserved_bytes
  fi
  TARGET_MEM_GB=$((target_bytes / 1024 / 1024 / 1024))

  # Go heap = 90% of cgroup limit (leaves 10% for stack, mmap, runtime).
  GOMEM_GB=$((target_bytes * 90 / 100 / 1024 / 1024 / 1024))
  if [[ $GOMEM_GB -lt 1 ]]; then
    GOMEM_GB=1
  fi

  HOST_CPUS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

  log_ok "Detected ${HOST_RAM_GB} GB RAM / ${HOST_CPUS} CPUs"
  log_info "Container claim: ${TARGET_MEM_GB}g RAM (GOMEMLIMIT=${GOMEM_GB}g)"
}

# =============================================================================
# Config generation
# =============================================================================
generate_env() {
  if [[ -f "$ENV_FILE" && "$FORCE" != true ]]; then
    # Validate the existing .env — fix broken XMEDIA_IMAGE if needed
    if grep -q 'XMEDIA_IMAGE=.*[[:space:]]' "$ENV_FILE" 2>/dev/null; then
      local tag="${XMEDIA_RELEASE_TAG:-latest}"
      log_warn "Fixing broken XMEDIA_IMAGE in existing .env"
      sed -i "s|^XMEDIA_IMAGE=.*|XMEDIA_IMAGE=${DEFAULT_IMAGE_REPO}:${tag}|" "$ENV_FILE"
    fi
    # Backfill resource-claim variables for installs predating Phase 40.
    # Existing .env is preserved otherwise — vault passphrase must not change.
    if ! grep -q '^XMEDIA_MEMORY_LIMIT=' "$ENV_FILE" 2>/dev/null; then
      log_warn "Backfilling resource claim into existing .env (${TARGET_MEM_GB}g / GOMEMLIMIT=${GOMEM_GB}g)"
      cat >> "$ENV_FILE" <<EOF

# Added by install.sh Phase 40 on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# 90% of detected host RAM (${HOST_RAM_GB} GB) with 1 GB OS reservation.
XMEDIA_MEMORY_LIMIT=${TARGET_MEM_GB}g
XMEDIA_GOMEMLIMIT=${GOMEM_GB}g
XMEDIA_CPU_LIMIT=0
EOF
    fi
    log_ok "Preserving existing .env at $ENV_FILE"
    return
  fi

  local pg_pass vault_pass admin_pass tag
  pg_pass=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
  vault_pass=$(openssl rand -base64 48 | tr -d '/+=' | head -c 48)
  admin_pass=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
  tag="${XMEDIA_RELEASE_TAG:-latest}"

  cat > "$ENV_FILE" <<EOF
# Generated by install.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Host detected: ${HOST_RAM_GB} GB RAM, ${HOST_CPUS} CPUs.
# Keep this file private — it contains the vault passphrase.

XMEDIA_IMAGE=${DEFAULT_IMAGE_REPO}:${tag}
XMEDIA_HTTP_HOST_PORT=${PORT:-$MAIN_PORT}

# 90% of host RAM with 1 GB reserved for OS. GOMEMLIMIT is the Go runtime
# soft heap cap (90% of the container limit) so the GC keeps memory inside
# the cgroup and the kernel never OOM-kills us. Override either value here
# if you want to dedicate less of the box to XMedia.
XMEDIA_MEMORY_LIMIT=${TARGET_MEM_GB}g
XMEDIA_GOMEMLIMIT=${GOMEM_GB}g
XMEDIA_CPU_LIMIT=0

POSTGRES_USER=xmedia
POSTGRES_PASSWORD=${pg_pass}
POSTGRES_DB=xmedia

# Losing this passphrase permanently locks the vault — back it up now.
XMEDIA_VAULT_PASSPHRASE=${vault_pass}

XMEDIA_BOOTSTRAP_ADMIN_USERNAME=admin
XMEDIA_BOOTSTRAP_ADMIN_PASSWORD=${admin_pass}
XMEDIA_BOOTSTRAP_ADMIN_DISPLAY_NAME=Administrator
EOF
  chmod 600 "$ENV_FILE"
  log_ok "Generated secrets at $ENV_FILE"
  log_warn "Initial admin password: ${admin_pass}"
  log_warn "Back up $ENV_FILE (and XMEDIA_VAULT_PASSPHRASE especially) before continuing"
}

write_compose() {
  cat > "$COMPOSE_FILE" <<'EOF'
# Generated by install.sh — source of truth lives at
# https://github.com/secur8yai/xmedia-revoked/blob/main/docker-compose.yml
services:
  postgres:
    image: postgres:16.8-alpine
    container_name: xmedia-prod-postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER:-xmedia}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-xmedia_secret}
      POSTGRES_DB: ${POSTGRES_DB:-xmedia}
    volumes:
      - postgres_data:/var/lib/postgresql/data
    deploy:
      resources:
        limits:
          memory: 256M
    ulimits:
      nofile: { soft: 65535, hard: 65535 }
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-xmedia} -d ${POSTGRES_DB:-xmedia}"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks: [xmedia]

  xmedia:
    image: ${XMEDIA_IMAGE:-ghcr.io/secur8yai/xmedia:latest}
    container_name: xmedia-prod
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "${XMEDIA_HTTP_HOST_PORT:-8080}:8000"
    volumes:
      - xmedia_data:/data
      - xmedia_config:/config
    deploy:
      resources:
        limits:
          memory: ${XMEDIA_MEMORY_LIMIT:-14g}
          cpus: "${XMEDIA_CPU_LIMIT:-0}"
        reservations:
          memory: 1g
    mem_swappiness: 10
    ulimits:
      nofile: { soft: 65535, hard: 65535 }
      nproc: 8192
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt:
      - no-new-privileges:true
    environment:
      XMEDIA_SERVER_HOST: "0.0.0.0"
      XMEDIA_SERVER_PORT: "8000"
      XMEDIA_DATABASE_HOST: postgres
      XMEDIA_DATABASE_PORT: "5432"
      XMEDIA_DATABASE_USER: ${POSTGRES_USER:-xmedia}
      XMEDIA_DATABASE_PASSWORD: ${POSTGRES_PASSWORD:-xmedia_secret}
      XMEDIA_DATABASE_DATABASE: ${POSTGRES_DB:-xmedia}
      XMEDIA_DATABASE_SSLMODE: "disable"
      XMEDIA_DOWNLOAD_DOWNLOAD_DIR: "/data/downloads"
      XMEDIA_DOWNLOAD_DATA_DIR: "/data/xmedia"
      XMEDIA_VAULT_KEY_PATH: "/config/vault.key"
      XMEDIA_VAULT_SALT_PATH: "/config/vault.salt"
      XMEDIA_VAULT_PASSPHRASE: ${XMEDIA_VAULT_PASSPHRASE:-}
      XMEDIA_BOOTSTRAP_ADMIN_USERNAME: ${XMEDIA_BOOTSTRAP_ADMIN_USERNAME:-}
      XMEDIA_BOOTSTRAP_ADMIN_PASSWORD: ${XMEDIA_BOOTSTRAP_ADMIN_PASSWORD:-}
      XMEDIA_BOOTSTRAP_ADMIN_DISPLAY_NAME: ${XMEDIA_BOOTSTRAP_ADMIN_DISPLAY_NAME:-}
      XMEDIA_PROFILE: production
      XMEDIA_LOG_LEVEL: "info"
      XMEDIA_LOG_FORMAT: "json"
      GOMEMLIMIT: ${XMEDIA_GOMEMLIMIT:-13GiB}
      GOMAXPROCS: ${XMEDIA_GOMAXPROCS:-0}
    healthcheck:
      test: ["CMD", "/xmedia", "healthcheck"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 10s
    networks: [xmedia]

volumes:
  postgres_data:
  xmedia_data:
  xmedia_config:

networks:
  xmedia:
    name: xmedia-prod
EOF
  log_ok "Wrote compose file to $COMPOSE_FILE"
}

start_stack() {
  cd "$INSTALL_DIR"
  docker compose up -d
  log_ok "Stack started"
}

wait_ready() {
  local port="${PORT:-$MAIN_PORT}"
  local deadline=$(( $(date +%s) + 120 ))
  log_info "Waiting for http://localhost:${port}/api/v1/health/ready ..."
  until curl -fsS "http://localhost:${port}/api/v1/health/ready" >/dev/null 2>&1; do
    if (( $(date +%s) > deadline )); then
      log_error "Timed out waiting for readiness; inspect 'docker compose logs xmedia'"
      exit 1
    fi
    sleep 2
  done
  log_ok "XMedia is ready"
}

# =============================================================================
# Main
# =============================================================================
main() {
  check_root
  check_os
  check_prereqs
  check_lock

  handle_uninstall
  handle_upgrade
  handle_force

  install_docker
  mkdir -p "${INSTALL_DIR}"
  detect_host_resources
  generate_env
  write_compose
  start_stack
  wait_ready

  local port="${PORT:-$MAIN_PORT}"
  echo
  log_ok "XMedia is running at http://localhost:${port}"
  log_ok "Log in with the credentials recorded in ${ENV_FILE}"
  log_warn "After first login: rotate the password in the UI and remove XMEDIA_BOOTSTRAP_ADMIN_PASSWORD from ${ENV_FILE}"
}

main "$@"
