#!/usr/bin/env bash
set -euo pipefail

SCRIPT="${1:-ocsinventory-install.sh}"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Execute como root."
  exit 1
fi

if [[ ! -f "$SCRIPT" ]]; then
  echo "Arquivo não encontrado: $SCRIPT"
  echo "Uso: $0 /caminho/para/ocsinventory-install.sh"
  exit 1
fi

BACKUP="${SCRIPT}.bak-$(date +%Y%m%d-%H%M%S)"

echo "Backup do script:"
cp -a "$SCRIPT" "$BACKUP"
echo "$BACKUP"

echo "Removendo software-properties-common..."
sed -i \
  -e 's/[[:space:]]*software-properties-common[[:space:]]*/ /g' \
  "$SCRIPT"

echo "Trocando apt por apt-get..."
sed -i \
  -e 's/\bapt update\b/apt-get update/g' \
  -e 's/\bapt install\b/apt-get install/g' \
  -e 's/\bapt upgrade\b/apt-get upgrade/g' \
  -e 's/\bapt full-upgrade\b/apt-get full-upgrade/g' \
  -e 's/\bapt autoremove\b/apt-get autoremove/g' \
  -e 's/\bapt clean\b/apt-get clean/g' \
  "$SCRIPT"

echo "Removendo repositório cdrom..."
find /etc/apt -type f \( -name "*.list" -o -name "*.sources" \) \
  -exec sed -i '/cdrom:/d' {} \;

echo "Configurando repositórios oficiais Debian 13..."
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

echo
echo "Verificando se ainda existe software-properties-common no script..."
if grep -n "software-properties-common" "$SCRIPT"; then
  echo "Ainda existe referência. Revise manualmente."
  exit 1
else
  echo "OK: software-properties-common removido."
fi

echo
echo "Verificando comandos apt restantes..."
grep -nE '\bapt (update|install|upgrade|full-upgrade|autoremove|clean)\b' "$SCRIPT" || true

echo
echo "Correção finalizada."
echo "Backup salvo em: $BACKUP"
echo
echo "Agora execute:"
echo "bash $SCRIPT"
