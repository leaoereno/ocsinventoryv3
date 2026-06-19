#!/usr/bin/env bash
#
# install-ocsinventory-3.0.sh
#
# Instalacao do OCS Inventory 3.0 (tag 3.0.0-rc1) com suporte a
# arquitetura multi-layer: cada componente pode ser instalado em um
# servidor dedicado, ou combinado da forma que fizer sentido.
#
# PAPEIS DISPONIVEIS (--role):
#
#   standalone   Tudo em um servidor (laboratorio/teste)
#   db           Banco de dados (MySQL/MariaDB ou PostgreSQL)
#   backend      API Django + uWSGI (conecta a --db-host remoto)
#   frontend     Console web Vue.js/Nginx (conecta a --backend-host remoto)
#   snmp         SNMP Discovery Scanner (conecta a --backend-host remoto)
#   app          Backend + Frontend no mesmo servidor (atalho para [2]+[3])
#   db-remote    Prepara o banco em OUTRO servidor via SSH
#
# EXEMPLO DE ARQUITETURA 4 CAMADAS:
#   Servidor A: --role db
#   Servidor B: --role backend  --db-host A
#   Servidor C: --role frontend --backend-host B
#   Servidor D: --role snmp     --backend-host B
#   (o agente e instalado automaticamente em todos os servidores)
#
# Suporta Debian (Ubuntu 22/24, Debian 12/13) e RHEL (AlmaLinux, Rocky,
# RHEL 8/9/10, Fedora) com deteccao automatica de familia de pacotes.
#
# Uso:
#   sudo ./install-ocsinventory-3.0.sh [--role PAPEL] [opcoes]
#   sudo ./install-ocsinventory-3.0.sh --help

set -Eeuo pipefail

#############################################
# Configuracao padrao (sobrescrevivel via flags)
#############################################
OCS_TAG="3.0.0-rc1"
BASE_DIR="/opt/ocsinventory"
OCS_SYS_USER="ocs"

BACKEND_PORT="8000"
FRONTEND_PORT="8080"

# Papel deste servidor na arquitetura
ROLE=""

# Motor de banco de dados
DB_ENGINE_CHOICE=""
MARIADB_MIN_VERSION="10.6"
MYSQL_MIN_VERSION="8.0"
POSTGRES_MIN_VERSION="14"

# Conexao com o banco de dados
DB_HOST=""
DB_PORT=""
DB_NAME="ocsdb"
DB_USER="ocsuser"
DB_PASSWORD=""
DB_ROOT_PASSWORD=""   # transitorio, nunca salvo
DB_FRESH_INSTALL=0

# Hosts dos outros componentes (usados em arquitetura multi-layer)
BACKEND_HOST=""       # host do backend, usado por --role frontend e --role snmp
APP_SERVER_HOST=""    # host do app server, usado por --role db para GRANT/firewall

# SSH para --role db-remote
REMOTE_DB_HOST=""
REMOTE_DB_SSH_USER=""
REMOTE_DB_SSH_PORT=""
REMOTE_DB_SSH_KEY=""

# Credenciais do superusuario do console
ADMIN_USER="admin"
ADMIN_EMAIL="admin@localhost"
ADMIN_PASSWORD=""

# IP deste servidor (selecionado interativamente se houver multiplas interfaces)
SERVER_HOST=""
SNMP_SUBNET=""

# Controle de componentes opcionais
SKIP_SNMP=-1
SKIP_AGENT=-1
ASSUME_YES=0
RUN_OS_UPGRADE=-1

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
PKG_FAMILY=""
PKG_MGR=""
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
# Perguntas interativas
#############################################
# Todas caem para o valor padrao (sem bloquear) quando nao ha terminal
# interativo (ex.: execucao via Ansible/CI) ou quando --yes foi usado.

ask_input() {
  local prompt=$1 default=${2:-} answer
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    echo "$default"
    return 0
  fi
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " answer
    echo "${answer:-$default}"
  else
    read -r -p "$prompt: " answer
    echo "$answer"
  fi
}

ask_secret() {
  local prompt=$1 default=${2:-} answer
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    echo "$default"
    return 0
  fi
  read -rs -p "$prompt: " answer
  echo >&2
  echo "${answer:-$default}"
}

# ask_yes_no "pergunta" "s"|"N"  -> retorna 0 (sim) ou 1 (nao)
ask_yes_no() {
  local prompt=$1 default=${2:-N} answer hint
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    [ "$default" = "s" ] && return 0 || return 1
  fi
  if [ "$default" = "s" ]; then hint="S/n"; else hint="s/N"; fi
  read -r -p "$prompt [$hint]: " answer
  answer="${answer:-$default}"
  case "$answer" in
    s|S|sim|Sim|SIM|y|Y|yes|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

# version_ge "1.2.3" "1.2"  -> 0 se a primeira for >= a segunda (compara
# so major.minor, suficiente para os checks de versao minima de banco).
version_ge() {
  local a=$1 b=$2 a_major a_minor b_major b_minor
  a_major=${a%%.*}; a_minor=${a#*.}; a_minor=${a_minor%%.*}
  b_major=${b%%.*}; b_minor=${b#*.}; b_minor=${b_minor%%.*}
  [[ "$a_major" =~ ^[0-9]+$ ]] || a_major=0
  [[ "$a_minor" =~ ^[0-9]+$ ]] || a_minor=0
  [[ "$b_major" =~ ^[0-9]+$ ]] || b_major=0
  [[ "$b_minor" =~ ^[0-9]+$ ]] || b_minor=0
  if [ "$a_major" -gt "$b_major" ]; then return 0; fi
  if [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -ge "$b_minor" ]; then return 0; fi
  return 1
}

# resolve_to_ip "lnxdcocsapp01"  -> resolve via DNS/hosts; se ja for um IP
# ou um wildcard ("%"), retorna como esta.
resolve_to_ip() {
  local input=$1 ip
  if [[ "$input" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || [ "$input" = "%" ]; then
    echo "$input"
    return 0
  fi
  ip=$(getent hosts "$input" 2>/dev/null | awk '{print $1}' | head -n1) || true
  if [ -n "$ip" ]; then
    echo "$ip"
  else
    echo "$input"
  fi
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
#
# Detecta e corrige automaticamente um problema real e relativamente comum
# em AlmaLinux/RHEL 8 (costuma aparecer apos restaurar snapshot/imagem, ou
# quando alguma ferramenta tocou o /var/lib/rpm com uma versao diferente do
# rpm/dnf): "RPM: error: db5 error(-30969) ... BDB0091 DB_VERSION_MISMATCH".
# Sem essa deteccao, as 3 tentativas de retry falham identicamente, porque
# nada corrige a causa raiz entre elas -- so reexecutar o mesmo comando nao
# resolve. A correcao documentada e remover os arquivos de ambiente/lock
# antigos do Berkeley DB em /var/lib/rpm; o proprio rpm os recria do zero
# no comando seguinte.
pkg_install() {
  local mgr_cmd="dnf"
  [ "$PKG_MGR" = "yum" ] && mgr_cmd="yum"
  local attempt=1 max=3 delay=5 tmp_out
  tmp_out=$(mktemp)
  while true; do
    if "$mgr_cmd" install -y "$@" 2>&1 | tee "$tmp_out"; then
      rm -f "$tmp_out"
      return 0
    fi
    if grep -qE "DB_VERSION_MISMATCH|cannot open Packages database" "$tmp_out"; then
      warn "Banco de dados do RPM corrompido detectado (BDB0091 DB_VERSION_MISMATCH); removendo /var/lib/rpm/__db* e tentando novamente..."
      rm -f /var/lib/rpm/__db* 2>/dev/null || true
    fi
    if [ "$attempt" -ge "$max" ]; then
      rm -f "$tmp_out"
      return 1
    fi
    warn "Comando falhou (tentativa $attempt/$max), tentando novamente em ${delay}s: $mgr_cmd install -y $*"
    sleep "$delay"
    attempt=$((attempt + 1))
  done
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

# Lista todas as interfaces IPv4 do servidor (exceto loopback e docker/virbr)
# e deixa o usuario escolher qual usar para comunicacao com os outros
# componentes. Se houver so uma, usa ela automaticamente. Se SERVER_HOST
# ja estiver definido via --host, respeita e nao pergunta.
pick_server_ip() {
  [ -n "$SERVER_HOST" ] && return 0

  local ips=() ifaces=() line
  while IFS= read -r line; do
    local ip iface
    ip=$(echo "$line" | awk '{print $4}' | cut -d/ -f1)
    iface=$(echo "$line" | awk '{print $2}')
    # Ignora loopback, docker, virbr, veth, lo
    case "$iface" in lo|docker*|virbr*|veth*|br-*) continue ;; esac
    ips+=("$ip")
    ifaces+=("$iface")
  done < <(ip -o -4 addr show scope global 2>/dev/null)

  if [ "${#ips[@]}" -eq 0 ]; then
    SERVER_HOST=$(detect_ip)
    info "IP detectado automaticamente: $SERVER_HOST"
    return 0
  fi

  if [ "${#ips[@]}" -eq 1 ]; then
    SERVER_HOST="${ips[0]}"
    info "IP detectado: $SERVER_HOST (${ifaces[0]})"
    return 0
  fi

  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    SERVER_HOST="${ips[0]}"
    info "Multiplos IPs detectados; usando o primeiro (${ips[0]}) automaticamente. Use --host para especificar outro."
    return 0
  fi

  cat <<EOF

Este servidor tem ${#ips[@]} interfaces de rede. Qual IP os outros
componentes devem usar para se conectar a ESTE servidor?
EOF
  local i
  for i in "${!ips[@]}"; do
    printf "  [%d] %-18s  (%s)\n" "$((i+1))" "${ips[$i]}" "${ifaces[$i]}"
  done
  local choice
  read -r -p "Escolha [1-${#ips[@]}]: " choice
  local idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#ips[@]}" ]; then
    die "Opcao invalida: $choice"
  fi
  SERVER_HOST="${ips[$idx]}"
  info "IP selecionado: $SERVER_HOST (${ifaces[$idx]})"
}

# Testa conectividade TCP com um host:porta antes de prosseguir.
# Evita descobrir problemas de rede/firewall so depois de horas de instalacao.
test_tcp_connectivity() {
  local host=$1 port=$2
  local label="${3:-${host}:${port}}"
  info "Testando conectividade TCP com ${label} (${host}:${port})..."
  if timeout 5 bash -c "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
    info "Conectividade TCP com ${label}: OK"
    return 0
  else
    die "Nao foi possivel conectar em ${host}:${port} (${label}). Verifique:
  - Se o servico esta rodando no servidor remoto
  - Se a porta esta aberta no firewall do servidor remoto
  - Se nao ha bloqueio de rede/microsegmentacao (Guardicore, NSX, ACL) entre os servidores
  Teste manual: timeout 5 bash -c 'echo > /dev/tcp/${host}/${port}' && echo OK"
  fi
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
      # Nota: software-properties-common foi removido do Debian 13/trixie
      # (sem previsao de retorno) e por isso NAO entra aqui -- ele so e
      # necessario no ramo especifico do Ubuntu (deadsnakes PPA), onde e
      # instalado separadamente dentro de ensure_python312().
      # sudo: instalacoes minimas do Debian (netinst sem tasksel padrao,
      # imagens de container/cloud) frequentemente NAO o incluem por
      # padrao -- e o script inteiro depende de "sudo -u" para rodar
      # comandos como o usuario "ocs" e como "postgres".
      apt_install sudo curl wget ca-certificates gnupg lsb-release psmisc iproute2
      if [ "$ROLE" != "db" ]; then
        apt_install build-essential git unzip python3 nginx ufw
      else
        apt_install ufw
      fi
      ;;
    rhel)
      pkg_install epel-release || warn "Nao foi possivel instalar epel-release (normal em Fedora, que ja inclui tudo); seguindo."
      pkg_install dnf-plugins-core || true
      pkg_install sudo curl wget ca-certificates gnupg2 psmisc iproute
      if [ "$ROLE" != "db" ]; then
        pkg_install gcc gcc-c++ make git unzip python3 nginx firewalld
        pkg_install policycoreutils-python-utils || \
          warn "Nao foi possivel instalar policycoreutils-python-utils (semanage); se o SELinux estiver enforcing, os ajustes automaticos de contexto serao pulados."
      else
        pkg_install firewalld
      fi
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

# Pergunta antes de atualizar o sistema operacional -- numa producao isso
# pode reiniciar/atualizar servicos ja existentes no servidor (ex.: o
# proprio MariaDB no servidor de banco), entao o padrao e NAO atualizar
# sem confirmacao explicita.
maybe_run_os_upgrade() {
  if [ "$RUN_OS_UPGRADE" -eq 0 ]; then
    info "Atualizacao do sistema operacional pulada (--no-os-upgrade)."
    return 0
  fi
  if [ "$RUN_OS_UPGRADE" -eq -1 ]; then
    if ! ask_yes_no "Atualizar os pacotes do sistema operacional agora (dnf/apt upgrade)? Pode reiniciar/atualizar servicos ja existentes neste servidor." "N"; then
      info "Atualizacao do sistema operacional pulada (escolha do usuario)."
      return 0
    fi
  fi
  info "Atualizando pacotes do sistema operacional..."
  case "$PKG_FAMILY" in
    debian)
      apt_wait_lock
      retry 3 5 apt-get update -y
      retry 3 5 env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
      ;;
    rhel)
      retry 3 5 "$PKG_MGR" -y upgrade
      ;;
  esac
}

setup_firewall() {
  if [ "$ROLE" = "db" ]; then
    info "Papel 'db': portas 8000/8080 nao se aplicam aqui; a porta do banco e liberada na etapa de configuracao do banco."
    case "$PKG_FAMILY" in
      debian)
        command -v ufw &>/dev/null && { ufw allow OpenSSH >/dev/null 2>&1 || true; ufw status | grep -qi inactive && ufw --force enable || true; } || true
        ;;
      rhel)
        command -v firewall-cmd &>/dev/null && systemctl enable --now firewalld 2>/dev/null || true
        ;;
    esac
    return 0
  fi
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
  DB_HOST="localhost"
  DB_PORT="5432"
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
# Papel "db": prepara um banco JA EXISTENTE (ou instala um novo, se
# autorizado) para uso remoto pelo servidor de aplicacao. Roda
# LOCALMENTE no proprio servidor de banco de dados.
#############################################
setup_db_role() {
  if [ -z "$DB_ENGINE_CHOICE" ]; then
    decide_db_engine_for_role_db
  fi
  case "$DB_ENGINE_CHOICE" in
    mysql) setup_db_role_mysql ;;
    postgresql) setup_db_role_postgresql ;;
    *) die "Motor de banco de dados desconhecido: $DB_ENGINE_CHOICE" ;;
  esac
}

# Detecta o que JA esta instalado neste servidor. Se nada for encontrado,
# apresenta um menu com informacoes tecnicas detalhadas de cada opcao para
# que o usuario decida qual motor instalar -- ja na versao correta exigida
# pelo Django 6.0 (MariaDB 10.11 LTS ou PostgreSQL 15, dependendo da distro).
decide_db_engine_for_role_db() {
  local has_mysql=0 has_psql=0
  local mysql_version="" mysql_vendor="" psql_version=""
  local mysql_running=0 psql_running=0

  if command -v mysql &>/dev/null || command -v mariadb &>/dev/null; then
    has_mysql=1
    local raw
    if mysql -u root -e "SELECT 1;" &>/dev/null 2>&1; then
      raw=$(mysql -u root -N -e "SELECT VERSION();" 2>/dev/null || true)
    elif mariadb -u root -e "SELECT 1;" &>/dev/null 2>&1; then
      raw=$(mariadb -u root -N -e "SELECT VERSION();" 2>/dev/null || true)
    fi
    if [ -n "$raw" ]; then
      mysql_version=$(echo "$raw" | cut -d- -f1)
      echo "$raw" | grep -qi "mariadb" && mysql_vendor="MariaDB" || mysql_vendor="MySQL"
      mysql_running=1
    else
      mysql_vendor="MySQL/MariaDB"
      mysql_version="(nao foi possivel conectar sem senha)"
    fi
  fi

  if command -v psql &>/dev/null; then
    has_psql=1
    if sudo -u postgres psql -c "SELECT 1;" &>/dev/null 2>&1; then
      psql_version=$(sudo -u postgres psql -tAc "SHOW server_version;" 2>/dev/null | cut -d. -f1 || true)
      psql_running=1
    else
      psql_version="(cluster nao inicializado ou sem acesso)"
    fi
  fi

  # --------------------------------------------------------
  # Caso 1: ambos presentes -> menu de escolha qual usar
  # --------------------------------------------------------
  if [ "$has_mysql" -eq 1 ] && [ "$has_psql" -eq 1 ]; then
    if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
      DB_ENGINE_CHOICE="mysql"
      info "Dois motores detectados; sem terminal interativo, usando MySQL/MariaDB por padrao. Use --db-engine postgresql para o outro."
      return 0
    fi
    local mysql_compat="" psql_compat=""
    if [ "$mysql_running" -eq 1 ] && [ -n "$mysql_version" ]; then
      version_ge "$mysql_version" "$MARIADB_MIN_VERSION" \
        && mysql_compat="compativel com Django 6.0" \
        || mysql_compat="ABAIXO do minimo exigido pelo Django 6.0 (${MARIADB_MIN_VERSION}+ para MariaDB / ${MYSQL_MIN_VERSION}+ para MySQL)"
    fi
    if [ "$psql_running" -eq 1 ] && [ -n "$psql_version" ]; then
      version_ge "${psql_version}.0" "${POSTGRES_MIN_VERSION}.0" \
        && psql_compat="compativel com Django 6.0" \
        || psql_compat="ABAIXO do minimo exigido pelo Django 6.0 (${POSTGRES_MIN_VERSION}+)"
    fi
    cat <<EOF

Dois servidores de banco de dados foram encontrados neste servidor. Qual usar para o OCS Inventory?
  [1] ${mysql_vendor} ${mysql_version}  ${mysql_compat:+-- ${mysql_compat}}
  [2] PostgreSQL ${psql_version}  ${psql_compat:+-- ${psql_compat}}
EOF
    local choice
    read -r -p "Escolha [1/2]: " choice
    case "$choice" in
      1) DB_ENGINE_CHOICE="mysql" ;;
      2) DB_ENGINE_CHOICE="postgresql" ;;
      *) die "Opcao invalida." ;;
    esac
    return 0
  fi

  # --------------------------------------------------------
  # Caso 2: so um presente -> usa ele automaticamente
  # --------------------------------------------------------
  if [ "$has_mysql" -eq 1 ]; then
    info "${mysql_vendor} ${mysql_version} detectado neste servidor. Usando esse motor (use --db-engine postgresql para forcar o outro)."
    DB_ENGINE_CHOICE="mysql"
    return 0
  fi
  if [ "$has_psql" -eq 1 ]; then
    info "PostgreSQL ${psql_version} detectado neste servidor. Usando esse motor (use --db-engine mysql para forcar o outro)."
    DB_ENGINE_CHOICE="postgresql"
    return 0
  fi

  # --------------------------------------------------------
  # Caso 3: nenhum banco encontrado -> menu de instalacao
  # --------------------------------------------------------
  info "Nenhum servidor de banco de dados (MySQL/MariaDB ou PostgreSQL) encontrado neste servidor."
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    DB_ENGINE_CHOICE="mysql"
    info "Sem terminal interativo (ou --yes): instalando MariaDB 10.11 LTS por padrao. Use --db-engine postgresql para instalar o PostgreSQL."
    install_mariadb_compatible
    return 0
  fi

  # Prepara descricao especifica por distro para cada opcao
  local mysql_desc psql_desc
  case "$PKG_FAMILY" in
    rhel)
      case "${VERSION_ID:-0}" in
        8*) mysql_desc="MariaDB 10.11 LTS (via modulo DNF mariadb:10.11 -- substitui o 10.3 padrao do RHEL 8, sem reinstalacao necessaria)"
            psql_desc="PostgreSQL 15 (via modulo DNF postgresql:15 -- substitui o 10.x padrao do RHEL 8)"
            ;;
        9*) mysql_desc="MariaDB 10.11 LTS (do repositorio MariaDB.org, pois o RHEL 9 ainda nao traz o 10.11 no modulo padrao)"
            psql_desc="PostgreSQL 15 (do repositorio oficial do RHEL 9 / EPEL)"
            ;;
        10*) mysql_desc="MariaDB 10.11 LTS (do repositorio MariaDB.org)"
             psql_desc="PostgreSQL 16 (do repositorio oficial do RHEL 10 / EPEL)"
             ;;
        *) mysql_desc="MariaDB 10.11 LTS (do repositorio MariaDB.org)"
           psql_desc="PostgreSQL 15+ (via gerenciador de pacotes da distro)"
           ;;
      esac
      ;;
    debian)
      mysql_desc="MariaDB 10.11 LTS (do repositorio oficial dos pacotes Debian/Ubuntu)"
      psql_desc="PostgreSQL 15+ (do repositorio oficial dos pacotes Debian/Ubuntu)"
      ;;
    *) mysql_desc="MariaDB 10.11 LTS"
       psql_desc="PostgreSQL 15+"
       ;;
  esac

  cat <<EOF

Qual banco de dados instalar neste servidor para o OCS Inventory?

  Django 6.0 (backend do OCS 3.0) exige:
    - MariaDB 10.6 ou superior  (recomendado: 10.11 LTS)
    - MySQL 8.0.11 ou superior
    - PostgreSQL 14 ou superior  (recomendado: 15+)

  [1] MySQL/MariaDB -- ${mysql_desc}
  [2] PostgreSQL    -- ${psql_desc}
EOF
  local choice
  read -r -p "Escolha [1/2]: " choice
  case "$choice" in
    1) DB_ENGINE_CHOICE="mysql";       install_mariadb_compatible ;;
    2) DB_ENGINE_CHOICE="postgresql";  install_postgresql_compatible ;;
    *) die "Opcao invalida." ;;
  esac
}

# Instala o MariaDB numa versao >= 10.6 (minimo Django 6.0). A logica
# varia por distro porque o pacote padrao de algumas distros (especialmente
# RHEL/AlmaLinux 8) ainda e o 10.3 (EOL). Para essas, habilita o modulo
# de versao correta via DNF module switch antes de instalar.
install_mariadb_compatible() {
  info "Instalando MariaDB compativel com Django 6.0 (>= ${MARIADB_MIN_VERSION})..."
  case "$PKG_FAMILY" in
    debian)
      apt_install mariadb-server mariadb-client
      # Pacotes atuais do Debian 12/Ubuntu 22.04+ ja trazem 10.6+; Ubuntu
      # 20.04 pode trazer 10.3 -- nesse caso avisa mas prossegue (o check
      # de versao posterior em setup_db_role_mysql ira alertar).
      ;;
    rhel)
      case "${VERSION_ID:-0}" in
        8*)
          # RHEL/AlmaLinux 8 traz MariaDB 10.3 por padrao; precisamos do
          # modulo 10.11. Se o 10.3 estiver instalado, o DNF recusa instalar
          # 10.11 sem antes desabilitar o modulo antigo.
          info "AlmaLinux/RHEL 8 detectado: habilitando modulo DNF mariadb:10.11 (substitui o 10.3 padrao)..."
          dnf module reset mariadb -y 2>/dev/null || true
          dnf module enable mariadb:10.11 -y
          pkg_install mariadb-server mariadb
          ;;
        9*)
          # RHEL/AlmaLinux 9 traz MariaDB 10.5 -- abaixo do minimo 10.6.
          # O repositorio oficial do MariaDB.org e mais seguro para garantir
          # uma versao LTS recente.
          info "AlmaLinux/RHEL 9 detectado: adicionando repositorio oficial MariaDB.org para obter MariaDB 10.11 LTS..."
          if ! command -v curl &>/dev/null; then pkg_install curl; fi
          curl -fsSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | \
            bash -s -- --mariadb-server-version="mariadb-10.11"
          pkg_install MariaDB-server MariaDB-client
          ;;
        *)
          # RHEL 10+ e outros: tenta direto pelo gerenciador de pacotes;
          # o check de versao posterior avisara se nao for suficiente.
          pkg_install mariadb-server mariadb
          ;;
      esac
      ;;
  esac

  systemctl enable --now mariadb
  wait_for_active mariadb 30 || die "MariaDB nao iniciou a tempo apos a instalacao."
  info "MariaDB instalado e iniciado (datadir padrao: /var/lib/mysql)."
  warn "Recomendado rodar 'mariadb-secure-installation' (ou 'mysql_secure_installation') apos concluir."
  DB_FRESH_INSTALL=1
}

# Instala o PostgreSQL numa versao >= POSTGRES_MIN_VERSION. Em RHEL 8/9 o
# pacote padrao pode ser antigo (9.x/10.x); usa o modulo DNF para garantir
# a versao correta.
install_postgresql_compatible() {
  info "Instalando PostgreSQL compativel com Django 6.0 (>= ${POSTGRES_MIN_VERSION})..."
  case "$PKG_FAMILY" in
    debian)
      apt_install postgresql postgresql-contrib
      ;;
    rhel)
      case "${VERSION_ID:-0}" in
        8*)
          info "AlmaLinux/RHEL 8 detectado: habilitando modulo DNF postgresql:15..."
          dnf module reset postgresql -y 2>/dev/null || true
          dnf module enable postgresql:15 -y
          pkg_install postgresql-server postgresql-contrib
          ;;
        9*|10*)
          pkg_install postgresql-server postgresql-contrib
          ;;
        *)
          pkg_install postgresql-server postgresql-contrib
          ;;
      esac
      ;;
  esac
  DB_FRESH_INSTALL=1
}

# Prepara o datadir padrao do PostgreSQL para receber um initdb novo,
# tratando o caso de ja existir conteudo que NAO e um cluster valido (sem
# PG_VERSION) -- ex.: sobra de uma tentativa anterior incompleta:
#   - Ignora "lost+found", criado automaticamente pelo mkfs em qualquer
#     filesystem ext4 recem-formatado -- nao e "sujeira" real.
#   - Se o caminho for um PONTO DE MONTAGEM, nao da pra renomear o
#     diretorio em si ("mv" falha com "Device or resource busy") -- nesse
#     caso move so o CONTEUDO para uma subpasta de backup dentro do
#     proprio mountpoint. Caso contrario, move o diretorio inteiro de lado.
prepare_pg_datadir_for_initdb() {
  local datadir=$1
  [ -d "$datadir" ] || return 0
  [ -f "${datadir}/PG_VERSION" ] && return 0

  local real_content
  real_content=$(find "$datadir" -mindepth 1 -maxdepth 1 ! -name "lost+found" 2>/dev/null)
  [ -z "$real_content" ] && return 0

  if command -v mountpoint &>/dev/null && mountpoint -q "$datadir" 2>/dev/null; then
    local backup_subdir
    backup_subdir=".preinit-backup.$(date +%s)"
    warn "${datadir} e um ponto de montagem com conteudo que nao e um cluster valido -- movendo o conteudo para ${datadir}/${backup_subdir}/ antes de inicializar (o mountpoint em si nao pode ser renomeado)."
    mkdir -p "${datadir}/${backup_subdir}"
    find "$datadir" -mindepth 1 -maxdepth 1 ! -name "lost+found" ! -name "$backup_subdir" -exec mv -t "${datadir}/${backup_subdir}" {} +
  else
    local pg_backup_dir
    pg_backup_dir="${datadir}.bak.$(date +%s)"
    warn "${datadir} existe mas nao e um cluster valido (sem PG_VERSION) -- movendo para ${pg_backup_dir} antes de inicializar."
    mv "$datadir" "$pg_backup_dir"
  fi
}

# Garante que o cluster RHEL esta inicializado no caminho padrao
# (/var/lib/pgsql/data). Cobre tanto uma instalacao nova quanto um pacote
# que ja estava instalado antes desta execucao mas nunca chegou a ser
# inicializado -- idempotente (so age se realmente faltar inicializar).
#
# Nota: se existir um arquivo /etc/sysconfig/pgsql/postgresql com PGDATA
# apontando para outro caminho (ex.: sobra de tentativa anterior), o
# postgresql-setup o leria e ignoraria o padrao. Por isso, quando a
# intencao e usar o padrao, removemos esse arquivo antes do initdb.
ensure_postgresql_initdb_rhel() {
  local datadir="/var/lib/pgsql/data"

  if [ -f "${datadir}/PG_VERSION" ]; then
    return 0
  fi

  # O postgresql-setup descobre o PGDATA via "systemctl show -p Environment",
  # que reflete tanto o /etc/sysconfig/pgsql/postgresql quanto drop-ins
  # do systemd. Se qualquer um deles apontar para um caminho anterior (ex.:
  # /dbocs de uma tentativa com datadir customizado que foi abandonada),
  # o initdb vai la -- ignorando completamente o nosso PGDATA. Limpamos
  # ambos antes de rodar o initdb para garantir que usa o padrao.
  local cleanup_needed=0

  if [ -f /etc/sysconfig/pgsql/postgresql ]; then
    local old_pgdata
    old_pgdata=$(grep -E '^PGDATA=' /etc/sysconfig/pgsql/postgresql 2>/dev/null | tail -n1 | cut -d= -f2-)
    if [ -n "$old_pgdata" ] && [ "$old_pgdata" != "$datadir" ]; then
      warn "Removendo /etc/sysconfig/pgsql/postgresql com PGDATA=${old_pgdata} (sobra de tentativa anterior)."
      rm -f /etc/sysconfig/pgsql/postgresql
      cleanup_needed=1
    fi
  fi

  local dropin_dir="/etc/systemd/system/postgresql.service.d"
  if [ -d "$dropin_dir" ] && grep -rl "PGDATA=" "$dropin_dir" &>/dev/null; then
    local old_dropin_pgdata
    old_dropin_pgdata=$(grep -rh "^Environment=PGDATA=" "$dropin_dir" 2>/dev/null | tail -n1 | sed 's/^Environment=PGDATA=//')
    if [ -n "$old_dropin_pgdata" ] && [ "$old_dropin_pgdata" != "$datadir" ]; then
      warn "Removendo drop-in systemd ${dropin_dir}/ com PGDATA=${old_dropin_pgdata} (sobra de tentativa anterior)."
      rm -rf "$dropin_dir"
      cleanup_needed=1
    fi
  fi

  if [ "$cleanup_needed" -eq 1 ]; then
    systemctl daemon-reload
    info "Configuracao de PGDATA limpa; postgresql-setup vai usar o padrao: ${datadir}"
  fi

  prepare_pg_datadir_for_initdb "$datadir"

  # O initdb falha com "invalid locale settings" quando o servidor nao tem
  # os arquivos de locale instalados, mesmo que LANG esteja setada. Isso e
  # comum em VMs provisionadas com LANG=en_US.utf8 mas sem o langpack
  # correspondente instalado (en_US.utf8 e diferente de en_US.UTF-8 no
  # glibc -- o segundo precisa do pacote glibc-langpack-en).
  # Instalamos o langpack sempre que estiver faltando, e passamos o locale
  # correto direto ao initdb via PGSETUP_INITDB_OPTIONS.
  case "$PKG_FAMILY" in
    rhel)
      pkg_install glibc-langpack-en 2>/dev/null || true
      ;;
    debian)
      apt_install locales 2>/dev/null || true
      locale-gen en_US.UTF-8 2>/dev/null || true
      ;;
  esac
  export LANG=en_US.UTF-8
  export LC_ALL=en_US.UTF-8
  export PGSETUP_INITDB_OPTIONS="--locale=en_US.UTF-8"

  info "Cluster do PostgreSQL nao inicializado neste servidor; rodando postgresql-setup --initdb..."
  postgresql-setup --initdb || die "Falha ao inicializar o cluster do PostgreSQL (postgresql-setup --initdb). Veja /var/lib/pgsql/initdb_postgresql.log para detalhes."
}

# Executa um comando SQL via o cliente mysql/mariadb como root, usando
# autenticacao por socket (sem senha) se disponivel, ou a senha fornecida.
mysql_root_exec() {
  if [ -z "$DB_ROOT_PASSWORD" ] && mysql -u root -e "SELECT 1;" &>/dev/null; then
    mysql -u root "$@"
  else
    mysql -u root -p"$DB_ROOT_PASSWORD" "$@"
  fi
}

setup_db_role_mysql() {
  # Garante que o servico esta rodando. Se nenhum banco foi encontrado
  # anteriormente, install_mariadb_compatible() ja foi chamado pelo
  # decide_db_engine_for_role_db() e o servico ja deve estar ativo.
  for unit in mariadb mysql mysqld; do
    if systemctl list-units --full --all 2>/dev/null | grep -q "^${unit}\.service"; then
      systemctl enable --now "$unit" 2>/dev/null || true
      wait_for_active "$unit" 30 && break
    fi
  done

  if ! mysql -u root -e "SELECT 1;" &>/dev/null; then
    DB_ROOT_PASSWORD=$(ask_secret "Senha do usuario root do MySQL/MariaDB")
    if ! mysql_root_exec -e "SELECT 1;" &>/dev/null; then
      die "Nao foi possivel autenticar como root no MySQL/MariaDB com a senha informada."
    fi
  else
    info "Conectado como root via socket local, sem senha."
  fi

  local version vendor
  version=$(mysql_root_exec -N -e "SELECT VERSION();" 2>/dev/null | cut -d- -f1)
  vendor="MySQL"
  mysql_root_exec -N -e "SELECT VERSION();" 2>/dev/null | grep -qi "mariadb" && vendor="MariaDB"
  info "Servidor detectado: ${vendor} ${version}"

  local min_version="$MYSQL_MIN_VERSION"
  [ "$vendor" = "MariaDB" ] && min_version="$MARIADB_MIN_VERSION"
  if [ -n "$version" ] && ! version_ge "$version" "$min_version"; then
    warn "${vendor} ${version} esta ABAIXO do minimo suportado pelo Django 6.0 (${vendor} ${min_version}+)."
    warn "MariaDB 10.3, em particular, esta fora de suporte oficial (EOL) desde maio de 2023 -- sem patches de seguranca."
    if ! ask_yes_no "Continuar mesmo assim? NAO recomendado para producao -- migracoes podem falhar ou o comportamento pode ser instavel." "N"; then
      die "Abortado para que o ${vendor} seja atualizado para ${min_version}+ antes de prosseguir (em producao, planeje essa atualizacao com janela de manutencao)."
    fi
  fi

  DB_NAME=$(ask_input "Nome do banco de dados a criar" "$DB_NAME")
  DB_USER=$(ask_input "Usuario da aplicacao a criar" "$DB_USER")
  if [ -z "$DB_PASSWORD" ]; then
    if ask_yes_no "Gerar uma senha aleatoria para o usuario '$DB_USER'?" "s"; then
      DB_PASSWORD=$(gen_password 24)
    else
      DB_PASSWORD=$(ask_secret "Senha para o usuario '$DB_USER'")
    fi
  fi

  APP_SERVER_HOST=$(ask_input "Hostname ou IP do servidor de aplicacao que vai se conectar (use '%' para permitir qualquer host -- NAO recomendado em producao)" "${APP_SERVER_HOST:-%}")

  mysql_root_exec <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'${APP_SERVER_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'${APP_SERVER_HOST}' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${APP_SERVER_HOST}';
FLUSH PRIVILEGES;
SQL

  if [ "$APP_SERVER_HOST" != "localhost" ] && [ "$APP_SERVER_HOST" != "127.0.0.1" ]; then
    ensure_mariadb_remote_access
  fi

  print_db_role_summary "mysql"
}

# Ajusta bind-address (se necessario) e a porta no firewall para permitir
# que o servidor de aplicacao se conecte remotamente. Pergunta antes de
# qualquer alteracao, pois reinicia um servico de banco em producao.
ensure_mariadb_remote_access() {
  local bind_addr
  bind_addr=$(mysql_root_exec -N -e "SHOW VARIABLES LIKE 'bind_address';" 2>/dev/null | awk '{print $2}')
  info "bind-address atual do MySQL/MariaDB: ${bind_addr:-desconhecido}"

  if [ "$bind_addr" = "127.0.0.1" ] || [ "$bind_addr" = "localhost" ] || [ "$bind_addr" = "::1" ]; then
    warn "O servidor so aceita conexoes locais (bind-address=$bind_addr); o servidor de aplicacao NAO vai conseguir se conectar assim."
    local do_fix=1
    if [ "$DB_FRESH_INSTALL" -eq 1 ]; then
      info "Instalacao recem-feita por este script: ajustando bind-address automaticamente (sem perguntar), pois nao ha nada em producao em risco aqui."
    else
      ask_yes_no "Localizar o arquivo de configuracao e ajustar bind-address para 0.0.0.0 automaticamente (reinicia o MySQL/MariaDB)?" "N" || do_fix=0
    fi
    if [ "$do_fix" -eq 1 ]; then
      local cnf_file
      cnf_file=$(grep -rl "^[[:space:]]*bind-address" /etc/my.cnf /etc/my.cnf.d/ /etc/mysql/ 2>/dev/null | head -n1)
      if [ -z "$cnf_file" ]; then
        warn "Nao encontrei a linha bind-address em nenhum arquivo de configuracao conhecido (/etc/my.cnf, /etc/my.cnf.d/, /etc/mysql/). Ajuste manualmente e reinicie o servico."
      else
        cp "$cnf_file" "${cnf_file}.bak.$(date +%s)"
        sed -i "s/^[[:space:]]*bind-address.*/bind-address = 0.0.0.0/" "$cnf_file"
        info "Ajustado em $cnf_file. Reiniciando o servico..."
        systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || systemctl restart mysqld 2>/dev/null || true
        wait_for_active mariadb 20 2>/dev/null || wait_for_active mysql 20 2>/dev/null || wait_for_active mysqld 20 2>/dev/null || true
      fi
    else
      warn "Pulado a pedido do usuario. Ajuste manualmente o bind-address e reinicie o servico antes de testar a conexao do servidor de aplicacao."
    fi
  fi

  local open_port=1
  if [ "$DB_FRESH_INSTALL" -eq 0 ]; then
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
      ask_yes_no "Abrir a porta 3306/tcp no firewalld para '${APP_SERVER_HOST}'?" "s" || open_port=0
    elif command -v ufw &>/dev/null; then
      ask_yes_no "Abrir a porta 3306/tcp no ufw para '${APP_SERVER_HOST}'?" "s" || open_port=0
    fi
  else
    info "Instalacao recem-feita: liberando a porta 3306/tcp no firewall automaticamente para '${APP_SERVER_HOST}'."
  fi

  if [ "$open_port" -eq 1 ]; then
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
      if [ "$APP_SERVER_HOST" = "%" ]; then
        firewall-cmd --permanent --add-port=3306/tcp
      else
        local app_ip
        app_ip=$(resolve_to_ip "$APP_SERVER_HOST")
        firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=${app_ip}/32 port port=3306 protocol=tcp accept" 2>/dev/null || \
          firewall-cmd --permanent --add-port=3306/tcp
      fi
      firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
      if [ "$APP_SERVER_HOST" = "%" ]; then
        ufw allow 3306/tcp
      else
        ufw allow from "$(resolve_to_ip "$APP_SERVER_HOST")" to any port 3306 proto tcp
      fi
    fi
  fi
}

setup_db_role_postgresql() {
  # No RHEL/AlmaLinux, o pacote postgresql-server NAO inicializa o cluster
  # por conta propria (diferente do Debian, onde o postgresql-common ja
  # cria um cluster padrao na instalacao) -- exige "postgresql-setup --initdb"
  # manualmente. Isso pode ter sido pulado se o pacote foi instalado antes
  # desta execucao (por outro processo, ou uma tentativa anterior) sem
  # nunca ter sido inicializado. ensure_postgresql_initdb_rhel() cobre os
  # dois casos (instalacao nova OU pacote preexistente nunca inicializado),
  # sempre no caminho padrao -- idempotente (so age se o cluster realmente
  # nao existir ainda).
  if [ "$PKG_FAMILY" = "rhel" ]; then
    ensure_postgresql_initdb_rhel
  fi

  systemctl enable --now postgresql 2>/dev/null || true
  if ! wait_for_active postgresql 30; then
    journalctl -u postgresql -n 50 --no-pager 2>/dev/null || true
    die "PostgreSQL nao iniciou a tempo. Veja o log do servico acima (journalctl -u postgresql) para o motivo exato."
  fi

  local version
  version=$(sudo -u postgres psql -tAc "SHOW server_version;" 2>/dev/null | cut -d. -f1)
  info "Versao detectada: PostgreSQL ${version}"
  if [ -n "$version" ] && ! version_ge "${version}.0" "${POSTGRES_MIN_VERSION}.0"; then
    warn "PostgreSQL ${version} esta abaixo da versao minima recomendada (${POSTGRES_MIN_VERSION}+) para o Django 6.0."
    if ! ask_yes_no "Continuar mesmo assim? NAO recomendado para producao." "N"; then
      die "Abortado para que o PostgreSQL seja atualizado antes de prosseguir."
    fi
  fi

  ensure_pg_hba_password_auth

  DB_NAME=$(ask_input "Nome do banco de dados a criar" "$DB_NAME")
  DB_USER=$(ask_input "Usuario da aplicacao a criar" "$DB_USER")
  if [ -z "$DB_PASSWORD" ]; then
    if ask_yes_no "Gerar uma senha aleatoria para o usuario '$DB_USER'?" "s"; then
      DB_PASSWORD=$(gen_password 24)
    else
      DB_PASSWORD=$(ask_secret "Senha para o usuario '$DB_USER'")
    fi
  fi
  APP_SERVER_HOST=$(ask_input "Hostname ou IP do servidor de aplicacao que vai se conectar (use '0.0.0.0/0' para qualquer host -- NAO recomendado em producao)" "${APP_SERVER_HOST:-0.0.0.0/0}")

  local role_exists db_exists
  role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" 2>/dev/null || true)
  if [ "$role_exists" = "1" ]; then
    sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  else
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
  fi
  db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null || true)
  if [ "$db_exists" != "1" ]; then
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};"
  fi

  ensure_postgresql_remote_access

  print_db_role_summary "postgresql"
}

ensure_postgresql_remote_access() {
  local conf listen
  conf=$(sudo -u postgres psql -tAc "SHOW config_file;" 2>/dev/null | xargs) || true
  listen=$(sudo -u postgres psql -tAc "SHOW listen_addresses;" 2>/dev/null | xargs) || true
  info "listen_addresses atual: ${listen:-desconhecido}"

  if [ "$listen" = "localhost" ] && [ -n "$conf" ] && [ -f "$conf" ]; then
    warn "O PostgreSQL so escuta em localhost; o servidor de aplicacao NAO vai conseguir se conectar assim."
    local do_fix=1
    if [ "$DB_FRESH_INSTALL" -eq 1 ]; then
      info "Instalacao recem-feita por este script: ajustando listen_addresses automaticamente (sem perguntar), pois nao ha nada em producao em risco aqui."
    else
      ask_yes_no "Ajustar listen_addresses para '*' em $conf automaticamente (reinicia o PostgreSQL)?" "N" || do_fix=0
    fi
    if [ "$do_fix" -eq 1 ]; then
      cp "$conf" "${conf}.bak.$(date +%s)"
      sed -i "s/^[[:space:]]*#\?[[:space:]]*listen_addresses.*/listen_addresses = '*'/" "$conf"
      systemctl restart postgresql
      wait_for_active postgresql 20 || true
    else
      warn "Pulado a pedido do usuario. Ajuste manualmente e reinicie o PostgreSQL antes de testar a conexao remota."
    fi
  fi

  local hba marker="# ocsinventory-installer: acesso remoto para o servidor de aplicacao"
  hba=$(sudo -u postgres psql -tAc "SHOW hba_file;" 2>/dev/null | xargs) || true
  if [ -n "$hba" ] && [ -f "$hba" ] && ! grep -qF "$marker" "$hba"; then
    # Resolve o hostname para IP antes de escrever no pg_hba.conf: o
    # PostgreSQL valida a regra fazendo lookup reverso, e se o servidor
    # de banco nao conseguir resolver o hostname do app server (sem DNS
    # interno / /etc/hosts), a regra nunca casa e a conexao e recusada.
    local app_host_resolved
    app_host_resolved=$(resolve_to_ip "$APP_SERVER_HOST")
    if [ "$app_host_resolved" != "$APP_SERVER_HOST" ]; then
      info "Hostname '${APP_SERVER_HOST}' resolvido para '${app_host_resolved}' -- usando o IP no pg_hba.conf para evitar falha de resolucao DNS no servidor de banco."
    fi
    local app_host_for_hba="$app_host_resolved"
    # IP sem mascara no pg_hba.conf e invalido ("invalid IP mask"); um
    # host unico precisa de /32 (IPv4) ou /128 (IPv6). Wildcards (%,
    # 0.0.0.0/0) e hostnames ficam como estao.
    if [[ "$app_host_for_hba" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      app_host_for_hba="${app_host_for_hba}/32"
    elif [[ "$app_host_for_hba" =~ ^[0-9a-fA-F:]+$ ]]; then
      app_host_for_hba="${app_host_for_hba}/128"
    fi
    echo "${marker}
host    ${DB_NAME}    ${DB_USER}    ${app_host_for_hba}    md5" >> "$hba"
    sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null || \
      systemctl reload postgresql 2>/dev/null || systemctl restart postgresql
  fi

  local open_port=1
  if [ "$DB_FRESH_INSTALL" -eq 0 ]; then
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
      ask_yes_no "Abrir a porta 5432/tcp no firewalld para '${APP_SERVER_HOST}'?" "s" || open_port=0
    elif command -v ufw &>/dev/null; then
      ask_yes_no "Abrir a porta 5432/tcp no ufw?" "s" || open_port=0
    fi
  else
    info "Instalacao recem-feita: liberando a porta 5432/tcp no firewall automaticamente."
  fi

  if [ "$open_port" -eq 1 ]; then
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
      firewall-cmd --permanent --add-port=5432/tcp
      firewall-cmd --reload
    elif command -v ufw &>/dev/null; then
      ufw allow 5432/tcp
    fi
  fi
}

print_db_role_summary() {
  local engine=$1
  {
    echo "==================================================================="
    echo " OCS Inventory 3.0 -- banco de dados preparado (papel 'db', ${engine})"
    echo "==================================================================="
    echo "Host deste servidor de banco ..: ${SERVER_HOST}"
    echo "Banco de dados .................: ${DB_NAME}"
    echo "Usuario da aplicacao ...........: ${DB_USER}"
    echo "Senha do usuario ................: ${DB_PASSWORD}"
    echo "Liberado para o host ............: ${APP_SERVER_HOST}"
    echo
    echo "Use estes dados ao rodar o script com --role app no servidor de aplicacao:"
    echo "  --db-host ${SERVER_HOST} --db-name ${DB_NAME} --db-user ${DB_USER} --db-password '${DB_PASSWORD}'"
    echo "==================================================================="
  } | tee "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  warn "Essas credenciais tambem foram salvas em $CRED_FILE (permissao 600). A senha de root do banco NUNCA e salva."
}

#############################################
# Papel "app": conecta a um banco de dados REMOTO, ja preparado com
# --role db em outro servidor. Pergunta os dados de conexao e TESTA antes
# de seguir com a instalacao do backend/frontend.
#############################################
setup_app_role_db_connection() {
  # Se --db-engine nao foi passado via flag, pergunta aqui -- evita o
  # problema comum de escolher [5] Aplicacao no menu e o script assumir
  # MySQL quando o banco e PostgreSQL.
  if [ -z "$DB_ENGINE_CHOICE" ] || [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
    if [ -z "$DB_ENGINE_CHOICE" ] && [ "$ASSUME_YES" -eq 0 ] && [ -t 0 ]; then
      cat <<'EOF'

Qual o motor do banco de dados remoto?
  [1] MySQL / MariaDB
  [2] PostgreSQL
EOF
      local choice
      read -r -p "Escolha [1/2]: " choice
      case "$choice" in
        1) DB_ENGINE_CHOICE="mysql" ;;
        2) DB_ENGINE_CHOICE="postgresql" ;;
        *) die "Opcao invalida." ;;
      esac
    elif [ -z "$DB_ENGINE_CHOICE" ]; then
      DB_ENGINE_CHOICE="mysql"
    fi
  fi

  case "$DB_ENGINE_CHOICE" in
    mysql)
      DB_HOST=$(ask_input "Host do banco de dados (MySQL/MariaDB)" "${DB_HOST:-lnxdcocsdb01}")
      DB_PORT=$(ask_input "Porta do banco de dados" "${DB_PORT:-3306}")
      DB_NAME=$(ask_input "Nome do banco de dados" "${DB_NAME}")
      DB_USER=$(ask_input "Usuario do banco de dados" "${DB_USER}")
      if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(ask_secret "Senha do usuario '$DB_USER' no banco")
      fi
      test_mysql_connection
      ;;
    postgresql)
      DB_HOST=$(ask_input "Host do banco de dados (PostgreSQL)" "${DB_HOST:-lnxdcocsdb01}")
      DB_PORT=$(ask_input "Porta do banco de dados" "${DB_PORT:-5432}")
      DB_NAME=$(ask_input "Nome do banco de dados" "${DB_NAME}")
      DB_USER=$(ask_input "Usuario do banco de dados" "${DB_USER}")
      if [ -z "$DB_PASSWORD" ]; then
        DB_PASSWORD=$(ask_secret "Senha do usuario '$DB_USER' no banco")
      fi
      test_postgresql_connection
      ;;
  esac
}

test_mysql_connection() {
  if ! command -v mysql &>/dev/null; then
    case "$PKG_FAMILY" in
      debian) apt_install mariadb-client || apt_install default-mysql-client ;;
      rhel)   pkg_install mariadb ;;
    esac
  fi
  info "Testando conexao com ${DB_HOST}:${DB_PORT}..."
  if ! mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" -e "SELECT 1;" &>/dev/null; then
    die "Nao foi possivel conectar em ${DB_HOST}:${DB_PORT}/${DB_NAME} com o usuario '${DB_USER}'. Verifique host/porta/usuario/senha, firewall e bind-address no servidor de banco (rode --role db la primeiro), e tente novamente."
  fi
  info "Conexao com o banco de dados OK."

  local version
  version=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASSWORD" -N -e "SELECT VERSION();" 2>/dev/null | cut -d- -f1)
  if [ -n "$version" ]; then
    info "Versao do servidor remoto: $version"
    if ! version_ge "$version" "$MARIADB_MIN_VERSION"; then
      warn "Versao do servidor (${version}) esta abaixo do minimo exigido pelo Django 6.0 (MariaDB ${MARIADB_MIN_VERSION}+ / MySQL ${MYSQL_MIN_VERSION}+)."
      ask_yes_no "Continuar mesmo assim? Migracoes podem falhar." "N" || die "Abortado. Atualize o servidor de banco e rode novamente."
    fi
  fi
}

test_postgresql_connection() {
  if ! command -v psql &>/dev/null; then
    case "$PKG_FAMILY" in
      debian) apt_install postgresql-client ;;
      rhel)   pkg_install postgresql ;;
    esac
  fi
  info "Testando conexao com ${DB_HOST}:${DB_PORT}..."
  if ! PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" &>/dev/null; then
    die "Nao foi possivel conectar em ${DB_HOST}:${DB_PORT}/${DB_NAME} com o usuario '${DB_USER}'. Verifique host/porta/usuario/senha, firewall e listen_addresses no servidor de banco (rode --role db la primeiro), e tente novamente."
  fi
  info "Conexao com o banco de dados OK."
}

# Testa se a API do backend esta respondendo num host remoto.
# Usada pelo --role frontend e --role snmp antes de prosseguir.
test_backend_connection() {
  local host=$1 port=${2:-$BACKEND_PORT}
  test_tcp_connectivity "$host" "$port" "backend API"
  info "Testando resposta HTTP da API do backend em http://${host}:${port}..."
  if command -v curl &>/dev/null; then
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${host}:${port}/" 2>/dev/null || true)
    if [ "$http_code" = "000" ]; then
      die "A API do backend em http://${host}:${port}/ nao respondeu. Verifique se o servico ocsinventory-backend.service esta ativo no servidor de backend."
    fi
    info "Backend respondeu com HTTP ${http_code} -- OK."
  fi
}

#############################################
# Papel "backend": instala so a API Django + uWSGI (sem frontend)
# conectando a um banco de dados remoto ja preparado.
#############################################
setup_backend_role() {
  info "Papel 'backend': instalando API Django + uWSGI (sem frontend)."
  info "Banco de dados remoto: ${DB_HOST}:${DB_PORT} (${DB_ENGINE_CHOICE})"
}

#############################################
# Papel "frontend": instala so o console Vue.js + Nginx,
# apontando para um backend remoto ja instalado.
#############################################
setup_frontend_role() {
  if [ -z "$BACKEND_HOST" ]; then
    BACKEND_HOST=$(ask_input "Host ou IP do servidor de BACKEND (onde a API Django esta rodando)" "")
    [ -z "$BACKEND_HOST" ] && die "Host do backend e obrigatorio para o papel 'frontend'."
  fi
  test_tcp_connectivity "$BACKEND_HOST" "$BACKEND_PORT" "backend API"
  info "Papel 'frontend': console web sera configurado para usar o backend em http://${BACKEND_HOST}:${BACKEND_PORT}."
}

#############################################
# Papel "snmp": instala so o SNMP Discovery Scanner,
# apontando para um backend remoto ja instalado.
#############################################
setup_snmp_role() {
  if [ -z "$BACKEND_HOST" ]; then
    BACKEND_HOST=$(ask_input "Host ou IP do servidor de BACKEND (onde a API Django esta rodando)" "")
    [ -z "$BACKEND_HOST" ] && die "Host do backend e obrigatorio para o papel 'snmp'."
  fi
  test_tcp_connectivity "$BACKEND_HOST" "$BACKEND_PORT" "backend API"
  info "Papel 'snmp': scanner sera configurado para reportar ao backend em http://${BACKEND_HOST}:${BACKEND_PORT}."
}

#############################################
# Backend (Django REST API)
#############################################
install_backend() {
  ensure_python312
  case "$PKG_FAMILY" in
    debian)
      apt_install libldap2-dev libsasl2-dev libssl-dev build-essential
      if [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
        apt_install default-libmysqlclient-dev pkg-config || apt_install libmariadb-dev pkg-config
      fi
      ;;
    rhel)
      pkg_install openldap-devel cyrus-sasl-devel openssl-devel gcc gcc-c++ make
      if [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
        pkg_install mariadb-devel || pkg_install mysql-devel
      fi
      ;;
  esac
  clone_or_checkout "$GIT_BACKEND_URL" "$BASE_DIR/backend" "$OCS_TAG"

  if [ ! -d "$BASE_DIR/backend/venv" ]; then
    sudo -u "$OCS_SYS_USER" "$PYTHON_BIN" -m venv "$BASE_DIR/backend/venv"
  fi
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install --upgrade pip
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install -r "$BASE_DIR/backend/requirements.txt"
  if [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
    sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install -r "$BASE_DIR/backend/requirements_mysql.txt"
  else
    sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install -r "$BASE_DIR/backend/requirements_psql.txt"
  fi
  sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/pip" install uwsgi
}

configure_backend_env() {
  local env_file="$BASE_DIR/backend/.env"
  if [ ! -f "$env_file" ]; then
    cp "$BASE_DIR/backend/.env-sample" "$env_file"
  fi
  local secret
  secret=$(sudo -u "$OCS_SYS_USER" "$BASE_DIR/backend/venv/bin/python" -c "import secrets;print(secrets.token_urlsafe(50))")

  local db_engine_value
  if [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
    db_engine_value="django.db.backends.mysql"
  else
    db_engine_value="django.db.backends.postgresql"
  fi

  sed -i "s|^SECRET_KEY=.*|SECRET_KEY='${secret}'|" "$env_file"
  sed -i "s|^DEBUG=.*|DEBUG=False|" "$env_file"
  sed -i "s|^FRONTEND_REDIRECT=.*|FRONTEND_REDIRECT='http://${SERVER_HOST}:${FRONTEND_PORT}'|" "$env_file"
  sed -i "s|^DB_ENGINE=.*|DB_ENGINE='${db_engine_value}'|" "$env_file"
  sed -i "s|^DB_NAME=.*|DB_NAME='${DB_NAME}'|" "$env_file"
  sed -i "s|^DB_USER=.*|DB_USER='${DB_USER}'|" "$env_file"
  sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD='${DB_PASSWORD}'|" "$env_file"
  sed -i "s|^DB_HOST=.*|DB_HOST='${DB_HOST}'|" "$env_file"
  sed -i "s|^DB_PORT=.*|DB_PORT='${DB_PORT}'|" "$env_file"

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

  local after_db="network-online.target"
  if [ "$ROLE" = "standalone" ]; then
    if [ "$DB_ENGINE_CHOICE" = "mysql" ]; then
      after_db="mariadb.service mysql.service"
    else
      after_db="postgresql.service"
    fi
  fi

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
After=network.target ${after_db}

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
  # Em arquitetura multi-layer (--role frontend), o backend esta em outro
  # servidor (BACKEND_HOST). Nos papeis app/standalone, esta no mesmo
  # servidor (SERVER_HOST).
  local api_host="${BACKEND_HOST:-$SERVER_HOST}"
  mkdir -p "$BASE_DIR/frontend/public/config"
  cat > "$BASE_DIR/frontend/public/config/config.json" <<EOF
{
  "BACKEND_API_ROUTE": "http://${api_host}:${BACKEND_PORT}/"
}
EOF
  info "Frontend configurado para usar backend em http://${api_host}:${BACKEND_PORT}/"
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
    echo "Banco (${DB_ENGINE_CHOICE}) .: ${DB_NAME} / usuario ${DB_USER} @ ${DB_HOST:-localhost}:${DB_PORT}"
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
# Papel "db-remote": instala/configura o banco de dados em OUTRO servidor,
# via SSH, a partir deste. Roda --role db remotamente e traz o resumo de
# credenciais de volta. Util quando se quer disparar a preparacao do banco
# direto do servidor de aplicacao (ou de uma maquina de administracao),
# sem precisar logar manualmente no servidor de banco.
#############################################
ensure_ssh_client_tools() {
  if command -v ssh &>/dev/null && command -v scp &>/dev/null; then
    return 0
  fi
  info "Cliente SSH (ssh/scp) nao encontrado; instalando..."
  case "$PKG_FAMILY" in
    debian) apt_install openssh-client ;;
    rhel)   pkg_install openssh-clients ;;
  esac
  command -v ssh &>/dev/null && command -v scp &>/dev/null || \
    die "Nao foi possivel instalar o cliente SSH (ssh/scp). Instale manualmente e rode o script novamente."
}

orchestrate_remote_db_install() {
  ensure_ssh_client_tools

  REMOTE_DB_HOST=$(ask_input "Host ou IP do servidor REMOTO onde o banco sera preparado" "${REMOTE_DB_HOST}")
  [ -z "$REMOTE_DB_HOST" ] && die "Host do servidor remoto e obrigatorio."
  REMOTE_DB_SSH_USER=$(ask_input "Usuario SSH no servidor remoto" "${REMOTE_DB_SSH_USER:-root}")
  REMOTE_DB_SSH_PORT=$(ask_input "Porta SSH no servidor remoto" "${REMOTE_DB_SSH_PORT:-22}")
  if [ -z "$REMOTE_DB_SSH_KEY" ]; then
    REMOTE_DB_SSH_KEY=$(ask_input "Caminho de uma chave privada SSH (deixe vazio para usar agente/senha interativa)" "")
  fi

  local ssh_opts=(-p "$REMOTE_DB_SSH_PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
  if [ -n "$REMOTE_DB_SSH_KEY" ]; then
    [ -f "$REMOTE_DB_SSH_KEY" ] || die "Chave SSH nao encontrada em: $REMOTE_DB_SSH_KEY"
    ssh_opts+=(-i "$REMOTE_DB_SSH_KEY")
  fi
  local target="${REMOTE_DB_SSH_USER}@${REMOTE_DB_HOST}"

  info "Testando conexao SSH com ${target}:${REMOTE_DB_SSH_PORT}..."
  if ! ssh "${ssh_opts[@]}" "$target" "echo ok" >/dev/null; then
    die "Nao foi possivel conectar via SSH em ${target}:${REMOTE_DB_SSH_PORT}. Verifique host, usuario, porta, chave/senha e firewall, e tente novamente."
  fi
  info "Conexao SSH OK."

  local script_path
  script_path=$(readlink -f "$0" 2>/dev/null) || true
  if [ -z "$script_path" ] || [ ! -f "$script_path" ]; then
    die "Nao foi possivel localizar o caminho deste script (necessario para copia-lo ao servidor remoto). Rode-o a partir de um arquivo local, nao via pipe/curl direto."
  fi

  local remote_tmp="/tmp/ocsinventory-installer-$$.sh"
  info "Copiando o script para ${REMOTE_DB_HOST}:${remote_tmp}..."
  scp "${ssh_opts[@]}" "$script_path" "${target}:${remote_tmp}" || \
    die "Falha ao copiar o script para o servidor remoto."

  local app_host_for_remote
  app_host_for_remote=$(ask_input "Host/IP do servidor de APLICACAO a liberar no banco remoto" "${APP_SERVER_HOST:-$(detect_ip)}")

  local remote_args=(--role db --app-host "$app_host_for_remote")
  [ -n "$DB_ENGINE_CHOICE" ] && remote_args+=(--db-engine "$DB_ENGINE_CHOICE")
  [ -n "$DB_NAME" ] && remote_args+=(--db-name "$DB_NAME")
  [ -n "$DB_USER" ] && remote_args+=(--db-user "$DB_USER")
  [ "$ASSUME_YES" -eq 1 ] && remote_args+=(-y)

  # Monta a linha de comando remota com cada argumento individualmente
  # escapado (printf %q), em vez de interpolar o array direto numa string
  # -- assim valores com espaco/aspas (hosts, nomes de banco) nao quebram
  # o comando executado do outro lado do SSH.
  local remote_cmd
  remote_cmd=$(printf '%q' "$remote_tmp")
  remote_cmd="sudo bash ${remote_cmd}"
  for a in "${remote_args[@]}"; do
    remote_cmd+=" $(printf '%q' "$a")"
  done

  info "Executando a preparacao do banco remotamente em ${REMOTE_DB_HOST} -- as perguntas interativas (se houver) aparecem aqui normalmente."
  # -t aloca um pseudo-terminal e o repassa pelo SSH, para que
  # ask_input/ask_yes_no/ask_secret do script remoto funcionem normalmente
  # neste terminal local, como se estivessemos logados la.
  ssh -t "${ssh_opts[@]}" "$target" "$remote_cmd"
  local remote_exit=$?

  ssh "${ssh_opts[@]}" "$target" "sudo rm -f $(printf '%q' "$remote_tmp")" 2>/dev/null || true

  if [ "$remote_exit" -ne 0 ]; then
    die "A preparacao remota do banco falhou (codigo $remote_exit). Veja a saida acima para o diagnostico."
  fi

  local local_cred_copy="/root/ocsinventory-credentials-${REMOTE_DB_HOST}.txt"
  if scp "${ssh_opts[@]}" "${target}:/root/ocsinventory-credentials.txt" "$local_cred_copy" 2>/dev/null; then
    chmod 600 "$local_cred_copy"
    info "Credenciais do banco remoto tambem copiadas para aqui: $local_cred_copy"
  else
    warn "Nao foi possivel copiar o arquivo de credenciais do servidor remoto; use a saida impressa acima."
  fi

  info "Banco de dados preparado com sucesso em ${REMOTE_DB_HOST}. Use as credenciais acima para rodar --role app no servidor de aplicacao."
}

#############################################
# CLI
#############################################
usage() {
  cat <<EOF
Uso: sudo $0 --role PAPEL [opcoes]

Papeis disponíveis (perguntado interativamente se omitido):
  --role db           Banco de dados -- MySQL/MariaDB ou PostgreSQL
                        (roda LOCALMENTE no servidor de banco, sem conexao de rede
                        com os outros componentes -- use em ambientes com CyberArk)
  --role backend      API Django + uWSGI (conecta ao --db-host remoto)
  --role frontend     Console web Vue.js + Nginx (conecta ao --backend-host remoto)
  --role snmp         SNMP Discovery Scanner (conecta ao --backend-host remoto)
  --role app          Backend + Frontend no mesmo servidor (atalho para [2]+[3])
  --role standalone   Tudo em um servidor (laboratorio/teste)
  --role db-remote    Prepara o banco em OUTRO servidor via SSH

Opcoes gerais:
  --host IP            IP deste servidor (perguntado se houver multiplas interfaces)
  --backend-port PORTA Porta do backend/API (padrao: 8000)
  --frontend-port PORT Porta do console web (padrao: 8080)
  --admin-user USER    Usuario admin do console (padrao: admin)
  --admin-email EMAIL  E-mail do admin (padrao: admin@localhost)
  --admin-password PW  Senha do admin (gerada aleatoriamente se omitida)
  --snmp-subnet CIDR   Subnet varrida pelo SNMP (auto-detectada se omitida)
  --base-dir CAMINHO   Diretorio de instalacao (padrao: /opt/ocsinventory)
  --ocs-tag TAG        Tag git (padrao: 3.0.0-rc1)
  --skip-snmp          Nao instalar o SNMP Scanner
  --skip-agent         Nao instalar o agente neste servidor
  --os-upgrade         Atualizar o S.O. sem perguntar
  --no-os-upgrade      NAO atualizar o S.O. sem perguntar
  -y, --yes            Modo nao-interativo (usa padroes/flags)
  -h, --help           Mostra esta ajuda

Opcoes de banco (papeis db / backend / app / standalone):
  --db-engine mysql|postgresql  Motor do banco (padrao: mysql para backend/app)
  --db-host HOST                Host do banco remoto (papeis backend/app)
  --db-port PORTA               Porta do banco remoto
  --db-name NOME                Nome do banco (padrao: ocsdb)
  --db-user USUARIO             Usuario do banco (padrao: ocsuser)
  --db-password SENHA           Senha do usuario do banco
  --app-host HOST               [papel db] IP do servidor de app a liberar no banco

Opcoes multi-layer:
  --backend-host HOST           [papeis frontend/snmp] Host do servidor de backend

Opcoes do papel db-remote (SSH):
  --remote-db-host HOST         Host do servidor de banco remoto
  --remote-db-ssh-user USER     Usuario SSH (padrao: root)
  --remote-db-ssh-port PORTA    Porta SSH (padrao: 22)
  --remote-db-ssh-key CAMINHO   Chave privada SSH (opcional)

Exemplo 4 camadas:
  Servidor A: sudo $0 --role db       --db-engine postgresql --app-host IP_B
  Servidor B: sudo $0 --role backend  --db-engine postgresql --db-host IP_A --db-name ocsdb --db-user ocsuser --db-password PW
  Servidor C: sudo $0 --role frontend --backend-host IP_B
  Servidor D: sudo $0 --role snmp     --backend-host IP_B
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --role) ROLE="$2"; shift 2 ;;
      --db-engine) DB_ENGINE_CHOICE="$2"; shift 2 ;;
      --host) SERVER_HOST="$2"; shift 2 ;;
      --backend-port) BACKEND_PORT="$2"; shift 2 ;;
      --frontend-port) FRONTEND_PORT="$2"; shift 2 ;;
      --db-host) DB_HOST="$2"; shift 2 ;;
      --db-port) DB_PORT="$2"; shift 2 ;;
      --db-name) DB_NAME="$2"; shift 2 ;;
      --db-user) DB_USER="$2"; shift 2 ;;
      --db-password) DB_PASSWORD="$2"; shift 2 ;;
      --app-host) APP_SERVER_HOST="$2"; shift 2 ;;
      --backend-host) BACKEND_HOST="$2"; shift 2 ;;
      --remote-db-host) REMOTE_DB_HOST="$2"; shift 2 ;;
      --remote-db-ssh-user) REMOTE_DB_SSH_USER="$2"; shift 2 ;;
      --remote-db-ssh-port) REMOTE_DB_SSH_PORT="$2"; shift 2 ;;
      --remote-db-ssh-key) REMOTE_DB_SSH_KEY="$2"; shift 2 ;;
      --admin-user) ADMIN_USER="$2"; shift 2 ;;
      --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
      --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
      --snmp-subnet) SNMP_SUBNET="$2"; shift 2 ;;
      --base-dir) BASE_DIR="$2"; shift 2 ;;
      --ocs-tag) OCS_TAG="$2"; shift 2 ;;
      --skip-snmp) SKIP_SNMP=1; shift ;;
      --skip-agent) SKIP_AGENT=1; shift ;;
      --os-upgrade) RUN_OS_UPGRADE=1; shift ;;
      --no-os-upgrade) RUN_OS_UPGRADE=0; shift ;;
      -y|--yes) ASSUME_YES=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Opcao desconhecida: $1 (use --help)" ;;
    esac
  done

  case "$ROLE" in
    ""|db|backend|frontend|snmp|app|standalone|db-remote) ;;
    *) die "Valor invalido para --role: '$ROLE'. Opcoes: db, backend, frontend, snmp, app, standalone, db-remote" ;;
  esac
  case "$DB_ENGINE_CHOICE" in
    ""|mysql|postgresql) ;;
    *) die "Valor invalido para --db-engine: '$DB_ENGINE_CHOICE' (use mysql ou postgresql)" ;;
  esac
}

ask_role_if_needed() {
  if [ -n "$ROLE" ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    die "Defina o papel deste servidor com --role (obrigatorio quando nao ha terminal interativo). Use --help para ver as opcoes."
  fi
  cat <<'EOF'

========================================================
  OCS Inventory 3.0 -- Qual o papel deste servidor?
========================================================

  INSTALACAO EM CAMADAS (recomendado para producao):
  [1] Banco de dados      -- MySQL/MariaDB ou PostgreSQL
  [2] Backend (API)       -- Django REST API + uWSGI
  [3] Frontend (console)  -- Vue.js + Nginx
  [4] SNMP Discovery      -- Scanner de rede SNMP

  COMBINACOES CONVENIENTES:
  [5] Aplicacao completa  -- Backend + Frontend no mesmo servidor
  [6] Tudo em um          -- Banco + Backend + Frontend (laboratorio/teste)

  AVANCADO:
  [7] Preparar banco em OUTRO servidor via SSH (exige SSH entre hosts)
EOF
  local choice
  read -r -p "Escolha [1-7]: " choice
  case "$choice" in
    1) ROLE="db" ;;
    2) ROLE="backend" ;;
    3) ROLE="frontend" ;;
    4) ROLE="snmp" ;;
    5) ROLE="app" ;;
    6) ROLE="standalone" ;;
    7) ROLE="db-remote" ;;
    *) die "Opcao invalida: $choice" ;;
  esac
}

set_db_engine_default() {
  if [ -n "$DB_ENGINE_CHOICE" ]; then
    return 0
  fi
  case "$ROLE" in
    standalone) DB_ENGINE_CHOICE="postgresql" ;;
    backend|app) DB_ENGINE_CHOICE="mysql" ;;
    db|db-remote) DB_ENGINE_CHOICE="" ;;  # decidido em setup_db_role()
    frontend|snmp) DB_ENGINE_CHOICE="" ;; # nao se conectam ao banco diretamente
  esac
}

decide_optional_components() {
  # SNMP: so pergunta nos papeis que instalam o backend (standalone/app);
  # no papel "snmp" dediciado, a instalacao e obrigatoria (nao opcional).
  if [ "$SKIP_SNMP" -eq -1 ]; then
    case "$ROLE" in
      standalone) SKIP_SNMP=0 ;;
      app)
        if ask_yes_no "Instalar o SNMP Scanner tambem neste servidor?" "N"; then
          SKIP_SNMP=0
        else
          SKIP_SNMP=1
        fi
        ;;
      *) SKIP_SNMP=1 ;;
    esac
  fi

  # Agente: em arquitetura multi-layer, instala em TODOS os servidores
  # (recomendado para auto-inventario de cada camada). Pergunta so nos
  # papeis que nao sao banco (db ja nao tem frontend/backend pra exibir).
  if [ "$SKIP_AGENT" -eq -1 ]; then
    case "$ROLE" in
      standalone) SKIP_AGENT=0 ;;
      db) SKIP_AGENT=1 ;;
      *)
        if ask_yes_no "Instalar o agente OCS neste servidor (auto-inventario desta camada)?" "s"; then
          SKIP_AGENT=0
        else
          SKIP_AGENT=1
        fi
        ;;
    esac
  fi
}

confirm_or_die() {
  if [ "$ASSUME_YES" -eq 1 ] || [ ! -t 0 ]; then
    return 0
  fi
  local resumo
  case "$ROLE" in
    standalone)
      resumo="  - instalar PostgreSQL, Nginx, Python 3.12, Node.js 20 e Dart SDK
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - criar o banco '$DB_NAME' no PostgreSQL local
  - abrir as portas ${BACKEND_PORT} e ${FRONTEND_PORT} no firewall
  - instalar o agente OCS neste servidor"
      ;;
    app)
      resumo="  - conectar ao banco de dados em ${DB_HOST} (${DB_ENGINE_CHOICE})
  - instalar Python 3.12, Node.js 20, uWSGI e Nginx
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - abrir as portas ${BACKEND_PORT} e ${FRONTEND_PORT} no firewall
  - instalar o agente OCS neste servidor"
      ;;
    backend)
      resumo="  - conectar ao banco de dados em ${DB_HOST} (${DB_ENGINE_CHOICE})
  - instalar Python 3.12, uWSGI e Nginx (proxy do backend)
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - abrir a porta ${BACKEND_PORT} no firewall
  - instalar o agente OCS neste servidor"
      ;;
    frontend)
      resumo="  - conectar ao backend em ${BACKEND_HOST}:${BACKEND_PORT}
  - instalar Node.js 20 e Nginx
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - abrir a porta ${FRONTEND_PORT} no firewall
  - instalar o agente OCS neste servidor"
      ;;
    snmp)
      resumo="  - conectar ao backend em ${BACKEND_HOST}:${BACKEND_PORT}
  - instalar Python 3.12 e o SNMP Scanner
  - criar o usuario de sistema '$OCS_SYS_USER' e o diretorio $BASE_DIR
  - instalar o agente OCS neste servidor"
      ;;
    db)
      resumo="  - detectar ou instalar um servidor de banco de dados (${DB_ENGINE_CHOICE:-a definir})
  - criar o banco '$DB_NAME' e o usuario '$DB_USER'
  - liberar acesso remoto para o servidor de aplicacao (bind/listen address + firewall)"
      ;;
    db-remote)
      resumo="  - conectar via SSH em OUTRO servidor e executar --role db remotamente
  - trazer o resumo de credenciais de volta para este servidor"
      ;;
  esac
  cat <<EOF

Papel deste servidor : $ROLE
Motor de banco       : ${DB_ENGINE_CHOICE:-a definir}
IP deste servidor    : ${SERVER_HOST}

Este script vai, neste servidor:
$resumo

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
  OCS Inventory 3.0 -- instalador multi-layer
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
  ask_role_if_needed
  set_db_engine_default
  pick_server_ip

  # Gerar senhas que faltam
  if [ "$ROLE" = "standalone" ] && [ -z "$DB_PASSWORD" ]; then
    DB_PASSWORD=$(gen_password 24)
  fi
  case "$ROLE" in
    db|db-remote) ;;
    *) [ -z "$ADMIN_PASSWORD" ] && ADMIN_PASSWORD=$(gen_password 20) ;;
  esac

  confirm_or_die

  # --- Papel db-remote (SSH) ---
  if [ "$ROLE" = "db-remote" ]; then
    run_required "Preparacao do banco em outro servidor (via SSH)" orchestrate_remote_db_install
    return 0
  fi

  # --- Etapas comuns a todos os papeis ---
  run_required "Pacotes base do sistema"            install_base_packages
  run_required "Atualizacao do sistema operacional" maybe_run_os_upgrade
  run_required "Firewall (ufw/firewalld)"            setup_firewall

  # --- Papel db: so prepara o banco e encerra ---
  if [ "$ROLE" = "db" ]; then
    run_required "Configuracao do banco de dados" setup_db_role
    info "Papel 'db' concluido."
    info "Proximo passo: rode o script com --role backend (ou --role app) no servidor de aplicacao."
    return 0
  fi

  # --- Todos os outros papeis precisam do usuario de sistema ---
  run_required "Usuario de sistema '$OCS_SYS_USER'" create_system_user

  # --- Papel backend ---
  if [ "$ROLE" = "backend" ] || [ "$ROLE" = "app" ] || [ "$ROLE" = "standalone" ]; then
    if [ "$ROLE" = "standalone" ]; then
      run_required "Banco de dados local (${DB_ENGINE_CHOICE})" setup_postgres
    else
      run_required "Conexao com banco de dados remoto (${DB_ENGINE_CHOICE})" setup_app_role_db_connection
    fi
    run_required "Backend - codigo e dependencias"  install_backend
    run_required "Backend - configuracao (.env)"    configure_backend_env
    run_required "Backend - migracoes e estaticos"  backend_migrate_and_static
    run_required "Backend - superusuario"           backend_create_superuser
    run_required "Backend - uWSGI + Nginx"          backend_setup_uwsgi_and_nginx
    run_required "Backend - timer de automacao"     backend_setup_automation_timer
  fi

  # --- Papel frontend ---
  if [ "$ROLE" = "frontend" ] || [ "$ROLE" = "app" ] || [ "$ROLE" = "standalone" ]; then
    if [ "$ROLE" = "frontend" ]; then
      run_required "Verificacao do backend remoto" setup_frontend_role
    fi
    run_required "Frontend - codigo e dependencias" install_frontend
    run_required "Frontend - build"                 frontend_configure_and_build
    run_required "Frontend - Nginx"                 frontend_setup_nginx
  fi

  # --- Papel snmp dedicado ---
  if [ "$ROLE" = "snmp" ]; then
    run_required "Verificacao do backend remoto" setup_snmp_role
    run_required "SNMP Scanner"                  install_and_configure_snmp
  fi

  # --- Componentes opcionais (standalone/app: pergunta; outros papeis: so agente) ---
  decide_optional_components
  if [ "$ROLE" != "snmp" ]; then
    run_optional "SNMP Scanner" install_and_configure_snmp
  fi
  run_optional "Agente local (Dart)" install_agent

  validate_install
  print_summary
}

main "$@"
