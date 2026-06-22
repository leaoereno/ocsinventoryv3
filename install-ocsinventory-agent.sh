#!/usr/bin/env sh
# =============================================================================
# install-ocsinventory-agent.sh
#
# Instala o agente OCS Inventory 3.0 em qualquer distro Linux/Unix.
# Antes de instalar, faz uma VARREDURA COMPLETA e remove qualquer versao
# anterior -- tanto agentes v2.x (Perl/UNIX legados) quanto agentes v3.x
# (Dart), incluindo pacotes RPM/DEB, binarios avulsos, servicos systemd/
# init.d/OpenRC, arquivos de configuracao e dados de inventario local.
#
# Familias suportadas:
#   Debian / Ubuntu / Mint / Kali / Raspbian   (apt)
#   RHEL / AlmaLinux / Rocky / Fedora / Oracle (dnf / yum)
#   openSUSE / SLES                            (zypper)
#   Alpine Linux                               (apk)
#   Arch Linux / Manjaro / EndeavourOS         (pacman)
#   Slackware                                  (slackpkg / installpkg)
#
# Uso:
#   sudo ./install-ocsinventory-agent.sh [opcoes]
#
# Opcoes:
#   --url  URL   URL do backend/relay (ex.: http://IP:8000 ou http://IP)
#   --tag  TAG   Tag git do agente (padrao: 3.0.0-rc1)
#   --base DIR   Diretorio base (padrao: /opt/ocsinventory)
#   --no-service Nao instalar como servico systemd/OpenRC
#   --force      Reinstalar mesmo se a versao ja for igual
# =============================================================================
set -e

# ---------------------------------------------------------------------------
# Configuracao
# ---------------------------------------------------------------------------
OCS_TAG="3.0.0-rc1"
BASE_DIR="/opt/ocsinventory"
BACKEND_URL=""
ADMIN_USER="ocsagentes"
ADMIN_PASS="PSWAgente"
INSTALL_SERVICE=1
FORCE_REINSTALL=0
GIT_AGENT_URL="https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework.git"
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
    --url)        BACKEND_URL="$2"; shift 2 ;;
    --tag)        OCS_TAG="$2";     shift 2 ;;
    --base)       BASE_DIR="$2";    shift 2 ;;
    --no-service) INSTALL_SERVICE=0; shift ;;
    --force)      FORCE_REINSTALL=1; shift ;;
    *) die "Opcao desconhecida: $1  Use: --url, --tag, --base, --no-service, --force" ;;
  esac
done

[ "$(id -u)" -ne 0 ] && die "Execute como root: sudo $0"

cat <<'EOF'
=======================================================
  OCS Inventory 3.0 -- Instalador do Agente (Linux)
  Varredura completa de versoes anteriores incluida
=======================================================
EOF

# ---------------------------------------------------------------------------
# Detectar familia da distro
# ---------------------------------------------------------------------------
detect_distro() {
  PKG_FAMILY=""; PKG_MGR=""; DISTRO_NAME=""
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
    command -v apt-get >/dev/null 2>&1 && PKG_FAMILY="debian" ||
    { command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; } && PKG_FAMILY="rhel" ||
    command -v zypper >/dev/null 2>&1 && PKG_FAMILY="suse" ||
    command -v pacman >/dev/null 2>&1 && PKG_FAMILY="arch" ||
    command -v apk >/dev/null 2>&1 && PKG_FAMILY="alpine" ||
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
# Instalar pacote
# ---------------------------------------------------------------------------
pkg_install() {
  case "$PKG_FAMILY" in
    debian)    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    rhel)
      local stuck
      stuck=$(ps -eo pid,stat,comm 2>/dev/null | awk '/[Rr]pm/ && /D/{print $1}' || true)
      [ -n "$stuck" ] && { warn "Processo rpm travado (PID $stuck) -- matando."; kill -9 $stuck 2>/dev/null || true; sleep 2; }
      $PKG_MGR install -y "$@"
      ;;
    suse)      zypper install -y "$@" ;;
    arch)      pacman -Sy --noconfirm "$@" ;;
    alpine)    apk add --no-cache "$@" ;;
    slackware) slackpkg install "$@" 2>/dev/null || warn "Use installpkg manualmente para $*." ;;
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
# VARREDURA E REMOCAO COMPLETA DE AGENTES ANTERIORES
# Cobre agentes v2.x (Perl, pacote ocsinventory-agent) e v3.x (Dart)
# instalados por qualquer metodo: pacote, binario avulso ou fonte.
# ---------------------------------------------------------------------------
remove_all_old_agents() {
  section "Varredura e remocao de agentes anteriores"

  # ---- 1. Parar todos os servicos relacionados ao OCS ----
  info "Parando servicos OCS..."
  for svc in ocsinventory-agent ocsinventory ocs-agent ocsinventory-agent-ng; do
    if command -v systemctl >/dev/null 2>&1; then
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
    fi
    if command -v rc-service >/dev/null 2>&1; then
      rc-service "$svc" stop 2>/dev/null || true
      rc-update del "$svc" 2>/dev/null || true
    fi
    if [ -f "/etc/init.d/$svc" ]; then
      "/etc/init.d/$svc" stop 2>/dev/null || true
      command -v chkconfig >/dev/null 2>&1 && chkconfig "$svc" off 2>/dev/null || true
      command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$svc" remove 2>/dev/null || true
    fi
  done

  # ---- 2. Remover pacotes instalados pelo gerenciador de pacotes ----
  info "Removendo pacotes OCS do gerenciador de pacotes..."
  case "$PKG_FAMILY" in
    debian)
      # v2.x: ocsinventory-agent, libocsinventory-agent-perl, etc.
      # v3.x: pode ter sido instalado como .deb avulso
      DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
        ocsinventory-agent \
        ocsinventory-agent-ng \
        libocsinventory-agent-perl \
        2>/dev/null || true
      apt-get autoremove -y 2>/dev/null || true
      ;;
    rhel)
      $PKG_MGR remove -y \
        ocsinventory-agent \
        ocsinventory-agent-ng \
        perl-OCSInventory-Agent \
        2>/dev/null || true
      ;;
    suse)
      zypper remove -y ocsinventory-agent ocsinventory-agent-ng 2>/dev/null || true
      ;;
    arch)
      pacman -Rns --noconfirm ocsinventory-agent 2>/dev/null || true
      ;;
    alpine)
      apk del ocsinventory-agent 2>/dev/null || true
      ;;
  esac

  # ---- 3. Matar processos residuais ----
  # Excluir o PID atual ($$) e o pai (PPID) para nao matar o proprio script,
  # cujo nome contem "ocsinventory-agent" e seria matched pelo pkill -f.
  info "Matando processos OCS residuais..."
  local my_pid my_ppid
  my_pid=$$
  my_ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ' || echo 0)
  # Matar binarios do agente (nao o shell que roda este script)
  for pattern in "ocsinventory-cli" "ocsinventory-agent.pl" "OCSInventory-Agent"; do
    pgrep -f "$pattern" 2>/dev/null | while read -r pid; do
      [ "$pid" = "$my_pid" ] || [ "$pid" = "$my_ppid" ] && continue
      info "  Matando PID $pid ($pattern)"
      kill -9 "$pid" 2>/dev/null || true
    done
  done
  # Para o servico systemd pelo nome (sem pkill -f)
  command -v systemctl >/dev/null 2>&1 && systemctl kill ocsinventory-agent 2>/dev/null || true
  sleep 1

  # ---- 4. Remover units systemd e drop-ins ----
  info "Removendo units systemd..."
  for unit_dir in \
      /etc/systemd/system \
      /usr/lib/systemd/system \
      /lib/systemd/system; do
    [ -d "$unit_dir" ] || continue
    for svc in ocsinventory-agent ocsinventory ocs-agent ocsinventory-agent-ng; do
      rm -f "${unit_dir}/${svc}.service" 2>/dev/null || true
      rm -rf "${unit_dir}/${svc}.service.d" 2>/dev/null || true
    done
  done
  # Remover symlinks de multi-user.target.wants
  find /etc/systemd/system /usr/lib/systemd/system \
    -name "*ocsinventory*" -o -name "*ocs-agent*" 2>/dev/null | \
    xargs rm -f 2>/dev/null || true
  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true

  # ---- 5. Remover scripts init.d e OpenRC ----
  info "Removendo scripts de init..."
  for svc in ocsinventory-agent ocsinventory ocs-agent; do
    rm -f "/etc/init.d/$svc" 2>/dev/null || true
    rm -f "/etc/rc.d/init.d/$svc" 2>/dev/null || true
    rm -f "/etc/runlevels/default/$svc" 2>/dev/null || true
    rm -f "/etc/runlevels/boot/$svc" 2>/dev/null || true
  done

  # ---- 6. Remover binarios em todos os locais conhecidos ----
  info "Removendo binarios..."
  for bin in \
      /usr/bin/ocsinventory-agent \
      /usr/bin/ocsinventory-cli \
      /usr/bin/ocsinventory-agent.pl \
      /usr/local/bin/ocsinventory-agent \
      /usr/local/bin/ocsinventory-cli \
      /usr/local/bin/ocsinventory-agent.pl \
      /opt/ocsinventory/bin/ocsinventory-cli \
      /opt/ocsinventory-agent/ocsinventory-agent \
      /opt/OCSInventory-Agent/ocsinventory-agent \
      /opt/ocsinventory/agent-src/ocsinventory-cli; do
    [ -f "$bin" ] && { info "  Removendo: $bin"; rm -f "$bin"; }
  done
  # Busca adicional por binarios avulsos no PATH
  for bin_name in ocsinventory-agent ocsinventory-cli ocsinventory-agent.pl; do
    found=$(command -v "$bin_name" 2>/dev/null || true)
    [ -n "$found" ] && { info "  Removendo: $found"; rm -f "$found"; }
  done

  # ---- 7. Remover modulos Perl do agente v2.x ----
  info "Removendo modulos Perl OCS (v2.x)..."
  for perl_dir in \
      /usr/share/ocsinventory-agent \
      /usr/lib/ocsinventory-agent \
      /usr/local/share/ocsinventory-agent \
      /opt/OCSInventory-Agent \
      /opt/ocsinventory-agent; do
    [ -d "$perl_dir" ] && { info "  Removendo: $perl_dir"; rm -rf "$perl_dir"; }
  done

  # ---- 8. Remover configuracoes -- v2.x e v3.x ----
  info "Removendo configuracoes..."
  for conf_dir in \
      /etc/ocsinventory \
      /etc/ocsinventory-agent \
      /etc/ocsinventory-ng \
      /usr/local/etc/ocsinventory-agent \
      /opt/ocsinventory/agent; do
    [ -d "$conf_dir" ] && { info "  Removendo: $conf_dir"; rm -rf "$conf_dir"; }
  done

  # ---- 9. Remover dados de inventario local ----
  info "Removendo dados de inventario local..."
  for data_dir in \
      /var/lib/ocsinventory-agent \
      /var/lib/ocsinventory \
      /var/lib/ocsinventory-data \
      /var/cache/ocsinventory-agent \
      /var/cache/ocsinventory; do
    [ -d "$data_dir" ] && { info "  Removendo: $data_dir"; rm -rf "$data_dir"; }
  done

  # ---- 10. Remover logs antigos ----
  info "Removendo logs antigos..."
  for log in \
      /var/log/ocsinventory-agent \
      /var/log/ocsinventory \
      /var/log/OCSInventory.log \
      /var/log/ocsinventory-agent.log; do
    [ -e "$log" ] && { info "  Removendo: $log"; rm -rf "$log"; }
  done

  # ---- 11. Remover repositorio compilado v3.x ----
  local agent_src="${BASE_DIR}/agent-src"
  if [ -d "$agent_src" ]; then
    info "Removendo fonte compilada: $agent_src"
    rm -rf "$agent_src"
  fi

  # ---- 12. Remover entradas de cron ----
  info "Verificando entradas de cron..."
  for cron_file in \
      /etc/cron.d/ocsinventory-agent \
      /etc/cron.daily/ocsinventory-agent \
      /etc/cron.hourly/ocsinventory-agent; do
    [ -f "$cron_file" ] && { info "  Removendo: $cron_file"; rm -f "$cron_file"; }
  done
  # Remover linhas de crontab do root
  if command -v crontab >/dev/null 2>&1; then
    crontab -l 2>/dev/null | grep -v "ocsinventory" | crontab - 2>/dev/null || true
  fi

  info "Varredura concluida -- sistema limpo para instalacao do agente 3.0."
}

# ---------------------------------------------------------------------------
# Verificar versao instalada (v3.x Dart)
# ---------------------------------------------------------------------------
detect_installed_version() {
  INSTALLED_VERSION=""
  INSTALLED_BIN=""
  for path in /usr/bin/ocsinventory-cli /usr/local/bin/ocsinventory-cli; do
    if [ -f "$path" ]; then
      INSTALLED_BIN="$path"
      INSTALLED_VERSION=$("$path" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1 || true)
      break
    fi
  done
  if [ -z "$INSTALLED_BIN" ] && command -v ocsinventory-cli >/dev/null 2>&1; then
    INSTALLED_BIN=$(command -v ocsinventory-cli)
    INSTALLED_VERSION=$(ocsinventory-cli --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1 || true)
  fi
}

# ---------------------------------------------------------------------------
# Decidir se precisa remover
# ---------------------------------------------------------------------------
check_and_remove() {
  section "Verificando versoes anteriores"

  # Verificar agente v2.x (Perl)
  local has_v2=0
  for v2bin in \
      /usr/bin/ocsinventory-agent \
      /usr/local/bin/ocsinventory-agent \
      /opt/OCSInventory-Agent/ocsinventory-agent; do
    [ -f "$v2bin" ] && { has_v2=1; warn "Agente v2.x encontrado: $v2bin"; break; }
  done
  # Verificar por pacote RPM/DEB
  case "$PKG_FAMILY" in
    rhel)   rpm -q ocsinventory-agent 2>/dev/null | grep -qv "not installed" && has_v2=1 || true ;;
    debian) dpkg -l ocsinventory-agent 2>/dev/null | grep -q "^ii" && has_v2=1 || true ;;
  esac

  detect_installed_version

  if [ "$has_v2" -eq 0 ] && [ -z "$INSTALLED_BIN" ]; then
    info "Nenhuma versao anterior encontrada -- instalacao limpa."
    return 0
  fi

  if [ -n "$INSTALLED_BIN" ]; then
    info "Agente v3.x encontrado: ${INSTALLED_VERSION:-versao desconhecida} em $INSTALLED_BIN"
  fi
  if [ "$has_v2" -eq 1 ]; then
    warn "Agente v2.x (legado Perl) encontrado -- sera removido completamente."
  fi

  if [ "$FORCE_REINSTALL" -eq 0 ] && [ "$has_v2" -eq 0 ]; then
    local installed_norm desired_norm
    installed_norm=$(echo "$INSTALLED_VERSION" | sed 's/^v//')
    desired_norm=$(echo "$OCS_TAG" | sed 's/^v//')
    if [ "$installed_norm" = "$desired_norm" ]; then
      printf "\n  Versao %s ja esta instalada. Reinstalar? [s/N]: " "$OCS_TAG"
      read -r resp
      case "$resp" in
        s|S|sim|y|Y|yes) : ;;
        *) info "Nenhuma alteracao. Use --force para reinstalar."; exit 0 ;;
      esac
    fi
  fi

  remove_all_old_agents
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
  info "Baixando Dart SDK standalone..."
  local dart_zip="/tmp/dart-sdk.zip" dart_arch
  case "$(uname -m)" in
    aarch64|arm64) dart_arch="arm64" ;;
    armv7*)        dart_arch="arm" ;;
    *)             dart_arch="x64" ;;
  esac
  curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${dart_arch}-release.zip" \
    -o "$dart_zip" || die "Falha ao baixar Dart SDK."
  rm -rf /opt/dart-sdk
  unzip -q "$dart_zip" -d /opt
  rm -f "$dart_zip"
  ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
  ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true
  command -v dart >/dev/null 2>&1 || die "Falha ao instalar Dart SDK."
  info "Dart SDK instalado: $(dart --version 2>&1 | head -1)"
}

# ---------------------------------------------------------------------------
# URL do backend
# ---------------------------------------------------------------------------
ask_backend_url() {
  [ -n "$BACKEND_URL" ] && return 0
  printf "\n  URL do backend OCS Inventory (ex.: http://IP:8000 ou http://IP): "
  read -r input_url
  [ -z "$input_url" ] && die "URL do backend e obrigatoria."
  BACKEND_URL="${input_url%/}"
}

# Credenciais fixas (conta de servico dedicada)
ask_credentials() { :; }

# ---------------------------------------------------------------------------
# Clonar repositorio
# ---------------------------------------------------------------------------
clone_agent() {
  AGENT_SRC="${BASE_DIR}/agent-src"
  section "Codigo-fonte do agente"
  mkdir -p "$BASE_DIR"
  if [ -d "${AGENT_SRC}/.git" ]; then
    info "Repositorio existente -- atualizando para tag ${OCS_TAG}..."
    git config --global --add safe.directory "$AGENT_SRC" 2>/dev/null || true
    git -C "$AGENT_SRC" fetch --tags --quiet
    git -C "$AGENT_SRC" checkout "$OCS_TAG" --quiet 2>/dev/null \
      || git -C "$AGENT_SRC" checkout main --quiet
  else
    info "Clonando repositorio (tag ${OCS_TAG})..."
    git clone --depth 1 --branch "$OCS_TAG" "$GIT_AGENT_URL" "$AGENT_SRC" 2>/dev/null \
      || { git clone "$GIT_AGENT_URL" "$AGENT_SRC"
           git -C "$AGENT_SRC" checkout "$OCS_TAG" 2>/dev/null || true; }
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
# Instalar, configurar e registrar o servico
# ---------------------------------------------------------------------------
run_agent_installer() {
  section "Instalando agente"
  cp "${AGENT_SRC}/ocsinventory-cli" "${AGENT_SRC}/setup/linux/"
  chmod +x "${AGENT_SRC}/setup/linux/install.sh" "${AGENT_SRC}/setup/linux/uninstall.sh"

  local service_flag=""
  [ "$INSTALL_SERVICE" -eq 1 ] && service_flag="--service --now"

  # shellcheck disable=SC2086
  cd "${AGENT_SRC}/setup/linux" && ./install.sh \
    --silent \
    --url "$BACKEND_URL" \
    --username "$ADMIN_USER" \
    --password "$ADMIN_PASS" \
    --mode 1 \
    --log-level 2 \
    $service_flag

  # Sobrescrever config.json com a URL correta.
  # O install.sh pode nao sobrescrever um config.json existente (diz
  # "override for this run only"), mantendo a URL de uma instalacao anterior.
  local cfg_dir="/etc/ocsinventory-agent"
  mkdir -p "$cfg_dir" /var/log/ocsinventory-agent /var/lib/ocsinventory-data
  info "Gravando ${cfg_dir}/config.json com URL: ${BACKEND_URL}"
  cat > "${cfg_dir}/config.json" << CFGEOF
{
  "url": "${BACKEND_URL}",
  "username": "${ADMIN_USER}",
  "password": "${ADMIN_PASS}",
  "mode": 1,
  "log_level": 2,
  "log_file": true,
  "log_file_path": "/var/log/ocsinventory-agent/ocsinventory-agent.log",
  "data_directory": "/var/lib/ocsinventory-data",
  "certificate": "none",
  "bypass-certificate": false
}
CFGEOF

  # Criar override systemd para injetar parametros na unit gerada pelo
  # install.sh (que usa apenas "--service true" sem URL/credenciais).
  if [ "$INSTALL_SERVICE" -eq 1 ] && command -v systemctl >/dev/null 2>&1; then
    local override_dir="/etc/systemd/system/ocsinventory-agent.service.d"
    mkdir -p "$override_dir"
    info "Criando override systemd com URL: ${BACKEND_URL}"
    cat > "${override_dir}/ocs-params.conf" << EOF
[Service]
ExecStart=
ExecStart=/usr/bin/ocsinventory-cli \\
  --service true \\
  --url ${BACKEND_URL} \\
  --username ${ADMIN_USER} \\
  --password ${ADMIN_PASS} \\
  --mode 1 \\
  --log_level 2 \\
  --log_file true \\
  --log_file_path /var/log/ocsinventory-agent/ocsinventory-agent.log
EOF
    systemctl daemon-reload
    systemctl restart ocsinventory-agent 2>/dev/null || true
    info "Servico reiniciado com os parametros corretos."
  fi
}

# ---------------------------------------------------------------------------
# Verificar resultado
# ---------------------------------------------------------------------------
verify_install() {
  section "Verificando instalacao"
  detect_installed_version

  if [ -n "$INSTALLED_BIN" ]; then
    info "Agente v3.0 instalado: ${INSTALLED_VERSION:-versao nao disponivel} em $INSTALLED_BIN"
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

  # Confirmacao final: verificar que nao resta nenhum agente v2.x
  local v2_residual=0
  for v2bin in /usr/bin/ocsinventory-agent /usr/local/bin/ocsinventory-agent; do
    [ -f "$v2bin" ] && { warn "Residual v2.x ainda presente: $v2bin"; v2_residual=1; }
  done
  [ "$v2_residual" -eq 0 ] && info "Sem residuos de agente v2.x detectados."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
detect_distro
install_base_deps
check_and_remove
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