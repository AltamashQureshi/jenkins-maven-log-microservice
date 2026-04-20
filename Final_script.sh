#!/bin/bash
# =============================================================================
# Jenkins Docker Setup Script
# Deploys Jenkins container and configures SSH access to Kubernetes node01
# =============================================================================

set -euo pipefail

# ─── Colors & Formatting ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─── Logging Helpers ──────────────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step()    { echo -e "\n${CYAN}${BOLD}==> $*${NC}"; }
log_banner()  {
  echo -e "${BOLD}${CYAN}"
  echo "╔══════════════════════════════════════════════╗"
  echo "║        Jenkins Docker Setup Script           ║"
  echo "╚══════════════════════════════════════════════╝"
  echo -e "${NC}"
}

# ─── Configuration ────────────────────────────────────────────────────────────
JENKINS_IMAGE="jenkins/jenkins:lts-jdk21"
JENKINS_CONTAINER="jenkins"
JENKINS_HTTP_PORT="8080"
JENKINS_AGENT_PORT="50000"
SSH_KEY_PATH="/var/jenkins_home/.ssh/id_ed25519"
LOG_FILE="/tmp/jenkins-setup-$(date +%Y%m%d-%H%M%S).log"

# ─── Trap for unexpected errors ───────────────────────────────────────────────
trap 'log_error "Script failed at line $LINENO. Check log: $LOG_FILE"; exit 1' ERR

# Redirect all output to log file as well
exec > >(tee -a "$LOG_FILE") 2>&1

# ─── Prerequisite Checks ──────────────────────────────────────────────────────
check_prerequisites() {
  log_step "Checking prerequisites"
  local missing=()

  for cmd in kubectl docker ssh sshpass; do
    if command -v "$cmd" &>/dev/null; then
      log_ok "$cmd found"
    else
      log_warn "$cmd not found"
      missing+=("$cmd")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    log_error "Missing required tools: ${missing[*]}"
    log_error "Please install them and re-run this script."
    exit 1
  fi
}

# ─── Get Node01 IP ────────────────────────────────────────────────────────────
get_node01_ip() {
  log_step "Fetching node01 IP from Kubernetes"

  NODE01_IP=$(kubectl get nodes -o wide 2>/dev/null \
    | awk '/node/ {print $6}' \
    | head -n1)

  if [[ -z "$NODE01_IP" ]]; then
    log_error "Could not retrieve node01 IP. Is kubectl configured correctly?"
    exit 1
  fi

  log_ok "node01 IP: ${BOLD}$NODE01_IP${NC}"
}

# ─── Prompt for Password (hidden input) ───────────────────────────────────────
get_node_password() {
  log_step "Node01 SSH credentials"
  echo -e "${YELLOW}You will need root access to node01 ($NODE01_IP).${NC}"

  while true; do
    read -rsp "  Enter node01 root password: " NODE01_PASS
    echo
    read -rsp "  Confirm password:            " NODE01_PASS_CONFIRM
    echo

    if [[ "$NODE01_PASS" == "$NODE01_PASS_CONFIRM" ]]; then
      log_ok "Passwords match."
      break
    else
      log_warn "Passwords do not match. Please try again."
    fi
  done
}

# ─── Test SSH Connectivity ────────────────────────────────────────────────────
test_ssh_connectivity() {
  log_step "Testing SSH connectivity to node01 ($NODE01_IP)"

  if sshpass -p "$NODE01_PASS" ssh \
      -o StrictHostKeyChecking=no \
      -o ConnectTimeout=10 \
      "root@$NODE01_IP" "echo connected" &>/dev/null; then
    log_ok "SSH connection to node01 successful."
  else
    log_error "Cannot SSH into node01. Check IP address, password, and network."
    exit 1
  fi
}

# ─── Change Node01 Root Password ─────────────────────────────────────────────
change_node_password() {
  log_step "Setting root password on node01"

  sshpass -p "$NODE01_PASS" ssh \
    -o StrictHostKeyChecking=no \
    "root@$NODE01_IP" \
    "echo 'root:${NODE01_PASS}' | chpasswd" \
    && log_ok "Password updated on node01." \
    || { log_error "Failed to change password on node01."; exit 1; }
}

# ─── Pull Jenkins Image ───────────────────────────────────────────────────────
pull_jenkins_image() {
  log_step "Pulling Jenkins Docker image: $JENKINS_IMAGE"

  if docker pull "$JENKINS_IMAGE"; then
    log_ok "Image pulled successfully."
  else
    log_error "Failed to pull Jenkins image."
    exit 1
  fi
}

# ─── Remove Existing Container ────────────────────────────────────────────────
remove_existing_container() {
  if docker ps -a --format '{{.Names}}' | grep -q "^${JENKINS_CONTAINER}$"; then
    log_warn "Existing container '${JENKINS_CONTAINER}' found."
    read -rp "  Remove it and continue? [y/N]: " confirm
    if [[ "${confirm,,}" == "y" ]]; then
      docker rm -f "$JENKINS_CONTAINER"
      log_ok "Removed existing container."
    else
      log_error "Aborted by user."
      exit 1
    fi
  fi
}

# ─── Create Jenkins Container ─────────────────────────────────────────────────
create_jenkins_container() {
  log_step "Creating Jenkins container"
  remove_existing_container

  docker run -itd \
    -p "${JENKINS_HTTP_PORT}:8080" \
    -p "${JENKINS_AGENT_PORT}:50000" \
    --restart=on-failure \
    --name "$JENKINS_CONTAINER" \
    "$JENKINS_IMAGE"

  log_ok "Container '${JENKINS_CONTAINER}' started."
}

# ─── Wait for Container Readiness ────────────────────────────────────────────
wait_for_container() {
  log_step "Waiting for Jenkins container to be ready"
  local retries=10

  for ((i=1; i<=retries; i++)); do
    if docker exec "$JENKINS_CONTAINER" echo "ready" &>/dev/null; then
      log_ok "Container is ready."
      return 0
    fi
    log_info "Waiting... ($i/$retries)"
    sleep 3
  done

  log_error "Container did not become ready in time."
  exit 1
}

# ─── Install Dependencies Inside Container ────────────────────────────────────
install_dependencies() {
  log_step "Installing dependencies inside Jenkins container"
  log_info "Running: apt update + maven, openjdk-21-jdk, sshpass"

  docker exec -u 0 "$JENKINS_CONTAINER" \
    sh -c "apt update -y && apt install -y maven openjdk-21-jdk sshpass 2>&1" \
    && log_ok "Dependencies installed." \
    || { log_error "Dependency installation failed."; exit 1; }
}

# ─── Fix Permissions ─────────────────────────────────────────────────────────
fix_permissions() {
  log_step "Fixing Jenkins user permissions on /var"

  docker exec -u 0 "$JENKINS_CONTAINER" \
    sh -c "chown -R jenkins:jenkins /var/" \
    && log_ok "Permissions updated." \
    || { log_error "Failed to update permissions."; exit 1; }
}

# ─── Generate SSH Key ─────────────────────────────────────────────────────────
generate_ssh_key() {
  log_step "Generating SSH key inside Jenkins container"

  docker exec "$JENKINS_CONTAINER" \
    bash -c "mkdir -p /var/jenkins_home/.ssh && chmod 700 /var/jenkins_home/.ssh && \
             ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -N '' -q" \
    && log_ok "SSH key generated at ${SSH_KEY_PATH}." \
    || { log_error "SSH key generation failed."; exit 1; }
}

# ─── Copy SSH Key to Node01 ───────────────────────────────────────────────────
copy_ssh_key() {
  log_step "Copying SSH public key to node01 ($NODE01_IP)"

  docker exec "$JENKINS_CONTAINER" \
    bash -c "sshpass -p '${NODE01_PASS}' ssh-copy-id \
      -i ${SSH_KEY_PATH}.pub \
      -o StrictHostKeyChecking=no \
      root@${NODE01_IP}" \
    && log_ok "SSH key copied to node01." \
    || { log_error "Failed to copy SSH key to node01."; exit 1; }
}

# ─── Verify SSH Access from Jenkins ──────────────────────────────────────────
verify_ssh_from_jenkins() {
  log_step "Verifying passwordless SSH from Jenkins → node01"

  if docker exec "$JENKINS_CONTAINER" \
      bash -c "ssh -o StrictHostKeyChecking=no -i ${SSH_KEY_PATH} root@${NODE01_IP} 'echo SSH_OK'" \
      | grep -q "SSH_OK"; then
    log_ok "Passwordless SSH from Jenkins to node01 works!"
  else
    log_warn "Could not verify passwordless SSH. Please check manually."
  fi
}

# ─── Restart Jenkins ─────────────────────────────────────────────────────────
restart_jenkins() {
  log_step "Restarting Jenkins container"

  docker restart "$JENKINS_CONTAINER" \
    && log_ok "Jenkins restarted." \
    || { log_error "Failed to restart Jenkins."; exit 1; }

  log_info "Waiting for Jenkins to come back up..."
  sleep 10
}

# ─── Show Initial Admin Password ─────────────────────────────────────────────
show_admin_password() {
  log_step "Retrieving Jenkins initial admin password"

  local password
  local retries=10

  for ((i=1; i<=retries; i++)); do
    password=$(docker exec "$JENKINS_CONTAINER" \
      bash -c "cat /var/jenkins_home/secrets/initialAdminPassword 2>/dev/null || true")

    if [[ -n "$password" ]]; then
      echo ""
      echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════╗${NC}"
      echo -e "${BOLD}${GREEN}║       Jenkins Setup Complete!                ║${NC}"
      echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════╝${NC}"
      echo ""
      echo -e "  ${BOLD}Jenkins URL:${NC}           http://$(hostname -I | awk '{print $1}'):${JENKINS_HTTP_PORT}"
      echo -e "  ${BOLD}Initial Admin Password:${NC} ${YELLOW}${password}${NC}"
      echo -e "  ${BOLD}node01 IP:${NC}             ${NODE01_IP}"
      echo -e "  ${BOLD}Log file:${NC}              ${LOG_FILE}"
      echo ""
      return 0
    fi

    log_info "Password file not ready yet... ($i/$retries)"
    sleep 5
  done

  log_warn "Could not retrieve admin password automatically."
  log_info "Run manually: docker exec $JENKINS_CONTAINER bash -c 'cat /var/jenkins_home/secrets/initialAdminPassword'"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  log_banner

  check_prerequisites
  get_node01_ip
  get_node_password
  test_ssh_connectivity
  change_node_password
  pull_jenkins_image
  create_jenkins_container
  wait_for_container
  install_dependencies
  fix_permissions
  generate_ssh_key
  copy_ssh_key
  verify_ssh_from_jenkins
  restart_jenkins
  show_admin_password
}

main "$@"