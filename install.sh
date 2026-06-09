#!/usr/bin/env bash
# VPS Dashboard — one-click installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/david-hummingbot/vps-dashboard/main/install.sh | bash
#
# Environment variables (optional):
#   INSTALL_DIR   Where to clone the repo (default: ~/vps-dashboard)
#   REPO_URL      Git remote (default: https://github.com/david-hummingbot/vps-dashboard.git)
#   BRANCH        Git branch (default: main)
#   ROLE          Skip prompt: "server" or "agent"

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/david-hummingbot/vps-dashboard.git}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/vps-dashboard}"
BRANCH="${BRANCH:-main}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

msg_info()  { echo -e "  ${CYAN}→${RESET} $1"; }
msg_ok()    { echo -e "  ${GREEN}✓${RESET} $1"; }
msg_warn()  { echo -e "  ${YELLOW}!${RESET} $1"; }
msg_error() { echo -e "  ${RED}✗${RESET} $1"; }

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prompt() {
  local prompt_text="$1"
  local default="${2:-}"
  local var_name="$3"
  local value=""

  if [ -n "$default" ]; then
    echo -ne "  ${prompt_text} ${DIM}[${default}]${RESET}: " >&2
  else
    echo -ne "  ${prompt_text}: " >&2
  fi
  read -r value < /dev/tty || value=""
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_secret() {
  local prompt_text="$1"
  local default="${2:-}"
  local var_name="$3"
  local value=""

  if [ -n "$default" ]; then
    echo -ne "  ${prompt_text} ${DIM}[hidden / Enter to keep default]${RESET}: " >&2
  else
    echo -ne "  ${prompt_text}: " >&2
  fi
  read -rs value < /dev/tty || value=""
  echo "" >&2
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  if [ -z "$value" ] && [ -n "$default" ]; then
    value="$default"
  fi
  printf -v "$var_name" '%s' "$value"
}

prompt_yes_no() {
  local prompt_text="$1"
  local default="${2:-y}"
  local value=""
  local hint="Y/n"
  [ "$default" = "n" ] && hint="y/N"

  echo -ne "  ${prompt_text} ${DIM}[${hint}]${RESET}: " >&2
  read -r value < /dev/tty || value=""
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  if [ -z "$value" ]; then
    value="$default"
  fi
  [ "$value" = "y" ] || [ "$value" = "yes" ]
}

write_env_line() {
  local key="$1"
  local value="$2"
  if [[ "$value" =~ [^A-Za-z0-9._/-] ]]; then
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s="%s"\n' "$key" "$value"
  else
    printf '%s=%s\n' "$key" "$value"
  fi
}

generate_api_key() {
  if command_exists openssl; then
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  fi
}

detect_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command_exists docker-compose; then
    COMPOSE=(docker-compose)
  else
    msg_error "Docker Compose not found. Install Docker Compose v2 or docker-compose."
    exit 1
  fi
}

ensure_docker() {
  if ! command_exists docker; then
    msg_error "Docker is not installed."
    echo ""
    echo "  Install Docker first, then re-run this script:"
    echo "    curl -fsSL https://get.docker.com | sh"
    exit 1
  fi

  if ! docker info >/dev/null 2>&1; then
    msg_error "Cannot connect to the Docker daemon."
    echo ""
    echo "  Try: sudo usermod -aG docker \$USER && newgrp docker"
    echo "  Or re-run this script with sudo."
    exit 1
  fi
}

EXISTING_INSTALL=0

ensure_repo() {
  if [ -d "$INSTALL_DIR/server" ] && [ -d "$INSTALL_DIR/agent" ]; then
    EXISTING_INSTALL=1
    msg_info "Found existing install at ${INSTALL_DIR}"
  else
    msg_info "Cloning ${REPO_URL} → ${INSTALL_DIR}"
    if [ -e "$INSTALL_DIR" ]; then
      msg_error "Install path exists but is not a vps-dashboard checkout: ${INSTALL_DIR}"
      exit 1
    fi
    if ! git clone --branch "$BRANCH" --depth 1 --quiet "$REPO_URL" "$INSTALL_DIR"; then
      msg_error "Failed to clone repository"
      exit 1
    fi
    msg_ok "Repository ready"
  fi
  cd "$INSTALL_DIR"
}

choose_role() {
  SELECTED_ROLE=""

  if [ -n "${ROLE:-}" ]; then
    case "$ROLE" in
      server|agent|update) SELECTED_ROLE="$ROLE"; return ;;
      *)
        msg_error "ROLE must be 'server', 'agent', or 'update' (got: ${ROLE})"
        exit 1
        ;;
    esac
  fi

  echo ""
  echo -e "${BOLD}What would you like to do?${RESET}"
  echo ""
  echo "    1) Dashboard server  — central monitoring UI"
  echo "    2) Agent             — metric collector for this VPS"
  if [ "$EXISTING_INSTALL" = "1" ]; then
    echo "    3) Update            — pull latest and restart containers"
  fi
  echo ""
  local choice=""
  while true; do
    prompt "Enter choice" "1" choice
    case "$choice" in
      1|server|s) SELECTED_ROLE="server"; return ;;
      2|agent|a)  SELECTED_ROLE="agent"; return ;;
      3|update|u)
        if [ "$EXISTING_INSTALL" = "1" ]; then
          SELECTED_ROLE="update"; return
        fi
        msg_warn "Update is only available for an existing install"
        ;;
      *) msg_warn "Please enter a valid option" ;;
    esac
  done
}

pull_latest() {
  if [ ! -d "$INSTALL_DIR/.git" ]; then
    msg_warn "Not a git checkout; skipping pull"
    return
  fi
  msg_info "Pulling latest changes..."
  if git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH" >/dev/null 2>&1; then
    msg_ok "Updated to latest ${BRANCH}"
  else
    msg_warn "Could not pull latest changes; continuing with local copy"
  fi
}

run_update() {
  pull_latest

  local updated=0
  if [ -f "server/.env" ]; then
    msg_info "Rebuilding dashboard server..."
    (cd server && "${COMPOSE[@]}" up -d --build)
    msg_ok "Dashboard server restarted"
    updated=1
  fi
  if [ -f "agent/.env" ]; then
    msg_info "Rebuilding agent..."
    (cd agent && "${COMPOSE[@]}" up -d --build)
    msg_ok "Agent restarted"
    updated=1
  fi

  if [ "$updated" = "0" ]; then
    msg_warn "No configured service found (no server/.env or agent/.env)."
    msg_warn "Re-run and choose 'server' or 'agent' to configure one."
  fi
}

configure_server() {
  local env_file="server/.env"
  local api_key=""
  local discord=""
  local telegram_token=""
  local telegram_chat=""
  local cpu_threshold="90"
  local ram_threshold="90"
  local disk_threshold="90"
  local offline_threshold="120"

  echo ""
  echo -e "${BOLD}Dashboard server configuration${RESET}"
  echo ""
  echo "  Create keys at: https://login.tailscale.com/admin/settings/keys (for agents later)"
  echo ""

  if [ -f "$env_file" ] && ! prompt_yes_no "Overwrite existing server/.env?"; then
    msg_warn "Keeping existing server/.env"
    return
  fi

  local generated_key
  generated_key="$(generate_api_key)"
  msg_info "Press Enter to auto-generate a random API key"
  prompt_secret "API key (shared with agents)" "$generated_key" api_key
  [ -z "$api_key" ] && api_key="$generated_key"

  echo ""
  echo -e "  ${DIM}Optional notifications (press Enter to skip)${RESET}"
  prompt "Discord webhook URL" "" discord
  prompt "Telegram bot token" "" telegram_token
  prompt "Telegram chat ID" "" telegram_chat

  {
    write_env_line "API_KEY" "$api_key"
    write_env_line "DISCORD_WEBHOOK_URL" "$discord"
    write_env_line "TELEGRAM_BOT_TOKEN" "$telegram_token"
    write_env_line "TELEGRAM_CHAT_ID" "$telegram_chat"
    write_env_line "ALERT_CPU_THRESHOLD" "$cpu_threshold"
    write_env_line "ALERT_RAM_THRESHOLD" "$ram_threshold"
    write_env_line "ALERT_DISK_THRESHOLD" "$disk_threshold"
    write_env_line "OFFLINE_THRESHOLD_SECONDS" "$offline_threshold"
  } > "$env_file"

  msg_ok "Wrote server/.env"
  SERVER_API_KEY="$api_key"
}

configure_agent() {
  local env_file="agent/.env"
  local ts_authkey=""
  local dashboard_url=""
  local api_key=""
  local node_name=""
  local report_interval="30"

  echo ""
  echo -e "${BOLD}Agent configuration${RESET}"
  echo ""
  echo "  Tailscale auth key: https://login.tailscale.com/admin/settings/keys"
  echo "  Dashboard URL:     https://<machine>.<tailnet>.ts.net  (Tailscale Serve URL)"
  echo ""

  if [ -f "$env_file" ] && ! prompt_yes_no "Overwrite existing agent/.env?"; then
    msg_warn "Keeping existing agent/.env"
    return
  fi

  while [ -z "$ts_authkey" ]; do
    prompt_secret "Tailscale auth key (TS_AUTHKEY)" "" ts_authkey
    [ -z "$ts_authkey" ] && msg_warn "TS_AUTHKEY is required"
  done

  while [ -z "$dashboard_url" ]; do
    prompt "Dashboard URL (DASHBOARD_URL)" "" dashboard_url
    [ -z "$dashboard_url" ] && msg_warn "DASHBOARD_URL is required"
  done

  while [ -z "$api_key" ]; do
    prompt_secret "API key (must match server)" "" api_key
    [ -z "$api_key" ] && msg_warn "API key is required"
  done

  node_name="$(hostname -s 2>/dev/null || hostname)"
  prompt "Node name" "$node_name" node_name
  prompt "Report interval (seconds)" "$report_interval" report_interval

  {
    write_env_line "TS_AUTHKEY" "$ts_authkey"
    write_env_line "DASHBOARD_URL" "$dashboard_url"
    write_env_line "API_KEY" "$api_key"
    write_env_line "NODE_NAME" "$node_name"
    write_env_line "REPORT_INTERVAL" "$report_interval"
  } > "$env_file"

  msg_ok "Wrote agent/.env"
}

start_server() {
  msg_info "Building and starting dashboard server..."
  (cd server && "${COMPOSE[@]}" up -d --build)
  msg_ok "Dashboard server is running on http://127.0.0.1:8080"

  if command_exists tailscale && tailscale status >/dev/null 2>&1; then
    echo ""
    if prompt_yes_no "Enable Tailscale Serve for HTTPS access? (tailscale serve 8080)"; then
      if tailscale serve --bg 8080 >/dev/null 2>&1; then
        local serve_url=""
        serve_url="$(tailscale serve status 2>/dev/null | grep -Eo 'https://[^ ]+\.ts\.net' | head -1 || true)"
        if [ -n "$serve_url" ]; then
          msg_ok "Tailscale Serve enabled: ${serve_url}"
          echo ""
          echo -e "  ${BOLD}Give agents this URL:${RESET} ${serve_url}"
        else
          msg_ok "Tailscale Serve enabled. Check: tailscale serve status"
        fi
      else
        msg_warn "Could not enable Tailscale Serve. Run manually: tailscale serve 8080"
      fi
    fi
  else
    echo ""
    msg_warn "Tailscale not detected on this host."
    echo "  After installing Tailscale, expose the dashboard with:"
    echo "    tailscale serve 8080"
    echo "  Then give agents the https://<machine>.<tailnet>.ts.net URL."
  fi

  if [ -n "${SERVER_API_KEY:-}" ]; then
    echo ""
    echo -e "  ${BOLD}API key for agents:${RESET} ${SERVER_API_KEY}"
  fi
}

start_agent() {
  msg_info "Building and starting agent + Tailscale sidecar..."
  (cd agent && "${COMPOSE[@]}" up -d --build)
  msg_ok "Agent is running"
  msg_info "Check logs: docker logs -f vps-agent"
}

banner() {
  echo ""
  echo -e "${BOLD}╔═══════════════════════════════════════════╗${RESET}"
  echo -e "${BOLD}║         VPS Dashboard Installer           ║${RESET}"
  echo -e "${BOLD}╚═══════════════════════════════════════════╝${RESET}"
  echo ""
}

main() {
  banner

  msg_info "Checking prerequisites..."
  ensure_docker
  detect_compose
  if ! command_exists git; then
    msg_error "git is required but not installed."
    exit 1
  fi
  msg_ok "Docker and git are available"

  ensure_repo

  choose_role
  local role="$SELECTED_ROLE"

  case "$role" in
    server)
      configure_server
      start_server
      echo ""
      echo -e "${GREEN}${BOLD}Dashboard server installed!${RESET}"
      echo ""
      echo "  Directory:  ${INSTALL_DIR}/server"
      echo "  Logs:       docker logs -f vps-dashboard"
      echo "  Restart:    cd ${INSTALL_DIR}/server && docker compose restart"
      ;;
    agent)
      configure_agent
      start_agent
      echo ""
      echo -e "${GREEN}${BOLD}Agent installed!${RESET}"
      echo ""
      echo "  Directory:  ${INSTALL_DIR}/agent"
      echo "  Logs:       docker logs -f vps-agent"
      echo "  Restart:    cd ${INSTALL_DIR}/agent && docker compose restart"
      ;;
    update)
      run_update
      echo ""
      echo -e "${GREEN}${BOLD}Update complete!${RESET}"
      ;;
  esac
  echo ""
}

main "$@"
