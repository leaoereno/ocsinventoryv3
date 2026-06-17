#!/usr/bin/env bash
#
# install-ocsinventory-3.0.sh
#
# Instalacao completa e majoritariamente desassistida do OCS Inventory 3.0
# (tag 3.0.0-rc1) em um UNICO servidor de testes/laboratorio.
#
# Suporta duas familias de distribuicao, detectadas automaticamente:
#   - Debian:  Ubuntu 22.04/24.04, Debian 12/13 (apt/apt-get, ufw)
#   - RHEL:    RHEL 8/9, Rocky Linux, AlmaLinux, Fedora (dnf/yum, firewalld,
#              com ajustes de SELinux quando ele estiver enforcing/permissive)
#
# Baseado no runbook "OCS-Inventory-3.0-Instalacao-Servidor-Unico.md",
# que por sua vez foi construido a partir do codigo-fonte oficial publicado
# em github.com/OCSInventory-NG (tags 3.0.0-rc1 dos repositorios Backend,
# Frontend, Agent e SNMP Scanner).
#
# Uso:
#   sudo ./install-ocsinventory-3.0.sh [opcoes]
#
# Sem nenhuma opcao, o script roda de forma 100% nao-interativa: detecta o
# IP do servidor, gera senhas aleatorias, instala e configura tudo, e no
# final imprime (e salva em /root/ocsinventory-credentials.txt) um resumo
# com URLs e credenciais.
#
# Use --help para ver todas as opcoes.

set -Eeuo pipefail

#############################################
# Configuracao padrao (sobrescrevivel via flags)
#############################################
OCS_TAG="3.0.0-rc1"
BASE_DIR="/opt/ocsinventory"
OCS_SYS_USER="ocs"

BACKEND_PORT="8000"
FRONTEND_PORT="8080"

DB_NAME="ocsdb"
DB_USER="ocsuser"
DB_PASSWORD=""

ADMIN_USER="admin"
ADMIN_EMAIL="admin@localhost"
ADMIN_PASSWORD=""

SERVER_HOST=""
SNMP_SUBNET=""

SKIP_SNMP=0
SKIP_AGENT=0
ASSUME_YES=0

LOG_FILE="/var/log/ocsinventory-install.log"
CRED_FILE="/root/ocsinventory-credentials.txt"

GIT_BACKEND_URL="https://github.com/OCSInventory-NG/OCSInventory-Server-Backend-Rework.git"
GIT_FRONTEND_URL="https://github.com/OCSInventory-NG/OCSInventory-Server-Frontend-Rework.git"
GIT_SNMP_URL="https://github.com/OCSInventory-NG/OCSInventory-SNMP-Scanner.git"
GIT_AGENT_URL="https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework.git"

PYTHON_BIN=""
ID=""
ID_LIKE=""
PRETTY_NAME=""
PKG_FAMILY=""   # "debian" ou "rhel", definido por detect_os()
PKG_MGR=""      # "apt-get", "dnf" ou "yum", definido por detect_os()
CURRENT_STEP=""

STEP_ORDER=()
declare -A STEP_STATUS

#############################################
# Utilitarios de log / controle
#############################################
RED=$'\033[0;31m'; YEL=$'\033[1;33m'; GRN=$'\033[0;32m'; BLU=$'\033[0;34m'; NC=$'\033[0m'

ts() { date '+%Y-%m-%d %H:%M:%S'; }
info() { echo "${GRN}[INFO ${BLU}$(ts)${NC}${GRN}]${NC} $*"; }
warn() { echo "${YEL}[AVISO $(ts)]${NC} $*" >&2; }
err()  { echo "${RED}[ERRO  $(ts)]${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

on_err_trap() {
  err "Falha na etapa atual: ${CURRENT_STEP:-(desconhecida)} -- linha $LINENO (comando: $BASH_COMMAND). Detalhes em $LOG_FILE."
}
trap on_err_trap ERR

mark_step() {
  local name=$1 status=$2
  if [[ -z "${STEP_STATUS[$name]+x}" ]]; then
    STEP_ORDER+=("$name")
  fi
  STEP_STATUS[$name]="$status"
}

# IMPORTANTE: "$@" e chamado de forma direta (NAO como condicao de um if),
# de proposito. Bash suspende o efeito de "set -e" durante TODA a execucao
# de um comando (incluindo chamadas de funcao aninhadas) quando esse
# comando e usado como condicao de if/while/&&/||. Isso significa que
# colocar a etapa inteira dentro de "if minha_funcao; then" mascararia
# qualquer falha no MEIO da funcao, desde que o ultimo comando dela tivesse
# sucesso -- e foi exatamente isso que aconteceu na pratica (um "git fetch"
# falhou no meio de install_backend(), mas como a chamada estava dentro de
# um if, a etapa toda foi marcada como OK). Chamando "$@" diretamente,
# qualquer falha em qualquer ponto da etapa aciona o "set -e" normalmente e
# aborta o script (via on_err_trap), exatamente como em qualquer outro
# comando do script. Isso tambem preserva variaveis globais definidas
# dentro da etapa (ex.: PYTHON_BIN), que se perderiam se a etapa rodasse
# numa subshell.
run_required() {
  local name=$1; shift
  CURRENT_STEP="$name"
  info ">>> $name"
  "$@"
  mark_step "$name" "OK"
}

# Para etapas opcionais, queremos capturar a falha e CONTINUAR o script,
# o que exige um contexto exempt de "set -e" (se nao, a falha abortaria
# tudo). Para nao reintroduzir o mesmo problema do run_required antigo,
# a etapa roda isolada numa subshell com seu PROPRIO "set -e", entao uma
# falha no meio da etapa ainda aborta a etapa imediatamente (so que dentro
# da subshell, sem afetar o processo principal) em vez de mascarar o erro
# ate o ultimo comando. O efeito colateral aceitavel e que variaveis
# definidas dentro de uma etapa opcional nao persistem depois dela -- o
# que e seguro aqui, pois nenhuma etapa opcional (SNMP Scanner, Agente)
# define variavel global usada por etapas posteriores.
run_optional() {
  local name=$1; shift
  CURRENT_STEP="$name (opcional)"
  info ">>> $name (opcional)"
  local status
  set +e
  trap - ERR
  ( trap - ERR; set -Eeuo pipefail; "$@" )
  status=$?
  trap on_err_trap ERR
  set -e
  if [ "$status" -eq 0 ]; then
    mark_step "$name" "OK"
  else
    mark_step "$name" "FALHOU (opcional - instalacao principal nao foi afetada)"
    warn "Etapa opcional '$name' falhou (veja $LOG_FILE); seguindo com o restante da instalacao."
  fi
}

retry() {
  local max=$1; shift
  local delay=$1; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$max" ]; then
      return 1
    fi
    warn "Comando falhou (tentativa $n/$max), tentando novamente em ${delay}s: $*"
    sleep "$delay"
    n=$((n + 1))
  done
}

#############################################
# Deteccao / espera
#############################################
need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "Execute este script como root (ex: sudo $0)."
  fi
}

detect_os() {
  if [ ! -f /etc/os-release ]; then
    die "Nao foi possivel detectar o sistema operacional (/etc/os-release ausente)."
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Sistema detectado: ${PRETTY_NAME:-desconhecido}"

  if command -v apt-get &>/dev/null; then
    PKG_FAMILY="debian"
    PKG_MGR="apt-get"
  elif command -v dnf &>/dev/null; then
    PKG_FAMILY="rhel"
    PKG_MGR="dnf"
  elif command -v yum &>/dev/null; then
    PKG_FAMILY="rhel"
    PKG_MGR="yum"
  else
    die "Nao foi possivel identificar um gerenciador de pacotes suportado (apt-get, dnf ou yum) neste sistema."
  fi

  case "${ID:-}" in
    ubuntu|debian|rhel|centos|rocky|almalinux|fedora) ;;
    *)
      case "${ID_LIKE:-}" in
        *debian*|*rhel*|*fedora*) ;;
        *) warn "Distribuicao '${ID:-desconhecida}' nao testada oficialmente pelo projeto; seguindo no modo '$PKG_FAMILY' com base no gerenciador de pacotes detectado ($PKG_MGR)." ;;
      esac
      ;;
  esac

  info "Familia de pacotes: $PKG_FAMILY (gerenciador: $PKG_MGR)"
}

# Wrapper de instalacao de pacotes para a familia RHEL (dnf ou yum),
# espelhando o apt_install() ja existente para a familia Debian.
pkg_install() {
  if [ "$PKG_MGR" = "dnf" ]; then
    retry 3 5 dnf install -y "$@"
  else
    retry 3 5 yum install -y "$@"
  fi
}

detect_ip() {
  local ip=""
  ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}') || true
  if [ -z "$ip" ]; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  if [ -z "$ip" ]; then
    ip="127.0.0.1"
  fi
  echo "$ip"
}

detect_subnet() {
  local cidr
  cidr=$(ip -o -f inet addr show scope global 2>/dev/null | awk '{print $4}' | head -n1) || true
  if [ -z "$cidr" ]; then
    echo "192.168.0.0/24"
    return 0
  fi
  if command -v python3 &>/dev/null; then
    python3 - "$cidr" <<'PYEOF' 2>/dev/null || echo "$cidr"
import ipaddress, sys
try:
    print(ipaddress.ip_interface(sys.argv[1]).network)
except Exception:
    print(sys.argv[1])
PYEOF
  else
    echo "$cidr"
  fi
}

gen_password() {
  local len=${1:-20}
  tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$len" || true
  echo
}

wait_for_active() {
  local unit=$1 timeout=${2:-30} start
  start=$(date +%s)
  while ! systemctl is-active --quiet "$unit"; do
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      return 1
    fi
    sleep 2
  done
  return 0
}

wait_for_http() {
  local url=$1 timeout=${2:-30} start
  start=$(date +%s)
  while ! curl -fsS -o /dev/null "$url" 2>/dev/null; do
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
      return 1
    fi
    sleep 2
  done
  return 0
}

ver_ge_312() {
  local v=$1 major minor
  major=${v%%.*}
  minor=${v#*.}
  minor=${minor%%.*}
  [[ "$major" =~ ^[0-9]+$ ]] || return 1
  [[ "$minor" =~ ^[0-9]+$ ]] || return 1
  if [ "$major" -gt 3 ]; then return 0; fi
  if [ "$major" -eq 3 ] && [ "$minor" -ge 12 ]; then return 0; fi
  return 1
}

check_port_free_or_nginx() {
  local port=$1
  if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
    if ! ss -tlnp 2>/dev/null | grep ":${port} " | grep -q nginx; then
      die "A porta ${port} ja esta em uso por outro processo que nao o Nginx. Escolha outra porta (--backend-port/--frontend-port) ou libere a porta."
    fi
  fi
  return 0
}

disable_default_nginx_site_if_needed() {
  local port=$1
  if [ "$port" = "80" ] && [ -f /etc/nginx/sites-enabled/default ]; then
    info "Removendo site 'default' do Nginx (porta 80 sera usada pelo OCS Inventory)."
    rm -f /etc/nginx/sites-enabled/default
  fi
}

#############################################
# apt / pacotes
#############################################
apt_wait_lock() {
  command -v fuser &>/dev/null || return 0
  local tries=0
  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 30 ]; then
      warn "dpkg/apt parece bloqueado ha muito tempo; seguindo mesmo assim."
      break
    fi
    info "Aguardando outro processo apt/dpkg liberar o lock..."
    sleep 5
  done
}

apt_install() {
  apt_wait_lock
  retry 3 5 env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

install_base_packages() {
  case "$PKG_FAMILY" in
    debian)
      apt_wait_lock
      retry 3 5 apt-get update -y
      apt_install build-essential curl wget git unzip software-properties-common \
        ca-certificates gnupg lsb-release python3 nginx ufw psmisc iproute2
      ;;
    rhel)
      pkg_install epel-release || warn "Nao foi possivel instalar epel-release (normal em Fedora, que ja inclui tudo); seguindo."
      pkg_install dnf-plugins-core || true
      pkg_install gcc gcc-c++ make curl wget git unzip ca-certificates gnupg2 \
        python3 nginx firewalld psmisc iproute
      pkg_install policycoreutils-python-utils || \
        warn "Nao foi possivel instalar policycoreutils-python-utils (semanage); se o SELinux estiver enforcing, os ajustes automaticos de contexto serao pulados."
      ;;
  esac
}

create_system_user() {
  if id "$OCS_SYS_USER" &>/dev/null; then
    info "Usuario de sistema '$OCS_SYS_USER' ja existe."
  else
    useradd --system --create-home --shell /usr/sbin/nologin "$OCS_SYS_USER"
  fi
  mkdir -p "$BASE_DIR"
  chown "$OCS_SYS_USER":"$OCS_SYS_USER" "$BASE_DIR"
}

setup_firewall() {
  case "$PKG_FAMILY" in
    debian)
      if ! command -v ufw &>/dev/null; then
        warn "ufw nao disponivel; pulando configuracao de firewall (ajuste manualmente se necessario)."
        return 0
      fi
      ufw allow OpenSSH >/dev/null 2>&1 || true
      ufw allow "${BACKEND_PORT}/tcp" >/dev/null 2>&1 || true
      ufw allow "${FRONTEND_PORT}/tcp" >/dev/null 2>&1 || true
      if ufw status | grep -qi "inactive"; then
        info "Habilitando ufw..."
        ufw --force enable
      fi
      ;;
    rhel)
      if ! command -v firewall-cmd &>/dev/null; then
        warn "firewalld nao disponivel; pulando configuracao de firewall (ajuste manualmente se necessario)."
        return 0
      fi
      systemctl enable --now firewalld 2>/dev/null || true
      if systemctl is-active --quiet firewalld; then
        firewall-cmd --permanent --add-port="${BACKEND_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port="${FRONTEND_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
      else
        warn "firewalld nao iniciou; pulando regras de firewall (ajuste manualmente se necessario)."
      fi
      ;;
  esac
  return 0
}

#############################################
# SELinux (apenas relevante na familia RHEL)
#############################################
selinux_active() {
  [ "$PKG_FAMILY" = "rhel" ] || return 1
  command -v getenforce &>/dev/null || return 1
  local mode
  mode=$(getenforce 2>/dev/null) || return 1
  [ "$mode" = "Enforcing" ] || [ "$mode" = "Permissive" ]
}

selinux_allow_http_port() {
  local port=$1
  selinux_active || return 0
  command -v semanage &>/dev/null || return 0
  if ! semanage port -l 2>/dev/null | grep -Eq "(^| )${port}( |,|$)"; then
    info "Liberando a porta ${port}/tcp para o dominio SELinux http_port_t..."
    semanage port -a -t http_port_t -p tcp "$port" 2>/dev/null || \
      semanage port -m -t http_port_t -p tcp "$port" 2>/dev/null || \
      warn "Nao foi possivel registrar a porta ${port} no SELinux via semanage."
  fi
}

selinux_label_path() {
  local path=$1 ctx=$2
  selinux_active || return 0
  command -v semanage &>/dev/null || return 0
  info "Aplicando contexto SELinux ${ctx} em ${path}..."
  semanage fcontext -a -t "$ctx" "${path}(/.*)?" 2>/dev/null || \
    semanage fcontext -m -t "$ctx" "${path}(/.*)?" 2>/dev/null || true
  if command -v restorecon &>/dev/null; then
    restorecon -Rv "$path" >/dev/null 2>&1 || true
  fi
}

#############################################
# Python 3.12 (exigido pelo backend - Django 6.0+)
#############################################
ensure_python312() {
  local c v
  for c in python3.12 python3; do
    if command -v "$c" &>/dev/null; then
      v=$("$c" -c 'import sys;print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
      if ver_ge_312 "$v"; then
        PYTHON_BIN=$(command -v "$c")
        info "Usando $PYTHON_BIN (Python $v)."
        ensure_python_dev_headers "$c"
        return 0
      fi
    fi
  done

  info "Python 3.12+ nao encontrado; tentando instalar via gerenciador de pacotes..."
  case "$PKG_FAMILY" in
    debian)
      if [ "${ID:-}" = "ubuntu" ]; then
        apt_install software-properties-common
        add-apt-repository -y ppa:deadsnakes/ppa || true
        retry 3 5 apt-get update -y || true
      fi
      if apt_install python3.12 python3.12-venv python3.12-dev; then
        PYTHON_BIN=$(command -v python3.12)
        info "Python 3.12 instalado via apt."
        return 0
      fi
      ;;
    rhel)
      if pkg_install python3.12 python3.12-devel; then
        PYTHON_BIN=$(command -v python3.12)
        info "Python 3.12 instalado via $PKG_MGR."
        return 0
      fi
      ;;
  esac

  warn "Nao foi possivel instalar Python 3.12 via $PKG_MGR; tentando via pyenv (fallback, compila do source e pode demorar varios minutos)..."
  install_python_via_pyenv
}

# Garante que os headers de build (Python.h) e o modulo venv/ensurepip
# estao instalados, mesmo quando o Python 3.12 ja vem de fabrica na distro
# (caso do Ubuntu 24.04 e do AlmaLinux/Rocky 9.4+/10, que ja trazem
# python3 = 3.12 por padrao mas SEM os headers de build -- estes ficam
# num pacote -dev/-devel separado e sao exigidos para compilar extensoes
# em C como python-ldap e uwsgi).
ensure_python_dev_headers() {
  local bin_name=$1   # "python3.12" (binario versionado) ou "python3" (padrao do sistema)
  case "$PKG_FAMILY" in
    debian)
      if [ "$bin_name" = "python3.12" ]; then
        apt_install python3.12-dev python3.12-venv
      else
        apt_install python3-dev python3-venv
      fi
      ;;
    rhel)
      if [ "$bin_name" = "python3.12" ]; then
        pkg_install python3.12-devel
      else
        pkg_install python3-devel
      fi
      ;;
  esac
}

install_python_via_pyenv() {
  case "$PKG_FAMILY" in
    debian)
      apt_install make build-essential libssl-dev zlib1g-dev libbz2-dev \
        libreadline-dev libsqlite3-dev curl llvm libncursesw5-dev xz-utils \
        tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev git
      ;;
    rhel)
      pkg_install gcc gcc-c++ make patch zlib-devel bzip2 bzip2-devel \
        readline-devel sqlite sqlite-devel openssl-devel tk-devel \
        libffi-devel xz-devel git
      ;;
  esac

  export PYENV_ROOT="/root/.pyenv"
  if [ ! -d "$PYENV_ROOT" ]; then
    curl -fsSL https://pyenv.run | bash
  fi
  export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$("$PYENV_ROOT/bin/pyenv" init -)"
  "$PYENV_ROOT/bin/pyenv" install -s 3.12.8

  PYTHON_BIN="$PYENV_ROOT/versions/3.12.8/bin/python3.12"
  if [ ! -x "$PYTHON_BIN" ]; then
    die "Falha ao instalar Python 3.12 via pyenv."
  fi
  info "Python 3.12 instalado via pyenv em $PYTHON_BIN"
}

#############################################
# Node.js 20 (frontend) e Dart SDK (agente)
#############################################
ensure_node20() {
  if command -v node &>/dev/null; then
    local major
    major=$(node -v | sed 's/^v//' | cut -d. -f1)
    if [ "$major" -ge 20 ] 2>/dev/null; then
      info "Node.js $(node -v) ja instalado, pulando."
      return 0
    fi
  fi
  info "Instalando Node.js 20 LTS via NodeSource..."
  case "$PKG_FAMILY" in
    debian)
      retry 3 5 bash -c 'curl -fsSL https://deb.nodesource.com/setup_20.x | bash -'
      apt_install nodejs
      ;;
    rhel)
      retry 3 5 bash -c 'curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -'
      pkg_install nodejs
      ;;
  esac
}

ensure_dart() {
  if command -v dart &>/dev/null; then
    info "Dart SDK ja instalado, pulando."
    return 0
  fi
  info "Instalando Dart SDK (SDK standalone do Google, mesmo metodo para qualquer distro Linux)..."
  case "$PKG_FAMILY" in
    debian) apt_install unzip ca-certificates curl ;;
    rhel)   pkg_install unzip ca-certificates curl ;;
  esac

  local dart_zip="/tmp/dart-sdk.zip"
  local dart_url="https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-x64-release.zip"
  retry 3 5 curl -fsSL "$dart_url" -o "$dart_zip"
  rm -rf /opt/dart-sdk
  unzip -q "$dart_zip" -d /opt
  rm -f "$dart_zip"
  ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
  ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true

  command -v dart &>/dev/null || die "Falha ao instalar o Dart SDK."
}

#############################################
# Git clone/checkout idempotente
#############################################
clone_or_checkout() {
  local url=$1 dest=$2 tag=$3
  if [ -d "$dest/.git" ]; then
    info "Repositorio ja existe em $dest, atualizando para a tag $tag..."
    # Executado como o usuario "$OCS_SYS_USER" (dono do diretorio), e nao
    # como root, para nao acionar a protecao "dubious ownership" do git
    # (o git se recusa a operar num repositorio cujo dono difere do EUID
    # de quem o esta chamando). git -C evita precisar de subshell com cd.
    sudo -u "$OCS_SYS_USER" git -C "$dest" fetch --tags --force
    sudo -u "$OCS_SYS_USER" git -C "$dest" checkout "$tag" --force
  else
    info "Clonando $url (tag $tag) em $dest..."
    rm -rf "$dest"
    retry 3 5 sudo -u "$OCS_SYS_USER" git clone --branch "$tag" --depth 1 "$url" "$dest"
  fi
  chown -R "$OCS_SYS_USER":"$OCS_SYS_USER" "$dest"
}

#############################################
# PostgreSQL
#############################################
setup_postgres() {
  case "$PKG_FAMILY" in
    debian)
      apt_install postgresql postgresql-contrib
      ;;
    rhel)
      pkg_install postgresql-server postgresql-contrib
      if [ ! -f /var/lib/pgsql/data/PG_VERSION ]; then
        info "Inicializando o cluster do PostgreSQL (postgresql-setup --initdb)..."
        postgresql-setup --initdb
      fi
      ;;
  esac

  systemctl enable --now postgresql
  wait_for_active postgresql 30 || die "PostgreSQL nao iniciou a tempo."

  ensure_pg_hba_password_auth

  local role_exists db_exists
  role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || true)
  if [ "$role_exists" = "1" ]; then
    info "Role '${DB_USER}' ja existe no PostgreSQL, atualizando senha."
    sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  else
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  fi

  db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || true)
  if [ "$db_exists" != "1" ]; then
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
  else
    info "Banco '${DB_NAME}' ja existe."
  fi
}

# O caminho do pg_hba.conf muda de distro para distro (Debian:
# /etc/postgresql/<versao>/main/pg_hba.conf ; RHEL: /var/lib/pgsql/data/pg_hba.conf).
# Em vez de tentar adivinhar o caminho, perguntamos ao proprio PostgreSQL.
ensure_pg_hba_password_auth() {
  local hba marker="# ocsinventory-installer: regra de autenticacao por senha (tem prioridade sobre regras padrao da distro, ex.: 'ident' no RHEL)"
  hba=$(sudo -u postgres psql -tAc "SHOW hba_file;" 2>/dev/null | xargs) || true
  if [ -z "$hba" ] || [ ! -f "$hba" ]; then
    warn "Nao foi possivel localizar o pg_hba.conf automaticamente; se a conexao do backend falhar por autenticacao, ajuste-o manualmente."
    return 0
  fi

  if grep -qF "$marker" "$hba"; then
    info "$hba ja foi ajustado anteriormente pelo instalador, pulando."
    return 0
  fi

  # Nao basta checar se ja existe uma linha "host all all 127.0.0.1/32":
  # o pg_hba.conf padrao do RHEL/AlmaLinux (gerado por postgresql-setup
  # --initdb) ja inclui essa linha, mas com o metodo "ident", que rejeita
  # senha. Por isso as regras abaixo sao sempre inseridas no TOPO do
  # arquivo (onde tem prioridade sobre qualquer regra ja existente, ja
  # que o pg_hba.conf usa "primeira regra que casar, ganha"), e a
  # idempotencia e garantida pelo marcador, nao pela presenca da linha.
  info "Ajustando $hba para permitir autenticacao por senha em 127.0.0.1/::1 (tera prioridade sobre as regras padrao da distro)..."
  local orig_owner orig_mode
  orig_owner=$(stat -c '%U:%G' "$hba")
  orig_mode=$(stat -c '%a' "$hba")
  cp "$hba" "${hba}.bak.$(date +%s)"
  {
    echo "$marker"
    echo "host    all             all             127.0.0.1/32            scram-sha-256"
    echo "host    all             all             ::1/128                 scram-sha-256"
    cat "$hba"
  } > "${hba}.new"
  mv "${hba}.new" "$hba"
  chown "$orig_owner" "$hba"
  chmod "$orig_mode" "$hba"
  systemctl reload postgresql 2>/dev/null || systemctl restart postgresql
}

#############################################
# Backend (Django REST API)
#############################################
install_backend() {
  ensure_python312
  case "$PKG_FAMILY" in
    debian) apt_install libldap2-dev libsasl2-dev libssl-dev build-essential ;;
    rhel)   pkg_install openldap-devel cyrus-sasl-devel openssl-devel gcc gcc-c++ make ;;
  esac
  clone_or_checkout "$GIT_BACKEND_URL" "$BASE_DIR/backend" "$OCS_TAG"

  if [ ! -d "$BASE_DIR/backend/venv" ]; then
    sudo -u "$OCS_SYS_USER" "$PYTHON_BIN" -m venv "$BASE_DIR/backend/venv"
  fi
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install --upgrade pip
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install -r "$BASE_DIR/backend/requirements.txt"
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install -r "$BASE_DIR/backend/requirements_psql.txt"
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install uwsgi
}

configure_backend_env() {
  local env_file="$BASE_DIR/backend/.env"
  if [ ! -f "$env_file" ]; then
    cp "$BASE_DIR/backend/.env-sample" "$env_file"
  fi
  local secret
  secret=$(sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/python" -c "import secrets;print(secrets.token_urlsafe(50))")

  sed -i "s|^SECRET_KEY=.*|SECRET_KEY='${secret}'|" "$env_file"
  sed -i "s|^DEBUG=.*|DEBUG=False|" "$env_file"
  sed -i "s|^FRONTEND_REDIRECT=.*|FRONTEND_REDIRECT='http://${SERVER_HOST}:${FRONTEND_PORT}'|" "$env_file"
  sed -i "s|^DB_ENGINE=.*|DB_ENGINE='django.db.backends.postgresql'|" "$env_file"
  sed -i "s|^DB_NAME=.*|DB_NAME='${DB_NAME}'|" "$env_file"
  sed -i "s|^DB_USER=.*|DB_USER='${DB_USER}'|" "$env_file"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD='${DB_PASSWORD}'|" "$env_file"
  sed -i "s|^DB_HOST=.*|DB_HOST='localhost'|" "$env_file"
  sed -i "s|^DB_PORT=.*|DB_PORT='5432'|" "$env_file"

  chown "$OCS_SYS_USER":"$OCS_SYS_USER" "$env_file"
  chmod 600 "$env_file"
}

backend_migrate_and_static() {
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/python" "$BASE_DIR/backend/manage.py" migrate
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/python" "$BASE_DIR/backend/manage.py" collectstatic --noinput
}

backend_create_superuser() {
  sudo -u "$OCS_SYS_USER" env \
    DJANGO_SUPERUSER_USERNAME="$ADMIN_USER" \
    DJANGO_SUPERUSER_EMAIL="$ADMIN_EMAIL" \
    DJANGO_SUPERUSER_PASSWORD="$ADMIN_PASSWORD" \
    "$BASE_DIR/backend/venv/bin/python" "$BASE_DIR/backend/manage.py" shell -c "
from django.contrib.auth.models import User
import os
username = os.environ['DJANGO_SUPERUSER_USERNAME']
email = os.environ['DJANGO_SUPERUSER_EMAIL']
password = os.environ['DJANGO_SUPERUSER_PASSWORD']
u, created = User.objects.get_or_create(username=username, defaults={'email': email})
u.email = email
u.is_superuser = True
u.is_staff = True
u.set_password(password)
u.save()
print('Superusuario criado.' if created else 'Superusuario atualizado.')
"
}

backend_setup_uwsgi_and_nginx() {
  check_port_free_or_nginx "$BACKEND_PORT"
  mkdir -p /var/log/ocsinventory-backend /run/ocsinventory-backend
  chown "$OCS_SYS_USER":"$OCS_SYS_USER" /var/log/ocsinventory-backend /run/ocsinventory-backend

  cat > "$BASE_DIR/backend/uwsgi.ini" <<EOF
[uwsgi]
uid = $OCS_SYS_USER
gid = $OCS_SYS_USER
project = ocsinventory_backend
base = $BASE_DIR/backend
chdir = $BASE_DIR/backend
virtualenv = $BASE_DIR/backend/venv
module = ocsinventory_backend.wsgi:application
master = true
processes = 5
socket = /run/ocsinventory-backend/ocsinventory-backend.sock
chmod-socket = 666
vacuum = true
logto = /var/log/ocsinventory-backend/ocsinventory-backend.log
EOF
  chown "$OCS_SYS_USER":"$OCS_SYS_USER" "$BASE_DIR/backend/uwsgi.ini"

  cat > /etc/systemd/system/ocsinventory-backend.service <<EOF
[Unit]
Description=OCS Inventory Backend (uWSGI)
After=network.target postgresql.service

[Service]
User=$OCS_SYS_USER
Group=$OCS_SYS_USER
RuntimeDirectory=ocsinventory-backend
WorkingDirectory=$BASE_DIR/backend
ExecStart=$BASE_DIR/backend/venv/bin/uwsgi --ini $BASE_DIR/backend/uwsgi.ini
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now ocsinventory-backend
  if ! wait_for_active ocsinventory-backend 30; then
    journalctl -u ocsinventory-backend -n 50 --no-pager || true
    die "O servico ocsinventory-backend (uWSGI) nao iniciou."
  fi

  local vhost_file
  case "$PKG_FAMILY" in
    debian)
      disable_default_nginx_site_if_needed "$BACKEND_PORT"
      vhost_file="/etc/nginx/sites-available/ocsinventory-backend"
      ;;
    rhel)
      vhost_file="/etc/nginx/conf.d/ocsinventory-backend.conf"
      if [ "$BACKEND_PORT" = "80" ]; then
        warn "Na familia RHEL a porta 80 pode conflitar com o server block padrao embutido em /etc/nginx/nginx.conf; edite-o manualmente se o Nginx nao subir."
      fi
      ;;
  esac

  cat > "$vhost_file" <<EOF
server {
    listen ${BACKEND_PORT};
    server_name _;
    server_tokens off;

    location = /favicon.ico { access_log off; log_not_found off; }

    location /static/ {
        alias $BASE_DIR/backend/static/;
    }

    location / {
        include         uwsgi_params;
        uwsgi_pass      unix:/run/ocsinventory-backend/ocsinventory-backend.sock;
        uwsgi_param     UWSGI_SCHEME \$scheme;
        uwsgi_param     SERVER_SOFTWARE nginx/\$nginx_version;
        uwsgi_param     HTTP_HOST \$host;
        uwsgi_param     REQUEST_URI \$request_uri;
        uwsgi_param     DOCUMENT_ROOT \$document_root;
    }
}
EOF

  if [ "$PKG_FAMILY" = "debian" ]; then
    ln -sf "$vhost_file" /etc/nginx/sites-enabled/ocsinventory-backend
  fi

  if [ "$PKG_FAMILY" = "rhel" ]; then
    selinux_allow_http_port "$BACKEND_PORT"
    selinux_label_path "/run/ocsinventory-backend" httpd_var_run_t
    selinux_label_path "$BASE_DIR/backend/static" httpd_sys_content_t
  fi

  nginx -t || die "Configuracao do Nginx para o backend esta invalida."
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  if ! wait_for_http "http://127.0.0.1:${BACKEND_PORT}/api-check/" 30; then
    warn "Backend nao respondeu em /api-check/ dentro do tempo esperado (pode estar apenas lento; verifique depois)."
  fi
}

backend_setup_automation_timer() {
  cat > /etc/systemd/system/ocsinventory-automation.service <<EOF
[Unit]
Description=OCS Inventory - execucao de regras de automacao
After=ocsinventory-backend.service

[Service]
Type=oneshot
User=$OCS_SYS_USER
WorkingDirectory=$BASE_DIR/backend
ExecStart=$BASE_DIR/backend/venv/bin/python manage.py automation
EOF

  cat > /etc/systemd/system/ocsinventory-automation.timer <<EOF
[Unit]
Description=Dispara as regras de automacao do OCS Inventory periodicamente

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ocsinventory-automation.timer
}

#############################################
# Frontend (Vue 3 / Vite)
#############################################
install_frontend() {
  ensure_node20
  clone_or_checkout "$GIT_FRONTEND_URL" "$BASE_DIR/frontend" "$OCS_TAG"
  (cd "$BASE_DIR/frontend" && sudo -u "$OCS_SYS_USER" npm install)
}

frontend_configure_and_build() {
  mkdir -p "$BASE_DIR/frontend/public/config"
  cat > "$BASE_DIR/frontend/public/config/config.json" <<EOF
{
  "BACKEND_API_ROUTE": "http://${SERVER_HOST}:${BACKEND_PORT}/"
}
EOF
  chown -R "$OCS_SYS_USER":"$OCS_SYS_USER" "$BASE_DIR/frontend/public/config"
  (cd "$BASE_DIR/frontend" && sudo -u "$OCS_SYS_USER" npm run build)
}

frontend_setup_nginx() {
  check_port_free_or_nginx "$FRONTEND_PORT"
  mkdir -p /var/log/ocsinventory-frontend

  local vhost_file
  case "$PKG_FAMILY" in
    debian)
      disable_default_nginx_site_if_needed "$FRONTEND_PORT"
      vhost_file="/etc/nginx/sites-available/ocsinventory-frontend"
      ;;
    rhel)
      vhost_file="/etc/nginx/conf.d/ocsinventory-frontend.conf"
      if [ "$FRONTEND_PORT" = "80" ]; then
        warn "Na familia RHEL a porta 80 pode conflitar com o server block padrao embutido em /etc/nginx/nginx.conf; edite-o manualmente se o Nginx nao subir."
      fi
      ;;
  esac

  cat > "$vhost_file" <<EOF
server {
    listen ${FRONTEND_PORT};
    server_name _;

    root $BASE_DIR/frontend/dist;
    index index.html;

    access_log /var/log/ocsinventory-frontend/access.log;
    error_log  /var/log/ocsinventory-frontend/error.log;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF

  if [ "$PKG_FAMILY" = "debian" ]; then
    ln -sf "$vhost_file" /etc/nginx/sites-enabled/ocsinventory-frontend
  fi

  if [ "$PKG_FAMILY" = "rhel" ]; then
    selinux_allow_http_port "$FRONTEND_PORT"
    selinux_label_path "$BASE_DIR/frontend/dist" httpd_sys_content_t
  fi

  nginx -t || die "Configuracao do Nginx para o frontend esta invalida."
  systemctl reload nginx 2>/dev/null || systemctl restart nginx

  if ! wait_for_http "http://127.0.0.1:${FRONTEND_PORT}/" 30; then
    warn "Frontend nao respondeu dentro do tempo esperado (pode estar apenas lento; verifique depois)."
  fi
}

#############################################
# SNMP Scanner
#############################################
install_and_configure_snmp() {
  if [ "$SKIP_SNMP" -eq 1 ]; then
    info "SNMP Scanner ignorado (--skip-snmp)."
    return 0
  fi

  clone_or_checkout "$GIT_SNMP_URL" "$BASE_DIR/snmp-scanner" "$OCS_TAG"

  if [ ! -d "$BASE_DIR/snmp-scanner/venv" ]; then
    sudo -u "$OCS_SYS_USER" "$PYTHON_BIN" -m venv "$BASE_DIR/snmp-scanner/venv"
  fi
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/snmp-scanner/venv/bin/pip" install --upgrade pip
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/snmp-scanner/venv/bin/pip" install -r "$BASE_DIR/snmp-scanner/requirements.txt"

  local subnet="${SNMP_SUBNET:-$(detect_subnet)}"
  mkdir -p "$BASE_DIR/snmp-scanner/mibs"

  cat > "$BASE_DIR/snmp-scanner/config/scanner.conf" <<EOF
[auth]
ocs_user = ${ADMIN_USER}
ocs_password = ${ADMIN_PASSWORD}

[api]
ocs_base_url = http://127.0.0.1:${BACKEND_PORT}

[scanner]
scanner_mode = ONLINE
local_inventory_dir = files
targeted_subnets = ${subnet}
log_level = INFO
name = scanner-lab-01
mibs_dir = ${BASE_DIR}/snmp-scanner/mibs
server_logging_enabled = true
server_log_level = INFO
EOF
  chown -R "$OCS_SYS_USER":"$OCS_SYS_USER" "$BASE_DIR/snmp-scanner"

  cat > /etc/systemd/system/ocsinventory-snmp-scanner.service <<EOF
[Unit]
Description=OCS Inventory SNMP Scanner
After=ocsinventory-backend.service

[Service]
Type=oneshot
User=$OCS_SYS_USER
WorkingDirectory=$BASE_DIR/snmp-scanner
ExecStart=$BASE_DIR/snmp-scanner/venv/bin/python SnmpScanner.py
EOF

  cat > /etc/systemd/system/ocsinventory-snmp-scanner.timer <<EOF
[Unit]
Description=Executa o SNMP Scanner periodicamente

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now ocsinventory-snmp-scanner.timer

  info "Subnet configurada para o SNMP Scanner: ${subnet}"
  info "IMPORTANTE: associe uma configuracao/comunidade SNMP ao scanner 'scanner-lab-01' no console (Configuracao > SNMP) -- sem isso ele nao varre nenhum dispositivo."
}

#############################################
# Agente unificado (Dart) -- instalado no proprio servidor de teste
#############################################
install_agent() {
  if [ "$SKIP_AGENT" -eq 1 ]; then
    info "Agente local ignorado (--skip-agent)."
    return 0
  fi

  ensure_dart

  local agent_src="$BASE_DIR/agent-src"
  clone_or_checkout "$GIT_AGENT_URL" "$agent_src" "$OCS_TAG"

  (cd "$agent_src" && dart pub get && dart compile exe lib/app/app.dart -o ocsinventory-cli)
  cp "$agent_src/ocsinventory-cli" "$agent_src/setup/linux/"
  chmod +x "$agent_src/setup/linux/install.sh" "$agent_src/setup/linux/uninstall.sh"

  (cd "$agent_src/setup/linux" && ./install.sh \
      --silent \
      --url "http://${SERVER_HOST}:${BACKEND_PORT}" \
      --username "$ADMIN_USER" \
      --password "$ADMIN_PASSWORD" \
      --mode 1 \
      --log-level 3 \
      --service \
      --now)
}

#############################################
# Validacao final / resumo
#############################################
validate_install() {
  if curl -fsS "http://127.0.0.1:${BACKEND_PORT}/api-check/" >/dev/null 2>&1; then
    info "Backend respondendo em /api-check/."
  else
    warn "Backend nao respondeu ao check final em /api-check/."
  fi

  if curl -fsS "http://127.0.0.1:${FRONTEND_PORT}/" >/dev/null 2>&1; then
    info "Frontend respondendo."
  else
    warn "Frontend nao respondeu ao check final."
  fi
}

print_summary() {
  {
    echo "==================================================================="
    echo " OCS Inventory 3.0 (${OCS_TAG}) -- resumo da instalacao"
    echo "==================================================================="
    echo "Console web ......: http://${SERVER_HOST}:${FRONTEND_PORT}"
    echo "API backend ......: http://${SERVER_HOST}:${BACKEND_PORT}"
    echo "Usuario admin ....: ${ADMIN_USER}"
    echo "Senha admin ......: ${ADMIN_PASSWORD}"
    echo "Banco (Postgres) .: ${DB_NAME} / usuario ${DB_USER}"
    echo "Senha do banco ...: ${DB_PASSWORD}"
    echo
    echo "Etapas executadas:"
    for k in "${STEP_ORDER[@]}"; do
      echo "  - ${k}: ${STEP_STATUS[$k]}"
    done
    echo
    echo "Logs:"
    echo "  Instalacao .......: $LOG_FILE"
    echo "  Backend (uwsgi) ..: /var/log/ocsinventory-backend/"
    echo "  Frontend (nginx) .: /var/log/ocsinventory-frontend/"
    echo "  Agente ...........: /var/log/ocsinventory-agent/ (se instalado)"
    echo "==================================================================="
  } | tee "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  warn "As credenciais acima tambem foram salvas em $CRED_FILE (permissao 600). Troque a senha do admin apos validar a instalacao."
}

#############################################
# CLI
#############################################
usage() {
  cat <<EOF
Uso: sudo $0 [opcoes]

Opcoes:
  --host HOST_OU_IP        Endereco usado nas URLs do console/agente (auto-detectado se omitido)
  --backend-port PORTA     Porta do backend/API (padrao: 8000)
  --frontend-port PORTA    Porta do console web (padrao: 8080)
  --db-password SENHA      Senha do banco (gerada aleatoriamente se omitida)
  --admin-user USUARIO     Usuario administrador do console (padrao: admin)
  --admin-email EMAIL      E-mail do administrador (padrao: admin@localhost)
  --admin-password SENHA   Senha do administrador (gerada aleatoriamente se omitida)
  --snmp-subnet CIDR       Subnet a ser varrida pelo SNMP Scanner (auto-detectada se omitida)
  --base-dir CAMINHO       Diretorio de instalacao (padrao: /opt/ocsinventory)
  --ocs-tag TAG            Tag git a instalar (padrao: 3.0.0-rc1)
  --skip-snmp              Nao instalar o SNMP Scanner
  --skip-agent              Nao instalar o agente local neste servidor
  -y, --yes                 Nao perguntar confirmacao antes de iniciar
  -h, --help                 Mostra esta ajuda
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) SERVER_HOST="$2"; shift 2 ;;
      --backend-port) BACKEND_PORT="$2"; shift 2 ;;
      --frontend-port) FRONTEND_PORT="$2"; shift 2 ;;
      --db-password) DB_PASSWORD="$2"; shift 2 ;;
      --admin-user) ADMIN_USER="$2"; shift 2 ;;
      --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
      --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
      --snmp-subnet) SNMP_SUBNET="$2"; shift 2 ;;
      --base-dir) BASE_DIR="$2"; shift 2 ;;
      --ocs-tag) OCS_TAG="$2"; shift 2 ;;
      --skip-snmp) SKIP_SNMP=1; shift ;;
      --skip-agent) SKIP_AGENT=1; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opcao desconhecida: $1 (use --help)" ;;
    esac
  done
}

confirm_or_die() {
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    return 0
  fi
  cat <<EOF

Este script vai, neste servidor:
  - instalar PostgreSQL, Nginx, Python 3.12, Node.js 20 e (opcionalmente) o Dart SDK
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - criar o banco '$DB_NAME' no PostgreSQL local
  - abrir as portas ${BACKEND_PORT} e ${FRONTEND_PORT} no firewall (ufw ou firewalld, conforme a distro)
  - instalar e habilitar os servicos systemd do OCS Inventory 3.0 ($OCS_TAG)

Host/IP que sera usado nas URLs: ${SERVER_HOST}

EOF
  read -r -p "Continuar? [s/N] " resp
  case "$resp" in
    s|S|sim|y|Y|yes) return 0 ;;
    *) die "Instalacao cancelada pelo usuario." ;;
  esac
}

banner() {
  cat <<'EOF'
=====================================================
  OCS Inventory 3.0 - instalador para servidor unico
=====================================================
EOF
}

#############################################
# Main
#############################################
main() {
  need_root
  parse_args "$@"

  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1

  banner
  detect_os

  if [ -z "$SERVER_HOST" ]; then
    SERVER_HOST=$(detect_ip)
  fi
  if [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(gen_password 24)
  fi
  if [ -z "$ADMIN_PASSWORD" ]; then
    ADMIN_PASSWORD=$(gen_password 20)
  fi

  confirm_or_die

  run_required "Pacotes base do sistema"        install_base_packages
  run_required "Usuario de sistema '$OCS_SYS_USER'" create_system_user
  run_required "Firewall (ufw/firewalld)"        setup_firewall
  run_required "PostgreSQL"                     setup_postgres

  run_required "Backend - codigo e dependencias"     install_backend
  run_required "Backend - configuracao (.env)"       configure_backend_env
  run_required "Backend - migracoes e estaticos"     backend_migrate_and_static
  run_required "Backend - superusuario"              backend_create_superuser
  run_required "Backend - uWSGI + Nginx"             backend_setup_uwsgi_and_nginx
  run_required "Backend - timer de automacao"        backend_setup_automation_timer

  run_required "Frontend - codigo e dependencias" install_frontend
  run_required "Frontend - build"                 frontend_configure_and_build
  run_required "Frontend - Nginx"                 frontend_setup_nginx

  run_optional "SNMP Scanner"          install_and_configure_snmp
  run_optional "Agente local (Dart)"   install_agent

  validate_install
  print_summary
}

main "$@"
