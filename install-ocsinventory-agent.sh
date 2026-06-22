#!/usr/bin/env sh
# =============================================================================
# install-ocsinventory-agent.sh
#
# Instala (ou atualiza) o agente do OCS Inventory 3.0 em qualquer
# distribuicao Linux/Unix suportada. Se detectar uma versao anterior
# instalada, remove-a limpa antes de instalar a nova.
#
# Familias suportadas:
#   - Debian / Ubuntu / Mint e derivados   (apt)
#   - RHEL / AlmaLinux / Rocky / Fedora    (dnf / yum)
#   - openSUSE / SLES                      (zypper)
#   - Alpine Linux                         (apk)
#   - Arch Linux / Manjaro                 (pacman)
#   - Slackware                            (slackpkg / installpkg)
#
# Uso:
#   sudo ./install-ocsinventory-agent.sh [opcoes]
#
# Opcoes:
#   --url  URL       URL completa do backend, ex.: http://10.0.0.1:8000
#   --tag  TAG       Tag git (padrao: 3.0.0-rc1)
#   --base DIR       Diretorio base (padrao: /opt/ocsinventory)
#   --no-service     Nao instalar como servico systemd/openrc
#   --force          Forcar reinstalacao mesmo se a versao ja for igual
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Variaveis padrao
# ---------------------------------------------------------------------------
OCS_TAG="3.0.0-rc1"
BASE_DIR="/opt/ocsinventory"
BACKEND_URL=""
ADMIN_USER="ocsagentes"
ADMIN_PASS="PSWAgente"
INSTALL_SERVICE=1
FORCE_REINSTALL=0
GIT_AGENT_URL="https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework.git"

# Caminhos de instalacao conhecidos do agente
AGENT_BIN_PATHS="/usr/local/bin/ocsinventory-cli /usr/bin/ocsinventory-cli /opt/ocsinventory/bin/ocsinventory-cli"
AGENT_CONF_PATHS="/etc/ocsinventory /etc/ocsinventory-agent /opt/ocsinventory/agent"
AGENT_SERVICE_NAME="ocsinventory-agent"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'

info()    { printf "${GRN}[INFO]${NC}   %s\n" "$*"; }
warn()    { printf "${YEL}[AVISO]${NC}  %s\n" "$*" >&2; }
die()     { printf "${RED}[ERRO]${NC}   %s\n" "$*" >&2; exit 1; }
section() { printf "\n${BLU}>>> %s${NC}\n" "$*"; }

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --url)        BACKEND_URL="$2";    shift 2 ;;
    --tag)        OCS_TAG="$2";        shift 2 ;;
    --base)       BASE_DIR="$2";       shift 2 ;;
    --no-service) INSTALL_SERVICE=0;   shift ;;
    --force)      FORCE_REINSTALL=1;   shift ;;
    *) die "Opcao desconhecida: $1  Use: --url, --tag, --base, --no-service, --force" ;;
  esac
done

# ---------------------------------------------------------------------------
# Root
# ---------------------------------------------------------------------------
[ "$(id -u)" -ne 0 ] && die "Execute como root: sudo $0"

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
cat <<'EOF'
=======================================================
  OCS Inventory -- Instalador / Atualizador do Agente
=======================================================
EOF

# ---------------------------------------------------------------------------
# Detectar familia da distro
# ---------------------------------------------------------------------------
detect_distro() {
  PKG_FAMILY=""
  PKG_MGR=""
  DISTRO_NAME=""

  if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO_NAME="${PRETTY_NAME:-${NAME:-desconhecido}}"
    case "${ID:-} ${ID_LIKE:-}" in
      *debian*|*ubuntu*|*mint*|*pop*|*elementary*|*kali*|*raspbian*) PKG_FAMILY="debian" ;;
      *rhel*|*centos*|*fedora*|*rocky*|*alma*|*oracle*|*amzn*)       PKG_FAMILY="rhel"   ;;
      *suse*|*opensuse*)                                               PKG_FAMILY="suse"   ;;
      *arch*|*manjaro*|*endeavour*)                                    PKG_FAMILY="arch"   ;;
      *alpine*)                                                        PKG_FAMILY="alpine" ;;
    esac
  fi

  if [ -z "$PKG_FAMILY" ]; then
    command -v apt-get    >/dev/null 2>&1 && PKG_FAMILY="debian"    ||
    { command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; } && PKG_FAMILY="rhel" ||
    command -v zypper     >/dev/null 2>&1 && PKG_FAMILY="suse"      ||
    command -v pacman     >/dev/null 2>&1 && PKG_FAMILY="arch"      ||
    command -v apk        >/dev/null 2>&1 && PKG_FAMILY="alpine"    ||
    { command -v slackpkg >/dev/null 2>&1 || command -v installpkg >/dev/null 2>&1; } && PKG_FAMILY="slackware"
  fi

  [ -z "$PKG_FAMILY" ] && die "Nao foi possivel detectar a familia da distribuicao."

  case "$PKG_FAMILY" in
    debian)    PKG_MGR="apt-get" ;;
    rhel)      command -v dnf >/dev/null 2>&1 && PKG_MGR="dnf" || PKG_MGR="yum" ;;
    suse)      PKG_MGR="zypper" ;;
    arch)      PKG_MGR="pacman" ;;
    alpine)    PKG_MGR="apk" ;;
    slackware) PKG_MGR="slackpkg" ;;
  esac

  info "Sistema: ${DISTRO_NAME:-$PKG_FAMILY} (familia: $PKG_FAMILY, gerenciador: $PKG_MGR)"
}

# ---------------------------------------------------------------------------
# Instalar pacote (unificado)
# ---------------------------------------------------------------------------
pkg_install() {
  case "$PKG_FAMILY" in
    debian)
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    rhel)
      local stuck
      stuck=$(ps -eo pid,stat,comm 2>/dev/null | awk '/[Rr]pm/ && /D/{print $1}' || true)
      [ -n "$stuck" ] && { warn "Processo rpm travado (PID $stuck) -- matando."; kill -9 $stuck 2>/dev/null || true; sleep 2; }
      $PKG_MGR install -y "$@"
      ;;
    suse)      zypper install -y "$@" ;;
    arch)      pacman -Sy --noconfirm "$@" ;;
    alpine)    apk add --no-cache "$@" ;;
    slackware) slackpkg install "$@" 2>/dev/null || warn "slackpkg nao instalou $*; use installpkg manualmente." ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependencias base
# ---------------------------------------------------------------------------
install_base_deps() {
  section "Dependencias base"
  case "$PKG_FAMILY" in
    debian)
      apt-get update -qq
      pkg_install git curl unzip ca-certificates
      ;;
    rhel)
      rpm -q epel-release >/dev/null 2>&1 || $PKG_MGR install -y epel-release 2>/dev/null || true
      pkg_install git curl unzip ca-certificates
      ;;
    suse)
      zypper refresh
      pkg_install git curl unzip ca-certificates-mozilla
      ;;
    arch)
      pacman -Sy
      pkg_install git curl unzip ca-certificates
      ;;
    alpine)
      apk update
      pkg_install git curl unzip ca-certificates
      ;;
    slackware)
      pkg_install git curl
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Detectar versao instalada atual do agente
# ---------------------------------------------------------------------------
detect_installed_version() {
  INSTALLED_VERSION=""
  INSTALLED_BIN=""

  for path in $AGENT_BIN_PATHS; do
    if [ -f "$path" ]; then
      INSTALLED_BIN="$path"
      INSTALLED_VERSION=$("$path" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1 || true)
      break
    fi
  done

  # Fallback: procurar em qualquer lugar no PATH
  if [ -z "$INSTALLED_BIN" ] && command -v ocsinventory-cli >/dev/null 2>&1; then
    INSTALLED_BIN=$(command -v ocsinventory-cli)
    INSTALLED_VERSION=$(ocsinventory-cli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1 || true)
  fi
}

# ---------------------------------------------------------------------------
# Verificar se precisa atualizar
# ---------------------------------------------------------------------------
check_upgrade_needed() {
  section "Verificando versao instalada"
  detect_installed_version

  if [ -z "$INSTALLED_BIN" ]; then
    info "Nenhuma versao anterior encontrada -- instalacao nova."
    return 0
  fi

  info "Versao instalada : ${INSTALLED_VERSION:-desconhecida} em $INSTALLED_BIN"
  info "Versao desejada  : $OCS_TAG"

  if [ "$FORCE_REINSTALL" -eq 1 ]; then
    warn "--force especificado: reinstalando mesmo que a versao seja igual."
    remove_old_agent
    return 0
  fi

  # Normalizar: remover prefixo 'v' para comparacao
  local installed_norm desired_norm
  installed_norm=$(echo "$INSTALLED_VERSION" | sed 's/^v//')
  desired_norm=$(echo "$OCS_TAG" | sed 's/^v//')

  if [ "$installed_norm" = "$desired_norm" ]; then
    info "Versao $OCS_TAG ja esta instalada."
    printf "\n  Deseja reinstalar mesmo assim? [s/N]: "
    read -r resp
    case "$resp" in
      s|S|sim|y|Y|yes) remove_old_agent ;;
      *) info "Nenhuma alteracao feita. Use --force para forcar a reinstalacao."; exit 0 ;;
    esac
  else
    warn "Versao diferente detectada (${INSTALLED_VERSION:-?} -> $OCS_TAG). Removendo versao anterior..."
    remove_old_agent
  fi
}

# ---------------------------------------------------------------------------
# Remover versao anterior do agente
# ---------------------------------------------------------------------------
remove_old_agent() {
  section "Removendo versao anterior"

  # 1. Parar e desabilitar o servico
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-units --full --all 2>/dev/null | grep -q "${AGENT_SERVICE_NAME}.service"; then
      info "Parando servico $AGENT_SERVICE_NAME (systemd)..."
      systemctl stop "$AGENT_SERVICE_NAME" 2>/dev/null || true
      systemctl disable "$AGENT_SERVICE_NAME" 2>/dev/null || true
    fi
  fi

  if command -v rc-service >/dev/null 2>&1; then
    if rc-service "$AGENT_SERVICE_NAME" status >/dev/null 2>&1; then
      info "Parando servico $AGENT_SERVICE_NAME (OpenRC)..."
      rc-service "$AGENT_SERVICE_NAME" stop 2>/dev/null || true
      rc-update del "$AGENT_SERVICE_NAME" 2>/dev/null || true
    fi
  fi

  # 2. Remover arquivos do unit systemd
  for unit_path in \
      "/etc/systemd/system/${AGENT_SERVICE_NAME}.service" \
      "/usr/lib/systemd/system/${AGENT_SERVICE_NAME}.service" \
      "/lib/systemd/system/${AGENT_SERVICE_NAME}.service"; do
    if [ -f "$unit_path" ]; then
      info "Removendo unit: $unit_path"
      rm -f "$unit_path"
    fi
  done
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true

  # 3. Usar o uninstall.sh oficial se existir
  local agent_src="${BASE_DIR}/agent-src"
  if [ -f "${agent_src}/setup/linux/uninstall.sh" ]; then
    info "Executando desinstalador oficial (setup/linux/uninstall.sh)..."
    chmod +x "${agent_src}/setup/linux/uninstall.sh"
    "${agent_src}/setup/linux/uninstall.sh" --silent 2>/dev/null || true
  fi

  # 4. Remover binarios conhecidos
  for bin in $AGENT_BIN_PATHS; do
    if [ -f "$bin" ]; then
      info "Removendo binario: $bin"
      rm -f "$bin"
    fi
  done

  # 5. Remover arquivos de configuracao
  for conf in $AGENT_CONF_PATHS; do
    if [ -d "$conf" ]; then
      info "Removendo configuracao: $conf"
      rm -rf "$conf"
    fi
  done

  # 6. Remover logs antigos (opcional -- preserva historico se o diretorio existir)
  # rm -rf /var/log/ocsinventory-agent  # descomente para limpar logs tambem

  # 7. Limpar codigo-fonte compilado (sera re-clonado)
  if [ -d "$agent_src" ]; then
    info "Removendo fonte compilada anterior: $agent_src"
    rm -rf "$agent_src"
  fi

  info "Versao anterior removida com sucesso."
}

# ---------------------------------------------------------------------------
# Dart SDK
# ---------------------------------------------------------------------------
install_dart() {
  section "Dart SDK"

  if command -v dart >/dev/null 2>&1; then
    info "Dart SDK ja instalado: $(dart --version 2>&1 | head -1)"
    return 0
  fi

  info "Instalando Dart SDK..."

  case "$PKG_FAMILY" in
    debian)
      if curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub \
           | gpg --dearmor -o /usr/share/keyrings/dart.gpg 2>/dev/null; then
        echo "deb [signed-by=/usr/share/keyrings/dart.gpg] https://storage.googleapis.com/download.dartlang.org/linux/debian stable main" \
          > /etc/apt/sources.list.d/dart_stable.list
        apt-get update -qq
        pkg_install dart 2>/dev/null && return 0
      fi
      ;;
    arch)
      pacman -Sy --noconfirm dart 2>/dev/null && return 0
      ;;
  esac

  # Fallback universal: download SDK standalone
  info "Baixando Dart SDK standalone..."
  local dart_zip="/tmp/dart-sdk.zip"
  local sys_arch dart_arch
  sys_arch=$(uname -m)
  case "$sys_arch" in
    aarch64|arm64) dart_arch="arm64" ;;
    armv7*)        dart_arch="arm"   ;;
    *)             dart_arch="x64"   ;;
  esac

  local dart_url="https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${dart_arch}-release.zip"
  curl -fsSL "$dart_url" -o "$dart_zip" || die "Falha ao baixar Dart SDK."
  rm -rf /opt/dart-sdk
  unzip -q "$dart_zip" -d /opt
  rm -f "$dart_zip"
  ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
  ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true

  command -v dart >/dev/null 2>&1 || die "Falha ao instalar Dart SDK."
  info "Dart SDK instalado: $(dart --version 2>&1 | head -1)"
}

# ---------------------------------------------------------------------------
# Perguntas interativas
# ---------------------------------------------------------------------------
ask_backend_url() {
  [ -n "$BACKEND_URL" ] && return 0
  printf "\n  URL do backend OCS Inventory (ex.: http://10.24.22.90:8000): "
  read -r input_url
  [ -z "$input_url" ] && die "URL do backend e obrigatoria."
  BACKEND_URL="${input_url%/}"
}

# Credenciais do agente fixas (usuario de servico dedicado, grupo admin)
# Para alterar: edite ADMIN_USER e ADMIN_PASS no topo deste script.
ask_credentials() { :; }

# ---------------------------------------------------------------------------
# Clonar repositorio
# ---------------------------------------------------------------------------
clone_agent() {
  # Usa variavel global AGENT_SRC (nao command substitution) para evitar
  # que info()/section() sejam capturados junto com o caminho.
  AGENT_SRC="${BASE_DIR}/agent-src"
  section "Codigo-fonte do agente"
  mkdir -p "$BASE_DIR"

  if [ -d "${AGENT_SRC}/.git" ]; then
    info "Repositorio existente -- buscando tag ${OCS_TAG}..."
    # Garantir que o dono seja o usuario atual (root) ou adicionar safe.directory
    # para evitar "dubious ownership" quando o diretorio foi criado por outro usuario
    git config --global --add safe.directory "$AGENT_SRC" 2>/dev/null || true
    git -C "$AGENT_SRC" fetch --tags --quiet
    git -C "$AGENT_SRC" checkout "$OCS_TAG" --quiet 2>/dev/null       || git -C "$AGENT_SRC" checkout main --quiet
  else
    info "Clonando repositorio (tag ${OCS_TAG})..."
    git clone --depth 1 --branch "$OCS_TAG" "$GIT_AGENT_URL" "$AGENT_SRC" 2>/dev/null       || { git clone "$GIT_AGENT_URL" "$AGENT_SRC"; git -C "$AGENT_SRC" checkout "$OCS_TAG" 2>/dev/null || true; }
  fi
}

# ---------------------------------------------------------------------------
# Compilar
# ---------------------------------------------------------------------------
build_agent() {
  section "Compilando agente"
  cd "$AGENT_SRC"
  dart pub get
  dart compile exe lib/app/app.dart -o ocsinventory-cli
  info "Binario: ${AGENT_SRC}/ocsinventory-cli"
}

# ---------------------------------------------------------------------------
# Instalar via script oficial
# ---------------------------------------------------------------------------
run_agent_installer() {
  section "Instalando agente"
  cp "${AGENT_SRC}/ocsinventory-cli" "${AGENT_SRC}/setup/linux/"
  chmod +x "${AGENT_SRC}/setup/linux/install.sh" "${AGENT_SRC}/setup/linux/uninstall.sh"

  local service_flag=""
  [ "$INSTALL_SERVICE" -eq 1 ] && service_flag="--service --now"

  # shellcheck disable=SC2086
  cd "${AGENT_SRC}/setup/linux" && ./install.sh     --silent     --url "$BACKEND_URL"     --username "$ADMIN_USER"     --password "$ADMIN_PASS"     --mode 1     --log-level 3     $service_flag
}

# ---------------------------------------------------------------------------
# Verificar resultado
# ---------------------------------------------------------------------------
verify_install() {
  section "Verificando instalacao"
  detect_installed_version

  if [ -n "$INSTALLED_BIN" ]; then
    info "Agente instalado: ${INSTALLED_VERSION:-versao nao disponivel} em $INSTALLED_BIN"
  else
    warn "Binario do agente nao encontrado no PATH apos instalacao."
  fi

  if [ "$INSTALL_SERVICE" -eq 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$AGENT_SERVICE_NAME" 2>/dev/null; then
      info "Servico $AGENT_SERVICE_NAME: ATIVO"
    elif command -v rc-service >/dev/null 2>&1 && rc-service "$AGENT_SERVICE_NAME" status >/dev/null 2>&1; then
      info "Servico $AGENT_SERVICE_NAME (OpenRC): ATIVO"
    else
      warn "Servico nao detectado como ativo. Verifique: systemctl status $AGENT_SERVICE_NAME"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
detect_distro
install_base_deps
check_upgrade_needed    # detecta versao anterior e remove se necessario
install_dart
ask_backend_url

info "Configuracao:"
info "  Backend : $BACKEND_URL"
info "  Usuario : $ADMIN_USER (conta de servico dedicada)"
info "  Versao  : $OCS_TAG"
printf "\n"

clone_agent
build_agent
run_agent_installer
verify_install

printf "\n"
info "Concluido. O agente se reportara para: $BACKEND_URL"
[ "$INSTALL_SERVICE" -eq 1 ] && info "Status: systemctl status $AGENT_SERVICE_NAME"