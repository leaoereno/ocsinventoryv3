#!/usr/bin/env bash
# =============================================================================
# create-ocs-bundle.sh
#
# Cria um pacote offline completo para instalação do OCS Inventory 3.0
# em ambientes sem acesso à internet (ou com acesso restrito).
#
# Execute em uma máquina COM acesso à internet.
# O bundle gerado é copiado para os servidores de destino e detectado
# automaticamente pelos scripts install-ocsinventory-3.0.sh e
# install-ocsinventory-agent.sh.
#
# Uso:
#   ./create-ocs-bundle.sh [--tag TAG] [--out DIR] [--arch ARCH]
#
# Flags:
#   --tag  TAG    Tag git (padrão: 3.0.0-rc1)
#   --out  DIR    Diretório de saída (padrão: ./ocs-bundle)
#   --arch ARCH   Arquitetura Dart: x64, arm64, arm (padrão: x64)
#   --rhel        Baixar pacotes RPM para RHEL/AlmaLinux/Oracle
#   --debian      Baixar pacotes DEB para Debian/Ubuntu
#   --no-npm      Pular cache npm (frontend)
#   --no-pip      Pular wheels Python
#   --no-pkgs     Pular pacotes do sistema (RPM/DEB)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
OCS_TAG="3.0.0-rc1"
BUNDLE_DIR="./ocs-bundle"
DART_ARCH="x64"
DO_RHEL=0
DO_DEBIAN=0
DO_NPM=1
DO_PIP=1
DO_PKGS=1

GIT_BACKEND="https://github.com/OCSInventory-NG/OCSInventory-Server-Backend-Rework.git"
GIT_FRONTEND="https://github.com/OCSInventory-NG/OCSInventory-Server-Frontend-Rework.git"
GIT_SNMP="https://github.com/OCSInventory-NG/OCSInventory-SNMP-Scanner.git"
GIT_AGENT="https://github.com/OCSInventory-NG/OCSInventory-Agent-Rework.git"

RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'; BLU='\033[0;34m'; NC='\033[0m'
info()    { printf "${GRN}[INFO]${NC}    %s\n" "$*"; }
warn()    { printf "${YEL}[AVISO]${NC}   %s\n" "$*" >&2; }
die()     { printf "${RED}[ERRO]${NC}    %s\n" "$*" >&2; exit 1; }
section() { printf "\n${BLU}════════ %s ════════${NC}\n" "$*"; }
ok()      { printf "${GRN}  ✓${NC} %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Parse de argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)     OCS_TAG="$2";    shift 2 ;;
    --out)     BUNDLE_DIR="$2"; shift 2 ;;
    --arch)    DART_ARCH="$2";  shift 2 ;;
    --rhel)    DO_RHEL=1;       shift ;;
    --debian)  DO_DEBIAN=1;     shift ;;
    --no-npm)  DO_NPM=0;        shift ;;
    --no-pip)  DO_PIP=0;        shift ;;
    --no-pkgs) DO_PKGS=0;       shift ;;
    *) die "Opção desconhecida: $1" ;;
  esac
done

# Detectar distro automaticamente se não especificado
if [[ "$DO_RHEL" -eq 0 && "$DO_DEBIAN" -eq 0 ]]; then
  if command -v dnf &>/dev/null || command -v yum &>/dev/null; then
    DO_RHEL=1
  elif command -v apt-get &>/dev/null; then
    DO_DEBIAN=1
  fi
fi

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
cat << 'EOF'
╔══════════════════════════════════════════════════════════╗
║   OCS Inventory 3.0 — Criador de Bundle Offline         ║
║   Execute em uma máquina COM acesso à internet           ║
╚══════════════════════════════════════════════════════════╝
EOF
echo ""
info "Tag OCS     : $OCS_TAG"
info "Diretório   : $BUNDLE_DIR"
info "Arch Dart   : $DART_ARCH"
info "Pacotes RHEL: $([ "$DO_RHEL" -eq 1 ] && echo sim || echo não)"
info "Pacotes DEB : $([ "$DO_DEBIAN" -eq 1 ] && echo sim || echo não)"
echo ""

# ---------------------------------------------------------------------------
# Verificar pré-requisitos
# ---------------------------------------------------------------------------
section "Verificando pré-requisitos"

for cmd in git curl unzip; do
  command -v "$cmd" &>/dev/null && ok "$cmd" || die "$cmd não encontrado. Instale antes de continuar."
done

# Verificar Python3 para pip download
if [[ "$DO_PIP" -eq 1 ]]; then
  command -v python3 &>/dev/null && ok "python3" || { warn "python3 não encontrado — pulando pip wheels"; DO_PIP=0; }
  command -v pip3 &>/dev/null || command -v pip &>/dev/null && ok "pip" || { warn "pip não encontrado — pulando pip wheels"; DO_PIP=0; }
fi

# Verificar npm para cache frontend
if [[ "$DO_NPM" -eq 1 ]]; then
  command -v npm &>/dev/null && ok "npm" || { warn "npm não encontrado — pulando cache npm"; DO_NPM=0; }
fi

# Testar conectividade com os serviços necessários
section "Testando conectividade"

check_url() {
  local name="$1" url="$2"
  if curl -fsS --max-time 5 --head "$url" &>/dev/null; then
    ok "$name ($url)"
    return 0
  else
    warn "$name inacessível ($url)"
    return 1
  fi
}

check_url "GitHub"              "https://github.com" || die "GitHub inacessível — bundle não pode ser criado sem internet."
check_url "Dart SDK"            "https://storage.googleapis.com" || warn "Dart SDK pode falhar"
check_url "PyPI"                "https://pypi.org" || { warn "PyPI inacessível — pulando pip wheels"; DO_PIP=0; }
check_url "npm registry"        "https://registry.npmjs.org" || { warn "npm inacessível — pulando cache npm"; DO_NPM=0; }

# ---------------------------------------------------------------------------
# Criar estrutura de diretórios
# ---------------------------------------------------------------------------
section "Criando estrutura do bundle"

mkdir -p \
  "$BUNDLE_DIR/repos" \
  "$BUNDLE_DIR/dart" \
  "$BUNDLE_DIR/pip" \
  "$BUNDLE_DIR/npm" \
  "$BUNDLE_DIR/pkgs/rhel" \
  "$BUNDLE_DIR/pkgs/debian"

info "Estrutura criada em: $BUNDLE_DIR"

# ---------------------------------------------------------------------------
# Clonar repositórios como git bundle (portável, sem necessidade de git server)
# ---------------------------------------------------------------------------
section "Clonando repositórios git"

clone_as_bundle() {
  local name="$1" url="$2" tag="$3"
  local tmp_dir="/tmp/ocs-clone-$$-${name}"
  local bundle_file="${BUNDLE_DIR}/repos/${name}.bundle"

  if [[ -f "$bundle_file" ]]; then
    info "$name — bundle já existe, atualizando..."
    rm -rf "$tmp_dir"
  fi

  info "Clonando $name (tag $tag)..."
  git clone --branch "$tag" --depth 1 "$url" "$tmp_dir"

  info "Criando bundle portável: ${name}.bundle"
  git -C "$tmp_dir" bundle create "$bundle_file" --all
  rm -rf "$tmp_dir"
  ok "$name.bundle ($(du -sh "$bundle_file" | cut -f1))"
}

clone_as_bundle "backend"      "$GIT_BACKEND" "$OCS_TAG"
clone_as_bundle "frontend"     "$GIT_FRONTEND" "$OCS_TAG"
clone_as_bundle "snmp-scanner" "$GIT_SNMP" "$OCS_TAG"
clone_as_bundle "agent"        "$GIT_AGENT" "$OCS_TAG"

# ---------------------------------------------------------------------------
# Dart SDK
# ---------------------------------------------------------------------------
section "Dart SDK"

DART_ZIP="${BUNDLE_DIR}/dart/dartsdk-linux-${DART_ARCH}-release.zip"
DART_URL="https://storage.googleapis.com/dart-archive/channels/stable/release/latest/sdk/dartsdk-linux-${DART_ARCH}-release.zip"

if [[ -f "$DART_ZIP" ]]; then
  info "Dart SDK já existe no bundle."
else
  info "Baixando Dart SDK (${DART_ARCH})..."
  curl -fsSL --max-time 600 "$DART_URL" -o "$DART_ZIP"
fi

# Extrair e verificar
info "Verificando Dart SDK..."
unzip -q -o "$DART_ZIP" -d "${BUNDLE_DIR}/dart/"
ok "Dart SDK ($(${BUNDLE_DIR}/dart/dart-sdk/bin/dart --version 2>&1 | head -1))"

# ---------------------------------------------------------------------------
# Wheels Python (pip)
# ---------------------------------------------------------------------------
if [[ "$DO_PIP" -eq 1 ]]; then
  section "Wheels Python (pip)"

  # Clonar backend temporariamente para obter requirements
  TMP_BACKEND="/tmp/ocs-backend-reqs-$$"
  git clone --branch "$OCS_TAG" --depth 1 "$GIT_BACKEND" "$TMP_BACKEND" --quiet

  PIP_CMD="pip3"
  command -v pip3 &>/dev/null || PIP_CMD="pip"

  info "Baixando wheels: requirements.txt..."
  $PIP_CMD download \
    -r "${TMP_BACKEND}/requirements.txt" \
    -d "${BUNDLE_DIR}/pip/" \
    --no-deps 2>/dev/null || \
  $PIP_CMD download \
    -r "${TMP_BACKEND}/requirements.txt" \
    -d "${BUNDLE_DIR}/pip/"

  info "Baixando wheels: requirements_psql.txt..."
  $PIP_CMD download \
    -r "${TMP_BACKEND}/requirements_psql.txt" \
    -d "${BUNDLE_DIR}/pip/" 2>/dev/null || true

  info "Baixando wheels: requirements_mysql.txt..."
  $PIP_CMD download \
    -r "${TMP_BACKEND}/requirements_mysql.txt" \
    -d "${BUNDLE_DIR}/pip/" 2>/dev/null || true

  # uwsgi
  info "Baixando wheel: uwsgi..."
  $PIP_CMD download uwsgi -d "${BUNDLE_DIR}/pip/" 2>/dev/null || true

  rm -rf "$TMP_BACKEND"
  ok "$(ls "${BUNDLE_DIR}/pip/"*.whl 2>/dev/null | wc -l) wheels baixados"
fi

# ---------------------------------------------------------------------------
# Cache npm (frontend)
# ---------------------------------------------------------------------------
if [[ "$DO_NPM" -eq 1 ]]; then
  section "Cache npm (frontend)"

  TMP_FRONTEND="/tmp/ocs-frontend-npm-$$"
  git clone --branch "$OCS_TAG" --depth 1 "$GIT_FRONTEND" "$TMP_FRONTEND" --quiet

  info "Baixando dependências npm..."
  (cd "$TMP_FRONTEND" && npm install --prefer-offline 2>/dev/null)

  info "Compactando node_modules..."
  tar -czf "${BUNDLE_DIR}/npm/frontend-node_modules.tar.gz" \
    -C "$TMP_FRONTEND" node_modules

  rm -rf "$TMP_FRONTEND"
  ok "node_modules.tar.gz ($(du -sh "${BUNDLE_DIR}/npm/frontend-node_modules.tar.gz" | cut -f1))"
fi

# ---------------------------------------------------------------------------
# Pacotes RPM (RHEL/AlmaLinux/Oracle)
# ---------------------------------------------------------------------------
if [[ "$DO_RHEL" -eq 1 && "$DO_PKGS" -eq 1 ]]; then
  section "Pacotes RPM (RHEL)"

  PKG_MGR="dnf"
  command -v dnf &>/dev/null || PKG_MGR="yum"

  RHEL_PKGS=(
    git curl wget unzip sudo ca-certificates gnupg2
    gcc gcc-c++ make python3 python3-devel python3-pip
    nginx nodejs npm firewalld
    openldap-devel cyrus-sasl-devel openssl-devel
    policycoreutils-python-utils
    postgresql postgresql-libs
    epel-release
  )

  info "Baixando pacotes RPM com dependências..."
  $PKG_MGR download --resolve \
    --destdir="${BUNDLE_DIR}/pkgs/rhel" \
    "${RHEL_PKGS[@]}" 2>/dev/null || \
  warn "Alguns pacotes RPM não foram baixados (podem já estar instalados ou indisponíveis)"

  ok "$(ls "${BUNDLE_DIR}/pkgs/rhel/"*.rpm 2>/dev/null | wc -l) RPMs baixados"
fi

# ---------------------------------------------------------------------------
# Pacotes DEB (Debian/Ubuntu)
# ---------------------------------------------------------------------------
if [[ "$DO_DEBIAN" -eq 1 && "$DO_PKGS" -eq 1 ]]; then
  section "Pacotes DEB (Debian/Ubuntu)"

  command -v apt-get &>/dev/null || { warn "apt-get não disponível — pulando pacotes DEB"; DO_DEBIAN=0; }

  if [[ "$DO_DEBIAN" -eq 1 ]]; then
    DEB_PKGS=(
      git curl wget unzip sudo ca-certificates gnupg2
      gcc g++ make python3 python3-dev python3-pip python3-venv
      nginx nodejs npm
      ufw
      libldap2-dev libsasl2-dev libssl-dev build-essential
      postgresql-client
    )

    mkdir -p "${BUNDLE_DIR}/pkgs/debian/archives"
    info "Baixando pacotes DEB..."
    (cd "${BUNDLE_DIR}/pkgs/debian" && \
      apt-get download "${DEB_PKGS[@]}" 2>/dev/null || true)

    # Tentar via apt-cache
    apt-get install --download-only -y "${DEB_PKGS[@]}" \
      -o Dir::Cache::archives="${BUNDLE_DIR}/pkgs/debian/archives" 2>/dev/null || true

    ok "$(ls "${BUNDLE_DIR}/pkgs/debian/"*.deb "${BUNDLE_DIR}/pkgs/debian/archives/"*.deb 2>/dev/null | wc -l) DEBs baixados"
  fi
fi

# ---------------------------------------------------------------------------
# Manifest do bundle
# ---------------------------------------------------------------------------
section "Gerando manifest"

MANIFEST="${BUNDLE_DIR}/bundle.manifest"
cat > "$MANIFEST" << EOF
# OCS Inventory 3.0 — Bundle Manifest
# Gerado em: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Por: $(hostname) ($(uname -m))

OCS_TAG=${OCS_TAG}
DART_ARCH=${DART_ARCH}
BUNDLE_VERSION=1

REPOS=$(ls "${BUNDLE_DIR}/repos/"*.bundle 2>/dev/null | wc -l)
PIP_WHEELS=$(ls "${BUNDLE_DIR}/pip/"*.whl 2>/dev/null | wc -l)
NPM_CACHE=$([ -f "${BUNDLE_DIR}/npm/frontend-node_modules.tar.gz" ] && echo "yes" || echo "no")
RPM_PKGS=$(ls "${BUNDLE_DIR}/pkgs/rhel/"*.rpm 2>/dev/null | wc -l)
DEB_PKGS=$(ls "${BUNDLE_DIR}/pkgs/debian/"*.deb "${BUNDLE_DIR}/pkgs/debian/archives/"*.deb 2>/dev/null | wc -l)
EOF

ok "Manifest gerado: $MANIFEST"

# ---------------------------------------------------------------------------
# Compactar bundle
# ---------------------------------------------------------------------------
section "Compactando bundle"

BUNDLE_TARBALL="ocs-bundle-${OCS_TAG}-$(uname -m).tar.gz"

info "Criando ${BUNDLE_TARBALL}..."
tar -czf "$BUNDLE_TARBALL" -C "$(dirname "$BUNDLE_DIR")" "$(basename "$BUNDLE_DIR")"

ok "Bundle criado: $BUNDLE_TARBALL ($(du -sh "$BUNDLE_TARBALL" | cut -f1))"

# ---------------------------------------------------------------------------
# Resumo final
# ---------------------------------------------------------------------------
echo ""
cat << EOF
╔══════════════════════════════════════════════════════════╗
║   Bundle criado com sucesso!                            ║
╚══════════════════════════════════════════════════════════╝

Arquivo  : ${BUNDLE_TARBALL}
Tamanho  : $(du -sh "$BUNDLE_TARBALL" | cut -f1)

Para usar nos servidores de destino:

  1. Copiar o bundle:
     scp ${BUNDLE_TARBALL} root@IP_SERVIDOR:/opt/

  2. Extrair no servidor:
     tar -xzf /opt/${BUNDLE_TARBALL} -C /opt/

  3. Executar o instalador (detecta o bundle automaticamente):
     ./install-ocsinventory-3.0.sh --bundle-dir /opt/ocs-bundle --role relay ...

  Ou colocar o bundle ao lado do script (detecção automática):
     ls -la
     # ocs-bundle/   install-ocsinventory-3.0.sh
     ./install-ocsinventory-3.0.sh --role relay ...

EOF
