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
BUNDLE_DIR=""           # caminho do bundle offline; auto-detectado se vazio
INSTALL_LOG="/var/log/ocsinventory-install.log"   # log persistente da instalação
AGENT_TAG=""            # tag de identificação do ativo no console (ex.: ITSM-DEVOPS)
AGENT_SERVICE_NAME="ocsinventory-agent"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
info()    { printf "${GRN}[INFO]${NC}   %s\n" "$*"; echo "[INFO]  $*" >> "${INSTALL_LOG}" 2>/dev/null || true; }
warn()    { printf "${YEL}[AVISO]${NC}  %s\n" "$*" >&2; echo "[AVISO] $*" >> "${INSTALL_LOG}" 2>/dev/null || true; }
die()     { printf "${RED}[ERRO]${NC}   %s\n" "$*" >&2; echo "[ERRO]  $*" >> "${INSTALL_LOG}" 2>/dev/null || true; exit 1; }
ok()      { printf "${GRN}  ✓${NC} %s\n" "$*"; echo "[OK]    $*" >> "${INSTALL_LOG}" 2>/dev/null || true; }
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
    --bundle-dir) BUNDLE_DIR="$2"; shift 2 ;;
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
# BUNDLE OFFLINE — detecção automática e fallback de internet
# ---------------------------------------------------------------------------

detect_bundle() {
  [ -n "$BUNDLE_DIR" ] && [ -f "${BUNDLE_DIR}/bundle.manifest" ] && return 0
  for dir in "./ocs-bundle" "../ocs-bundle" "/opt/ocs-bundle" "$(dirname "$0")/ocs-bundle"; do
    if [ -d "$dir" ] && [ -f "${dir}/bundle.manifest" ]; then
      BUNDLE_DIR="$dir"
      info "Bundle offline detectado: $BUNDLE_DIR"
      return 0
    fi
  done
  return 1
}

check_internet_host() {
  timeout 5 bash -c "echo >/dev/tcp/${1}/${2:-443}" 2>/dev/null
}

INTERNET_GITHUB=0
INTERNET_DART=0

probe_internet_agent() {
  info "Verificando conectividade de internet..."
  check_internet_host "github.com" 443    && INTERNET_GITHUB=1 && info "  GitHub     : OK" || warn "  GitHub     : indisponivel"
  check_internet_host "storage.googleapis.com" 443 && INTERNET_DART=1 && info "  Dart SDK   : OK" || warn "  Dart SDK   : indisponivel"
}

# Clone com fallback para bundle
clone_agent_with_fallback() {
  local bundle_file="${BUNDLE_DIR}/repos/agent.bundle"

  if [ -d "${AGENT_SRC}/.git" ]; then
    git config --global --add safe.directory "$AGENT_SRC" 2>/dev/null || true
    if [ "$INTERNET_GITHUB" -eq 1 ]; then
      info "Atualizando repositorio do agente via internet..."
      git -C "$AGENT_SRC" fetch --tags --quiet 2>/dev/null || true
      git -C "$AGENT_SRC" checkout "$OCS_TAG" --quiet 2>/dev/null || true
    else
      info "Usando repositorio existente (sem internet)."
    fi
    return 0
  fi

  if [ "$INTERNET_GITHUB" -eq 1 ]; then
    info "Clonando agente via internet (tag ${OCS_TAG})..."
    if git clone --depth 1 --branch "$OCS_TAG" "$GIT_AGENT_URL" "$AGENT_SRC" 2>/dev/null; then
      ok "Agente clonado via internet."
      return 0
    fi
    warn "Clone falhou — tentando bundle offline..."
  fi

  if [ -n "$BUNDLE_DIR" ] && [ -f "$bundle_file" ]; then
    info "Restaurando agente do bundle offline..."
    git clone "$bundle_file" "$AGENT_SRC" 2>/dev/null
    git -C "$AGENT_SRC" checkout "$OCS_TAG" 2>/dev/null || true
    ok "Agente restaurado do bundle offline."
    return 0
  fi

  die "Nao foi possivel obter o codigo do agente: sem internet e sem bundle offline."
}

# Dart SDK com fallback para bundle
install_dart_agent() {
  if command -v dart >/dev/null 2>&1; then
    info "Dart SDK ja instalado: $(dart --version 2>&1 | head -1)"
    return 0
  fi

  local dart_arch dart_zip
  case "$(uname -m)" in
    aarch64|arm64) dart_arch="arm64" ;;
    armv7*)        dart_arch="arm" ;;
    *)             dart_arch="x64" ;;
  esac

  # Tentar via internet
  if [ "$INTERNET_DART" -eq 1 ]; then
    info "Baixando Dart SDK via internet..."
    dart_zip="/tmp/dart-sdk-$$.zip"
    if curl -fsSL --max-time 600         "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${dart_arch}-release.zip"         -o "$dart_zip"; then
      rm -rf /opt/dart-sdk
      unzip -q "$dart_zip" -d /opt
      rm -f "$dart_zip"
      ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
      ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true
      command -v dart >/dev/null 2>&1 && { ok "Dart SDK instalado via internet."; return 0; }
    fi
    warn "Download falhou — tentando bundle offline..."
  fi

  # Fallback: bundle (SDK já extraído)
  if [ -n "$BUNDLE_DIR" ] && [ -d "${BUNDLE_DIR}/dart/dart-sdk" ]; then
    info "Instalando Dart SDK do bundle offline..."
    cp -r "${BUNDLE_DIR}/dart/dart-sdk" /opt/dart-sdk
    ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
    ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true
    command -v dart >/dev/null 2>&1 && { ok "Dart SDK instalado do bundle."; return 0; }
  fi

  # Fallback: bundle (zip)
  if [ -n "$BUNDLE_DIR" ]; then
    local bundle_zip
    bundle_zip=$(find "$BUNDLE_DIR/dart" -name "dartsdk-linux-${dart_arch}-*.zip" 2>/dev/null | head -1)
    if [ -n "$bundle_zip" ]; then
      info "Extraindo Dart SDK do bundle (zip)..."
      rm -rf /opt/dart-sdk
      unzip -q "$bundle_zip" -d /opt
      ln -sf /opt/dart-sdk/bin/dart /usr/local/bin/dart
      ln -sf /opt/dart-sdk/bin/dartaotruntime /usr/local/bin/dartaotruntime 2>/dev/null || true
      command -v dart >/dev/null 2>&1 && { ok "Dart SDK instalado do bundle."; return 0; }
    fi
  fi

  die "Nao foi possivel instalar o Dart SDK: sem internet e sem bundle offline."
}

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Exibe os IPs da maquina e testa conectividade com cada relay da lista
# ---------------------------------------------------------------------------
show_network_info() {
  section "Informacoes de rede desta maquina"

  # Listar todas as interfaces e IPs
  info "Interfaces de rede detectadas:"
  printf "  %-20s %-18s %s\n" "Interface" "IP" "MAC"
  printf "  %s\n" "------------------------------------------------------"
  ip -o addr show 2>/dev/null | grep "inet " | while read -r line; do
    local iface ip_cidr ip mac
    iface=$(echo "$line" | awk '{print $2}')
    ip_cidr=$(echo "$line" | awk '{print $4}')
    ip="${ip_cidr%%/*}"
    mac=$(ip link show "$iface" 2>/dev/null | awk '/ether/{print $2}')
    [ "$iface" = "lo" ] && continue
    printf "  %-20s %-18s %s\n" "$iface" "$ip" "${mac:--}"
  done

  echo ""
  info "Testando conectividade com os relays OCS conhecidos..."
  printf "  %-6s %-22s %-22s %s\n" "Opcao" "IP" "Site" "Status"
  printf "  %s\n" "---------------------------------------------------------------"

  echo "$OCS_RELAYS" | grep -v "^[[:space:]]*$" | while IFS="|" read -r num ip desc; do
    num=$(echo "$num" | tr -d ' ')
    ip=$(echo "$ip"   | tr -d ' ')
    desc=$(echo "$desc" | sed 's/^ *//')
    [ -z "$ip" ] && continue

    local status color
    if timeout 3 bash -c "echo >/dev/tcp/${ip}/80" 2>/dev/null; then
      status="ALCANCAVEL :80"
      color="${GRN}"
    elif timeout 3 bash -c "echo >/dev/tcp/${ip}/8000" 2>/dev/null; then
      status="ALCANCAVEL :8000"
      color="${GRN}"
    else
      status="INACESSIVEL"
      color="${RED}"
    fi

    printf "  [%2s] %-22s %-22s %b%s%b\n" "$num" "$ip" "$desc" "$color" "$status" "$NC"
  done

  echo ""
  warn "Se nenhum relay aparecer como ALCANCAVEL, verifique as regras de firewall/Guardicore."
  warn "O agente NAO conseguira se registrar se a porta estiver bloqueada."
  echo ""
}

# ---------------------------------------------------------------------------
# Testa se o agente está se reportando corretamente ao relay
# ---------------------------------------------------------------------------
test_agent_report() {
  section "Teste de comunicacao pos-instalacao"

  local test_log="/tmp/ocs-agent-test-$$.log"
  local relay_ip="${BACKEND_URL#http://}"
  relay_ip="${relay_ip#https://}"
  relay_ip="${relay_ip%%/*}"
  relay_ip="${relay_ip%%:*}"
  local relay_port="80"
  echo "${BACKEND_URL}" | grep -q ":[0-9]" && relay_port=$(echo "$BACKEND_URL" | grep -oE ":[0-9]+" | tr -d ':')

  # 1. Testar conectividade TCP
  info "1. Testando conectividade TCP com ${relay_ip}:${relay_port}..."
  if timeout 3 bash -c "echo >/dev/tcp/${relay_ip}/${relay_port}" 2>/dev/null; then
    printf "${GRN}[INFO]${NC}   TCP %s:%s → ${GRN}ABERTA${NC}\n" "$relay_ip" "$relay_port"
  else
    printf "${RED}[AVISO]${NC} TCP %s:%s → ${RED}BLOQUEADA${NC}\n" "$relay_ip" "$relay_port" >&2
    warn "   O agente nao consegue alcancara o relay. Verifique Guardicore/firewall."
    return 1
  fi

  # 2. Testar API /api-check/
  info "2. Testando API do relay..."
  local api_resp
  api_resp=$(curl --noproxy '*' -fsS --max-time 5     "http://${relay_ip}:${relay_port}/api-check/" 2>/dev/null || true)
  if echo "$api_resp" | grep -q "API is online"; then
    printf "${GRN}[INFO]${NC}   API /api-check/ → ${GRN}OK${NC} (%s)\n" "$api_resp"
  else
    printf "${YEL}[AVISO]${NC} API /api-check/ → ${YEL}sem resposta esperada${NC} (resp: %s)\n" "${api_resp:-vazia}" >&2
  fi

  # 3. Testar autenticacao
  info "3. Testando autenticacao (usuario: ${ADMIN_USER})..."
  local token_resp
  token_resp=$(curl --noproxy '*' -fsS --max-time 5     -X POST "http://${relay_ip}:${relay_port}/api-auth/token"     -H "Content-Type: application/json"     -d "{"username":"${ADMIN_USER}","password":"${ADMIN_PASS}"}" 2>/dev/null || true)
  if echo "$token_resp" | grep -q '"token"'; then
    printf "${GRN}[INFO]${NC}   Autenticacao → ${GRN}OK${NC} (token obtido)\n"
  else
    printf "${RED}[AVISO]${NC} Autenticacao → ${RED}FALHOU${NC} (resp: %s)\n" "${token_resp:-vazia}" >&2
    warn "   Verifique se o usuario '${ADMIN_USER}' existe e tem permissao no backend."
    return 1
  fi

  # 4. Forcar envio de inventario e verificar resultado
  info "4. Forcando envio de inventario ao relay..."
  if command -v ocsinventory-cli >/dev/null 2>&1; then
    ocsinventory-cli       --url "$BACKEND_URL"       --username "$ADMIN_USER"       --password "$ADMIN_PASS"       --mode 1       --log_level 3       --log_file true       --log_file_path "$test_log" 2>/dev/null || true

    if grep -q "Inventory created\|Inventory updated\|completed successfully" "$test_log" 2>/dev/null; then
      printf "${GRN}[INFO]${NC}   Inventario → ${GRN}ENVIADO COM SUCESSO${NC}\n"
      grep -E "created|updated|successfully" "$test_log" | tail -3 | while read -r line; do
        info "   $line"
      done
    elif grep -q "API is not available\|No route to host\|Connection refused" "$test_log" 2>/dev/null; then
      printf "${RED}[AVISO]${NC} Inventario → ${RED}FALHOU${NC} (sem rota para o relay)\n" >&2
      warn "   Verifique conectividade TCP e regras de firewall."
    else
      printf "${YEL}[AVISO]${NC} Inventario → ${YEL}resultado inconclusivo${NC} -- veja: %s\n" "$test_log" >&2
    fi
  else
    warn "   Binario ocsinventory-cli nao encontrado no PATH."
  fi

  # 5. Resumo final
  echo ""
  printf "  ${BLU}════ Resumo do teste ════${NC}\n"
  printf "  Relay     : %s\n" "$BACKEND_URL"
  printf "  Usuario   : %s\n" "$ADMIN_USER"
  [ -n "$AGENT_TAG" ] && printf "  Tag       : %s\n" "$AGENT_TAG"
  printf "  Log teste : %s\n" "$test_log"
  printf "  Log inst. : %s\n" "$INSTALL_LOG"
  echo ""

  rm -f "$test_log"
}

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
      # Desabilitar repos externos conhecidos que podem estar desatualizados ou
      # indisponiveis (pgdg antigas, repos de terceiros) para nao travar o dnf
      # em metadados que nao sao necessarios para instalar as dependencias do agente.
      $PKG_MGR install -y         --disablerepo="pgdg9*"         --disablerepo="pgdg10"         --disablerepo="pgdg11"         --disablerepo="pgdg12"         --disablerepo="pgdg13"         "$@" 2>/dev/null || $PKG_MGR install -y "$@"
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
  curl -fsSL --max-time 600 "https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${dart_arch}-release.zip" \
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

# Lista de relays/servidores OCS conhecidos
# Formato: NUMERO|IP|NOME_DO_SITE
# Adicione novas linhas conforme o ambiente crescer.
OCS_RELAYS="
  1|10.24.22.93|Omnichannel
  2|10.24.55.30|DC Lapa Servers (lnxdczabprod02)
  3|10.24.55.31|SNOC
  4|10.24.55.32|DC Lapa Redes
  5|10.24.127.56|DC Makenzie
  6|10.24.21.157|Bradesco GVP
  7|10.230.22.199|Globalhitss
  8|172.27.0.39|CLOUD
  9|172.28.118.124|OPENSTACK-EDGE01
  10|172.28.118.125|OPENSTACK-EDGE02
  11|172.20.201.95|DCV-01
  12|172.20.201.98|DCV-02
  13|10.40.201.124|FEDERADO01
  14|10.40.201.125|FEDERADO02
  15|172.19.118.124|Openstack EDGE-BSA01
  16|172.19.118.125|Openstack EDGE-BSA02
  17|172.18.118.124|Openstack EDGE-CTA01
  18|172.18.118.125|Openstack EDGE-CTA02
"

# Pergunta a tag de identificação do ativo (opcional)
ask_agent_tag() {
  [ -n "$AGENT_TAG" ] && return 0
  printf "  Tag de identificacao do ativo no console (ex.: ITSM-DEVOPS, NOC, INFRA)
"
  printf "  Deixe em branco para nao definir tag: "
  read -r input_tag
  AGENT_TAG="${input_tag}"
  [ -n "$AGENT_TAG" ] && info "Tag definida: $AGENT_TAG" || info "Sem tag definida."
}

ask_backend_url() {
  [ -n "$BACKEND_URL" ] && return 0

  printf "
"
  printf "  Selecione o servidor OCS para onde o agente ira se reportar:
"
  printf "  %-5s %-20s %s
" "Opcao" "IP do Relay" "Site / Descricao"
  printf "  %s
" "------------------------------------------------------------"

  # Exibir relays da lista
  echo "$OCS_RELAYS" | grep -v "^[[:space:]]*$" | while IFS="|" read -r num ip desc; do
    num=$(echo "$num" | tr -d ' ')
    ip=$(echo "$ip"   | tr -d ' ')
    desc=$(echo "$desc" | sed 's/^ *//')
    [ -z "$ip" ] && continue
    printf "  [%2s] %-20s %s
" "$num" "$ip" "$desc"
  done

  # Calcular próximo número para opção manual
  local last_num
  last_num=$(echo "$OCS_RELAYS" | grep -v "^[[:space:]]*$" | tail -1 | cut -d'|' -f1 | tr -d ' ')
  local manual_num=$((last_num + 1))

  printf "  [%2s] %-20s %s
" "$manual_num" "---" "Informar manualmente"
  printf "
"
  printf "  Escolha [1-%s]: " "$manual_num"
  read -r escolha
  escolha=$(echo "$escolha" | tr -d ' ')

  # Verificar se é a opção manual
  if [ "$escolha" = "$manual_num" ]; then
    printf "  URL ou IP do relay (ex.: http://IP ou http://IP:PORTA): "
    read -r input_url
    [ -z "$input_url" ] && die "URL do relay e obrigatoria."
    BACKEND_URL="${input_url%/}"
    [ "${BACKEND_URL#http}" = "$BACKEND_URL" ] && BACKEND_URL="http://${BACKEND_URL}"
    info "Relay manual: $BACKEND_URL"
    return 0
  fi

  # Verificar se o número corresponde a um relay da lista
  local found_ip
  found_ip=$(echo "$OCS_RELAYS" | grep -v "^[[:space:]]*$" | while IFS="|" read -r num ip desc; do
    num=$(echo "$num" | tr -d ' ')
    ip=$(echo "$ip"   | tr -d ' ')
    [ "$num" = "$escolha" ] && echo "$ip" && break
  done)

  if [ -n "$found_ip" ]; then
    BACKEND_URL="http://${found_ip}"
    info "Relay selecionado: $BACKEND_URL"
    return 0
  fi

  # Aceitar IP ou URL digitada diretamente
  if echo "$escolha" | grep -qE "^[0-9]+\.[0-9]+|^http"; then
    BACKEND_URL="${escolha%/}"
    [ "${BACKEND_URL#http}" = "$BACKEND_URL" ] && BACKEND_URL="http://${BACKEND_URL}"
    info "Relay direto: $BACKEND_URL"
    return 0
  fi

  die "Opcao invalida: $escolha. Escolha um numero entre 1 e $manual_num."
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

  # Construir campo tag (opcional)
  local tag_field=""
  [ -n "$AGENT_TAG" ] && tag_field=",
  \"tag\": \"${AGENT_TAG}\""

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
  "bypass-certificate": false$(printf '%b' "$tag_field")
}
CFGEOF

  [ -n "$AGENT_TAG" ] && info "Tag configurada: ${AGENT_TAG}"

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

  # Fallback: instalar cron quando systemd nao estiver disponivel ou nao suportar o servico
  # Garante execucao periodica em sistemas mais antigos (Slackware, containers, etc.)
  if ! command -v systemctl >/dev/null 2>&1 ||      ! systemctl is-active --quiet ocsinventory-agent 2>/dev/null; then
    if command -v crontab >/dev/null 2>&1 || [ -d /etc/cron.d ]; then
      info "Configurando cron como fallback (systemd indisponivel ou servico inativo)..."
      mkdir -p /var/log/ocsinventory-agent
      cat > /etc/cron.d/ocsinventory-agent << CRONEOF
# OCS Inventory Agent -- fallback cron (systemd nao disponivel)
# Executa a cada 4 horas (mesma frequencia configurada no servidor)
0 */4 * * * root /usr/bin/ocsinventory-cli \
  --url ${BACKEND_URL} \
  --username ${ADMIN_USER} \
  --password ${ADMIN_PASS} \
  --mode 1 \
  --log_level 2 \
  --log_file true \
  --log_file_path /var/log/ocsinventory-agent/ocsinventory-agent.log >> /var/log/ocsinventory-agent/cron.log 2>&1
CRONEOF
      chmod 644 /etc/cron.d/ocsinventory-agent
      info "Cron configurado: /etc/cron.d/ocsinventory-agent (execucao a cada 4 horas)"
    fi
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
# Inicializar log de instalacao
mkdir -p "$(dirname "$INSTALL_LOG")" 2>/dev/null || true
echo "" >> "$INSTALL_LOG" 2>/dev/null || true
echo "=== Inicio da instalacao $(date) ===" >> "$INSTALL_LOG" 2>/dev/null || true
info "Log de instalacao: $INSTALL_LOG"

detect_distro
detect_bundle || true
probe_internet_agent

if [ -n "$BUNDLE_DIR" ]; then
  info "Modo misto: internet com fallback para bundle em ${BUNDLE_DIR}"
elif [ "$INTERNET_GITHUB" -eq 0 ] || [ "$INTERNET_DART" -eq 0 ]; then
  warn "Sem acesso total a internet -- use --bundle-dir se tiver um bundle offline."
fi

install_base_deps
check_and_remove
install_dart_agent
show_network_info
ask_agent_tag
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
test_agent_report

printf "\n"
info "Concluido. O agente se reportara para: $BACKEND_URL"
[ -n "$AGENT_TAG" ] && info "Tag do ativo: $AGENT_TAG"
[ "$INSTALL_SERVICE" -eq 1 ] && info "Status: systemctl status $AGENT_SERVICE_NAME"
echo "=== Instalacao concluida em $(date) ===" >> "$INSTALL_LOG" 2>/dev/null || true
echo "    Relay  : $BACKEND_URL" >> "$INSTALL_LOG" 2>/dev/null || true
echo "    Tag    : ${AGENT_TAG:-nao definida}" >> "$INSTALL_LOG" 2>/dev/null || true
echo "    Log    : $INSTALL_LOG" >> "$INSTALL_LOG" 2>/dev/null || true
