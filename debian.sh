echo "Configurando repositórios oficiais do Debian 13..."

find /etc/apt -type f \( -name "*.list" -o -name "*.sources" \) \
    -exec sed -i '/cdrom:/d' {} \;

cat >/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

apt-get clean
rm -rf /var/lib/apt/lists/*
apt-get update
