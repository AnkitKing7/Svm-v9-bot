#!/bin/bash
# ============================================================================
# SVM V11.2V FULL INSTALLER
# Made by AnkitCoder
# LXC/LXD + QEMU/KVM/libvirt + WebSSH — standalone (LXC+KVM only)
# ============================================================================
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

APP_NAME="svm-v11.2v"
SERVICE_NAME="svm-v11.2v"
APP_DIR="/opt/svm-v11.2v"
DATA_DIR="/var/lib/svm-v11.2v"
CONFIG_DIR="/etc/svm-v11.2v"
LOG_DIR="/var/log/svm-v11.2v"
ENV_FILE="${CONFIG_DIR}/svm.env"
VENV_DIR="${APP_DIR}/venv"
BOT_TARGET="${APP_DIR}/bot.py"
INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
CYN='\033[0;36m'; WHT='\033[1;37m'; NC='\033[0m'
step(){ echo -e "${GRN}[+]${NC} $*"; }
info(){ echo -e "${CYN}[i]${NC} $*"; }
warn(){ echo -e "${YEL}[!]${NC} $*"; }
err(){ echo -e "${RED}[x]${NC} $*"; }
die(){ err "$*"; exit 1; }
trap 'err "Install stopped ($?)"; exit 1' ERR

banner() {
  clear || true
  echo -e "${WHT}SVM V11.2V FULL Installer • Made by AnkitCoder${NC}"
  echo
}

need_root(){ [[ "${EUID}" -eq 0 ]] || die "Run: sudo bash install_SVM_V11_2V_FULL.sh"; }
detect_os(){
  . /etc/os-release
  case "${ID:-}" in ubuntu|debian) ;; *) die "Ubuntu/Debian only";; esac
  step "OS: ${PRETTY_NAME:-$ID}"
}
confirm(){ local q="$1" d="${2:-Y}" a; [[ "${NONINTERACTIVE:-0}" == "1" ]] && return 0; read -r -p "$q [$d/n]: " a||true; a="${a:-$d}"; [[ "$a" =~ ^[Yy]$ ]]; }
apt_install(){ DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

base_packages(){
  step "Base packages..."
  apt-get update -qq
  apt_install ca-certificates curl wget git jq rsync unzip tar \
    python3 python3-pip python3-venv python3-dev build-essential pkg-config sqlite3 \
    openssh-client openssh-server iproute2 iputils-ping dnsutils net-tools \
    bridge-utils uidmap acl sudo gnupg lsb-release cloud-image-utils genisoimage
}

install_lxd(){
  step "LXD/LXC..."
  command -v snap >/dev/null || { apt_install snapd; systemctl enable --now snapd.socket snapd.service || true; sleep 2; }
  command -v lxd >/dev/null || snap install lxd
  if command -v lxd >/dev/null && ! lxc info >/dev/null 2>&1; then lxd init --auto; fi
}

install_kvm(){
  step "QEMU/KVM + libvirt..."
  apt_install qemu-system-x86 qemu-utils libvirt-daemon-system libvirt-clients virtinst ovmf \
    bridge-utils dnsmasq-base libguestfs-tools
  systemctl enable --now libvirtd 2>/dev/null || true
  systemctl enable --now virtqemud 2>/dev/null || true
  getent group libvirt >/dev/null && usermod -aG libvirt root || true
  getent group kvm >/dev/null && usermod -aG kvm root || true
  [[ -e /dev/kvm ]] && step "/dev/kvm present" || warn "No /dev/kvm — software emulation only"
  mkdir -p "${DATA_DIR}"/{images,vms,cloud-init}
}

write_env(){
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" "$LOG_DIR"
  chmod 700 "$CONFIG_DIR" "$DATA_DIR"
  [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  local token admin server_ip prefix botname
  if [[ "${NONINTERACTIVE:-0}" == "1" ]]; then
    token="${DISCORD_TOKEN:-}"; admin="${MAIN_ADMIN_ID:-}"
    server_ip="${YOUR_SERVER_IP:-127.0.0.1}"; prefix="${PREFIX:-!}"; botname="${BOT_NAME:-SVM V11.2V}"
  else
    read -r -s -p "Discord Bot Token: " token; echo
    read -r -p "Main Admin Discord ID(s): " admin
    read -r -p "Public IP/hostname [127.0.0.1]: " server_ip; server_ip="${server_ip:-127.0.0.1}"
    read -r -p "Prefix [!]: " prefix; prefix="${prefix:-!}"
    read -r -p "Bot name [SVM V11.2V]: " botname; botname="${botname:-SVM V11.2V}"
  fi
  [[ -n "$token" ]] || die "DISCORD_TOKEN required"
  [[ -n "$admin" ]] || die "MAIN_ADMIN_ID required"
  cat > "$ENV_FILE" <<EOF
DISCORD_TOKEN=${token}
MAIN_ADMIN_ID=${admin}
YOUR_SERVER_IP=${server_ip}
BOT_NAME=${botname}
BOT_VERSION=11.2V
BOT_DEVELOPER=AnkitCoder
PREFIX=${prefix}
SVM_PROVIDER_MODE=lxc
SVM_DATA_DIR=${DATA_DIR}
SVM_LOG_DIR=${LOG_DIR}
SVM_DB_PATH=${DATA_DIR}/vps.db
WEBSSH_ENABLED=true
WEBSSH_PORT=5000
WEBSSH_SERVER_IP=${server_ip}
WEBSSH_URL_FORMAT=http://{SERVER_IP}:{PORT}
DEFAULT_STORAGE_POOL=default
LIBVIRT_URI=qemu:///system
LIBVIRT_NETWORK=default
SVM_IMAGES_DIR=${DATA_DIR}/images
SVM_VMS_DIR=${DATA_DIR}/vms
SVM_CLOUDINIT_DIR=${DATA_DIR}/cloud-init
EOF
  chmod 600 "$ENV_FILE"
  step "Env written (0600)"
}

install_python(){
  step "Python venv..."
  mkdir -p "$APP_DIR"
  python3 -m venv "$VENV_DIR"
  "${VENV_DIR}/bin/pip" install --upgrade pip setuptools wheel
  if [[ -f "$INSTALLER_DIR/requirements.txt" ]]; then
    "${VENV_DIR}/bin/pip" install -r "$INSTALLER_DIR/requirements.txt"
  else
    "${VENV_DIR}/bin/pip" install discord.py requests python-dotenv paramiko Flask flask-cors Pillow
  fi
}

deploy(){
  step "Deploy bot..."
  local src=""
  for f in SVM_V11_2V_FULL.py bot.py; do
    [[ -f "$INSTALLER_DIR/$f" ]] && src="$INSTALLER_DIR/$f" && break
  done
  [[ -n "$src" ]] || die "Bot source not found"
  install -m 0750 "$src" "$BOT_TARGET"
  mkdir -p "$APP_DIR/static"
  [[ -f "$INSTALLER_DIR/static/webssh.html" ]] && cp -a "$INSTALLER_DIR/static/webssh.html" "$APP_DIR/static/"
  [[ -d "$INSTALLER_DIR/providers" ]] && cp -a "$INSTALLER_DIR/providers" "$APP_DIR/"
  [[ -d "$INSTALLER_DIR/db" ]] && cp -a "$INSTALLER_DIR/db" "$APP_DIR/"
  "${VENV_DIR}/bin/python" -m py_compile "$BOT_TARGET" || warn "Syntax warnings"
}

write_service(){
  step "systemd service..."
  cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=SVM V11.2V Discord VPS Bot + WebSSH
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${DATA_DIR}
EnvironmentFile=${ENV_FILE}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=${APP_DIR}
ExecStart=${VENV_DIR}/bin/python ${BOT_TARGET}
Restart=always
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGINT
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${DATA_DIR} ${LOG_DIR} ${CONFIG_DIR} ${APP_DIR} /var/lib/lxd /var/lib/libvirt
StandardOutput=append:${LOG_DIR}/bot.log
StandardError=append:${LOG_DIR}/bot-error.log

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

health(){
  step "Health..."
  command -v lxc >/dev/null && lxc info >/dev/null 2>&1 && echo "  LXD OK" || echo "  LXD ?"
  command -v virsh >/dev/null && echo "  libvirt OK" || echo "  libvirt missing"
  [[ -e /dev/kvm ]] && echo "  /dev/kvm OK" || echo "  /dev/kvm missing"
  [[ -f "$ENV_FILE" && "$(stat -c '%a' "$ENV_FILE")" == "600" ]] && echo "  env 0600 OK" || warn "env perms"
}

start_svc(){
  step "Start service..."
  systemctl restart "$SERVICE_NAME"
  sleep 3
  systemctl is-active --quiet "$SERVICE_NAME" && echo -e "${GRN}✓ Running${NC}" || {
    warn "Not active"; journalctl -u "$SERVICE_NAME" -n 40 --no-pager || true
  }
}

main(){
  banner; need_root; detect_os; base_packages; install_lxd
  confirm "Install QEMU/KVM + libvirt?" "Y" && install_kvm
  install_python; write_env; deploy; write_service; health; start_svc
  echo
  echo -e "${WHT}SVM V11.2V install complete • Made by AnkitCoder${NC}"
  echo "  systemctl status ${SERVICE_NAME}"
  echo "  journalctl -u ${SERVICE_NAME} -f"
  echo "  WebSSH: http://YOUR_IP:5000 (if WEBSSH_ENABLED)"
}
main "$@"
