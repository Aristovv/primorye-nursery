#!/usr/bin/env bash
# Installer for a separate VladFlora app; does not change other web services.
set -Eeuo pipefail
[ "$(id -u)" = 0 ] || { echo "Run as root"; exit 1; }
command -v apt-get >/dev/null || { echo "Ubuntu/Debian required"; exit 1; }
APPDIR=/opt/vladflora-app; PORT=4175
[ ! -e "$APPDIR" ] && [ ! -e /etc/systemd/system/vladflora.service ] || { echo "Existing installation: refusing overwrite"; exit 1; }
if ss -ltn 2>/dev/null | grep -q ":4175 "; then echo "Port 4175 occupied, aborting"; exit 1; fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y git curl ca-certificates nodejs npm postgresql openssl python3
id -u vladflora >/dev/null 2>&1 || useradd --system --home-dir "$APPDIR" --shell /usr/sbin/nologin vladflora
git clone --depth 1 https://github.com/Aristovv/primorye-nursery.git "$APPDIR"
cd "$APPDIR"
npm ci --omit=dev 2>/dev/null || npm install --omit=dev
python3 - <<'PY'
from pathlib import Path
p=Path("server.js"); s=p.read_text()
old="app.get('/',(_req,res)=>res.redirect(origin));"
new="app.get('/',(_req,res)=>res.sendFile(path.join(__dirname,'index.html')));app.get('/index.html',(_req,res)=>res.sendFile(path.join(__dirname,'index.html')));"
if old not in s: raise SystemExit("Unexpected server source; not patching")
p.write_text(s.replace(old,new))
p=Path("index.html"); s=p.read_text()
old="https://primorye-nursery-admin.onrender.com/api/plants"
if old not in s: raise SystemExit("Unexpected catalog source; not patching")
p.write_text(s.replace(old,"/api/plants"))
PY
systemctl enable --now postgresql
DBPASS="$(openssl rand -hex 24)"
ADMPASS="$(openssl rand -hex 18)"
SESSION="$(openssl rand -hex 48)"
ROLE_EXISTS="$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='vladflora'\"" | xargs)"
DB_EXISTS="$(su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='vladflora'\"" | xargs)"
if [ -n "$ROLE_EXISTS" ] || [ -n "$DB_EXISTS" ]; then echo "Existing VladFlora DB/role, refusing overwrite"; exit 1; fi
su postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE ROLE vladflora LOGIN PASSWORD '$DBPASS'\""
su postgres -c "psql -v ON_ERROR_STOP=1 -c \"CREATE DATABASE vladflora OWNER vladflora\""
install -d -m 700 /etc/vladflora
cat >/etc/vladflora/app.env <<EOF
PORT=$PORT
DB_SSL=false
DATABASE_URL=postgresql://vladflora:$DBPASS@127.0.0.1:5432/vladflora
SESSION_SECRET=$SESSION
ADMIN_PASSWORD=$ADMPASS
EOF
chmod 600 /etc/vladflora/app.env
cat >/etc/systemd/system/vladflora.service <<EOF
[Unit]
Description=VladFlora nursery catalogue
After=network.target postgresql.service
[Service]
WorkingDirectory=$APPDIR
User=vladflora
Environment=NODE_ENV=production
EnvironmentFile=/etc/vladflora/app.env
ExecStart=/usr/bin/node $APPDIR/server.js
Restart=on-failure
RestartSec=4
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF
chown -R vladflora:vladflora "$APPDIR"
systemctl daemon-reload
systemctl enable --now vladflora.service
sleep 3
curl -fsS http://127.0.0.1:4175/health >/dev/null || { echo "Check: journalctl -u vladflora"; exit 1; }
cat >/root/VLADFLORA_ACCESS.txt <<EOF
Preview: http://178.253.40.156:4175/
Admin: /admin (ONLY AFTER HTTPS)
Admin password: $ADMPASS
Root-only secrets: /etc/vladflora/app.env
New database is empty; no Render data migrated.
Open TCP 4175 in firewall to preview publicly. HTTPS needed before admin login.
EOF
chmod 600 /root/VLADFLORA_ACCESS.txt
echo "VladFlora started. Preview: http://178.253.40.156:4175/"
echo "Password in root-only /root/VLADFLORA_ACCESS.txt. Do not share it."
