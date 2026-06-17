#!/usr/bin/env bash
set -euo pipefail

echo "== Corrigindo repositórios Debian 13 Trixie =="

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Execute como root."
  exit 1
fi

echo "Backup dos arquivos APT..."
mkdir -p /root/backup-apt-$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="/root/backup-apt-$(date +%Y%m%d-%H%M%S)"

cp -a /etc/apt/sources.list "$BACKUP_DIR/" 2>/dev/null || true
cp -a /etc/apt/sources.list.d "$BACKUP_DIR/" 2>/dev/null || true

echo "Removendo entradas cdrom..."
find /etc/apt -type f \( -name "*.list" -o -name "*.sources" \) \
  -exec sed -i '/cdrom:/d' {} \;

echo "Configurando repositórios oficiais..."
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "Limpando cache APT..."
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "Atualizando repositórios..."
apt-get update

echo "Instalando pacotes base válidos..."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential \
  curl \
  wget \
  git \
  unzip \
  ca-certificates \
  gnupg \
  lsb-release \
  python3 \
  python3-pip \
  python3-venv \
  nginx \
  ufw \
  psmisc \
  iproute2

echo
echo "Concluído com sucesso."
echo "Backup salvo em: $BACKUP_DIR"
