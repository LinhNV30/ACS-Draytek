#!/bin/bash
# ============================================================
#  ACS-Draytek Auto Installer for Ubuntu 24.04.4 LTS
#  Installs: MongoDB + GenieACS + GenieACS Panel (Custom UI)
#  Repo: https://github.com/LinhNV30/ACS-Draytek
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
GENIEACS_VER="1.3.0-dev"
INSTALL_DIR="/opt"
PANEL_REPO="https://github.com/LinhNV30/ACS-Draytek.git"
GENIEACS_REPO="https://github.com/genieacs/genieacs.git"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ACS-Draytek Auto Installer${NC}"
echo -e "${GREEN}  Ubuntu 24.04.4 LTS${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

# ---- Check root ----
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo bash $0${NC}"
    exit 1
fi

# ---- Detect IP ----
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}Detected IP: ${SERVER_IP}${NC}"
read -p "Use this IP for ACS URL? [Y/n]: " USE_IP
USE_IP=${USE_IP:-Y}
if [[ "$USE_IP" =~ ^[Nn] ]]; then
    read -p "Enter ACS server IP or domain: " SERVER_IP
fi
echo ""

# ============================================================
# STEP 1: Install prerequisites
# ============================================================
echo -e "${GREEN}[1/7] Installing prerequisites...${NC}"
apt-get update -qq
apt-get install -y -qq curl git build-essential gnupg ufw net-tools unzip 2>&1 | tail -1

# ---- Node.js 20.x ----
if ! command -v node &>/dev/null; then
    echo -e "${YELLOW}  Installing Node.js 20.x...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
    apt-get install -y -qq nodejs
fi
echo -e "  Node.js: $(node -v) | npm: $(npm -v)"

# ---- MongoDB 7.0 ----
if ! command -v mongod &>/dev/null; then
    echo -e "${YELLOW}  Installing MongoDB 7.0...${NC}"
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update -qq
    apt-get install -y -qq mongodb-org
    systemctl enable mongod
    systemctl start mongod
fi
echo -e "  MongoDB: $(mongod --version 2>/dev/null | head -1)"

# ============================================================
# STEP 2: Clone & Build GenieACS
# ============================================================
echo -e "${GREEN}[2/7] Installing GenieACS...${NC}"

if [ ! -d "$INSTALL_DIR/genieacs" ]; then
    git clone "$GENIEACS_REPO" "$INSTALL_DIR/genieacs" 2>&1 | tail -1
fi
cd "$INSTALL_DIR/genieacs"

# Fix build issues for newer Node.js
echo -e "${YELLOW}  Applying compatibility fixes...${NC}"

# Fix import assertions (with -> assert)
if grep -q "with { type: \"text\" }" lib/init.ts 2>/dev/null; then
    sed -i 's/with { type: "text" }/assert { type: "text" }/g' lib/init.ts
fi

# Fix seedPlugin for assert support
sed -i 's/if (args.with?\.\["type"\] !== "text") return undefined/if (args.with?.["type"] !== "text" \&\& args.assert?.["type"] !== "text") return undefined/' build/build.ts 2>/dev/null || true

# Fix build targets for Node 20
sed -i 's/target: "node12"/target: "node18"/g' build/build.ts 2>/dev/null || true
sed -i 's/target: "node12.13.0"/target: "node18"/g' build/build.ts 2>/dev/null || true
sed -i 's/--target=node12/--target=node18/g' package.json 2>/dev/null || true

# Fix Tailwind CSS v4 compatibility
sed -i 's|entryPoints: \["ui/css/app.css"\]|entryPoints: ["ui/css/app-compiled.css"]|' build/build.ts 2>/dev/null || true

# Fix EBUSY error (dist locked)
sed -i 's/await fsAsync.rmdir(dirPath);/try { await fsAsync.rmdir(dirPath); } catch(err) { if(err.code !== "EBUSY" \&\& err.code !== "ENOTEMPTY") throw err; }/' build/build.ts 2>/dev/null || true
sed -i 's/await fsAsync.mkdir(OUTPUT_DIR);/await fsAsync.mkdir(OUTPUT_DIR).catch((err) => { if (err.code !== "EEXIST") throw err; });/' build/build.ts 2>/dev/null || true

# Build
npm install --silent 2>&1 | tail -1
npm run build 2>&1 | tail -3

# ---- Create GenieACS config ----
mkdir -p "$INSTALL_DIR/genieacs/dist/config/ext"
cat > "$INSTALL_DIR/genieacs/dist/config/config.json" << EOF
{
  "MONGODB_CONNECTION_URL": "mongodb://127.0.0.1/genieacs",
  "CWMP_PORT": 7547,
  "NBI_PORT": 7557,
  "FS_PORT": 7567,
  "UI_PORT": 3000,
  "UI_JWT_SECRET": "$(openssl rand -hex 32)"
}
EOF

echo -e "  GenieACS: installed at $INSTALL_DIR/genieacs"

# ============================================================
# STEP 3: Clone & Setup GenieACS Panel
# ============================================================
echo -e "${GREEN}[3/7] Installing GenieACS Panel...${NC}"

if [ ! -d "$INSTALL_DIR/genieacs-panel" ]; then
    git clone "$PANEL_REPO" "$INSTALL_DIR/genieacs-panel" 2>&1 | tail -1
fi

# ---- Backend ----
cd "$INSTALL_DIR/genieacs-panel/backend"
npm install --silent 2>&1 | tail -1

# Create .env
JWT_SECRET=$(openssl rand -hex 32)
cat > .env << EOF
# Database (SQLite)
SQLITE_PATH=../database.sqlite

# App
APP_PORT=3001
APP_ENV=production

# Security
SECRET_KEY=$(openssl rand -hex 32)
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=24h
REFRESH_TOKEN_EXPIRES_IN=7d

# GenieACS NBI API
GENIEACS_URL=http://127.0.0.1:7557
EOF

# ---- Frontend ----
cd "$INSTALL_DIR/genieacs-panel/frontend"
npm install --silent 2>&1 | tail -1

# Create .env.local
cat > .env.local << EOF
NEXT_PUBLIC_API_URL=http://${SERVER_IP}:3001
EOF

echo -e "  Panel: installed at $INSTALL_DIR/genieacs-panel"

# ============================================================
# STEP 4: Create systemd services
# ============================================================
echo -e "${GREEN}[4/7] Creating systemd services...${NC}"

# ---- GenieACS CWMP ----
cat > /etc/systemd/system/genieacs-cwmp.service << EOF
[Unit]
Description=GenieACS CWMP (TR-069 ACS)
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs/dist
Environment=GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1/genieacs
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs/dist/bin/genieacs-cwmp
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- GenieACS NBI ----
cat > /etc/systemd/system/genieacs-nbi.service << EOF
[Unit]
Description=GenieACS NBI (REST API)
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs/dist
Environment=GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1/genieacs
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs/dist/bin/genieacs-nbi
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- GenieACS FS ----
cat > /etc/systemd/system/genieacs-fs.service << EOF
[Unit]
Description=GenieACS FS (File Server)
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs/dist
Environment=GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1/genieacs
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs/dist/bin/genieacs-fs
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- GenieACS UI ----
cat > /etc/systemd/system/genieacs-ui.service << EOF
[Unit]
Description=GenieACS UI (Web Interface)
After=network.target mongod.service

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs/dist
Environment=GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1/genieacs
Environment=GENIEACS_UI_JWT_SECRET=${JWT_SECRET}
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs/dist/bin/genieacs-ui
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- Panel Backend ----
cat > /etc/systemd/system/genieacs-panel-api.service << EOF
[Unit]
Description=GenieACS Panel Backend API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs-panel/backend
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs-panel/backend/src/server.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- Panel Frontend ----
cat > /etc/systemd/system/genieacs-panel-frontend.service << EOF
[Unit]
Description=GenieACS Panel Frontend (Next.js)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR/genieacs-panel/frontend
ExecStart=/usr/bin/npm run dev
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo -e "  Services created."

# ============================================================
# STEP 5: Copy hashed assets & seed DB
# ============================================================
echo -e "${GREEN}[5/7] Setting up assets & database...${NC}"

# Copy hashed assets
cd "$INSTALL_DIR/genieacs/dist/public"
for f in app-*.css; do cp "$f" app.css 2>/dev/null; done
for f in app-*.js; do cp "$f" app.js 2>/dev/null; done
for f in icons-*.svg; do cp "$f" icons.svg 2>/dev/null; done

# Copy seed to dist
cp -r "$INSTALL_DIR/genieacs/seed"/* "$INSTALL_DIR/genieacs/dist/seed/" 2>/dev/null || true

# Reset default admin password for panel
cd "$INSTALL_DIR/genieacs-panel"
node -e "
const Database = require('./backend/node_modules/better-sqlite3');
const bcrypt = require('./backend/node_modules/bcryptjs');
const db = new Database('./database.sqlite');
const hash = bcrypt.hashSync('admin123', 12);
db.prepare('INSERT OR REPLACE INTO users (id, username, password, role) VALUES (1, ?, ?, ?)').run('admin', hash, 'admin');
console.log('Panel admin user: admin / admin123');
db.close();
" 2>/dev/null || echo -e "${YELLOW}  Panel DB already configured.${NC}"

echo -e "  Assets & database ready."

# ============================================================
# STEP 6: Configure Firewall
# ============================================================
echo -e "${GREEN}[6/7] Configuring firewall...${NC}"

ufw --force enable 2>/dev/null
ufw allow 22/tcp comment "SSH"
ufw allow 7547/tcp comment "GenieACS CWMP (TR-069)"
ufw allow 7557/tcp comment "GenieACS NBI (API)"
ufw allow 7567/tcp comment "GenieACS FS (Files)"
ufw allow 3000/tcp comment "GenieACS UI"
ufw allow 3001/tcp comment "Panel Backend API"
ufw allow 3002/tcp comment "Panel Frontend"
ufw reload 2>/dev/null

echo -e "  Firewall configured."

# ============================================================
# STEP 7: Start all services
# ============================================================
echo -e "${GREEN}[7/7] Starting services...${NC}"

SERVICES=(
    genieacs-cwmp
    genieacs-nbi
    genieacs-fs
    genieacs-ui
    genieacs-panel-api
    genieacs-panel-frontend
)

for svc in "${SERVICES[@]}"; do
    systemctl enable "$svc" 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    sleep 1
    if systemctl is-active --quiet "$svc"; then
        echo -e "  ${GREEN}✓${NC} $svc"
    else
        echo -e "  ${RED}✗${NC} $svc (check: journalctl -u $svc)"
    fi
done

# ============================================================
# DONE
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ACS-Draytek Installation Complete!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  Server IP:     ${YELLOW}${SERVER_IP}${NC}"
echo -e "  TR-069 ACS:    ${YELLOW}http://${SERVER_IP}:7547/${NC}"
echo ""
echo -e "  GenieACS UI:   ${YELLOW}http://${SERVER_IP}:3000${NC}"
echo -e "    Login: admin / admin"
echo ""
echo -e "  Panel UI:      ${YELLOW}http://${SERVER_IP}:3002${NC}"
echo -e "    Login: admin / admin123"
echo ""
echo -e "  Panel API:     ${YELLOW}http://${SERVER_IP}:3001${NC}"
echo -e "  NBI API:       ${YELLOW}http://${SERVER_IP}:7557${NC}"
echo ""
echo -e "${YELLOW}  Logs: journalctl -u genieacs-* -f${NC}"
echo -e "${GREEN}============================================${NC}"
