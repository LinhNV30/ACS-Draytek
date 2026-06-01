#!/bin/bash
# ============================================================
#  ACS-Draytek Auto Installer for Ubuntu 24.04.4 LTS
#  Installs: MongoDB + GenieACS + GenieACS Panel (Custom UI)
#  Repo: https://github.com/LinhNV30/ACS-Draytek
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
INSTALL_DIR="/opt"
PANEL_REPO="https://github.com/LinhNV30/ACS-Draytek.git"
GENIEACS_REPO="https://github.com/genieacs/genieacs.git"

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  ACS-Draytek Auto Installer${NC}"
echo -e "${GREEN}  Ubuntu 24.04.4 LTS${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo bash $0${NC}"
    exit 1
fi

SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}Detected IP: ${SERVER_IP}${NC}"
read -p "Use this IP? [Y/n]: " USE_IP
USE_IP=${USE_IP:-Y}
if [[ "$USE_IP" =~ ^[Nn] ]]; then
    read -p "Enter server IP/domain: " SERVER_IP
fi
echo ""

# ============================================================
# STEP 1: Prerequisites
# ============================================================
echo -e "${GREEN}[1/7] Installing prerequisites...${NC}"
apt-get update -qq
apt-get install -y -qq curl git build-essential gnupg ufw net-tools unzip openssl python3 2>/dev/null

# ---- Node.js 20.x (REQUIRED) ----
NODE_MAJOR=$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v')
if [ "$NODE_MAJOR" != "20" ] 2>/dev/null || ! command -v node &>/dev/null; then
    echo -e "${YELLOW}  Installing Node.js 20.x...${NC}"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - &>/dev/null
    apt-get install -y -qq nodejs
fi
echo -e "  Node.js: $(node -v) | npm: $(npm -v)"

# ---- MongoDB ----
if ! command -v mongod &>/dev/null; then
    echo -e "${YELLOW}  Installing MongoDB...${NC}"
    curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" > /etc/apt/sources.list.d/mongodb-org-7.0.list
    apt-get update -qq
    apt-get install -y -qq mongodb-org
    systemctl enable mongod
    systemctl start mongod
fi
echo -e "  MongoDB: $(mongod --version 2>/dev/null | head -1)"

# ============================================================
# STEP 2: Build GenieACS
# ============================================================
echo -e "${GREEN}[2/7] Building GenieACS...${NC}"

# Remove corrupted clone if exists
if [ -d "$INSTALL_DIR/genieacs" ] && [ ! -f "$INSTALL_DIR/genieacs/package.json" ]; then
    echo -e "${YELLOW}  Removing corrupted clone...${NC}"
    rm -rf "$INSTALL_DIR/genieacs"
fi

if [ ! -d "$INSTALL_DIR/genieacs" ]; then
    echo -e "${YELLOW}  Cloning GenieACS...${NC}"
    git clone "$GENIEACS_REPO" "$INSTALL_DIR/genieacs" 2>&1 | tail -1
fi

if [ ! -f "$INSTALL_DIR/genieacs/package.json" ]; then
    echo -e "${RED}FATAL: Failed to clone GenieACS${NC}"
    exit 1
fi

cd "$INSTALL_DIR/genieacs"

echo -e "${YELLOW}  Patching for Node.js $(node -v)...${NC}"

# --- Patch 1: Replace import assertions with fs.readFileSync in init.ts ---
python3 -c "
import re
with open('lib/init.ts', 'r') as f:
    content = f.read()

imports = re.findall(r'import (\w+) from \"\.\./seed/([\w.-]+)\" (?:with|assert) \{ type: \"text\" \};', content)
if imports:
    for var, file in imports:
        content = content.replace(f'import {var} from \"../seed/{file}\" with {{ type: \"text\" }};', '')
        content = content.replace(f'import {var} from \"../seed/{file}\" assert {{ type: \"text\" }};', '')
    
    first_import = content.find('import ')
    last_import = max(m.end() for m in re.finditer(r'^import .+$', content, re.MULTILINE))
    
    fs_import = 'import * as fs from \"node:fs\";\nimport * as path from \"node:path\";\n'
    seed_lines = ['const SEED_DIR = path.resolve(__dirname, \"..\", \"seed\");']
    for var, file in imports:
        seed_lines.append(f'const {var} = fs.readFileSync(path.join(SEED_DIR, \"{file}\"), \"utf8\");')
    
    content = content[:first_import] + fs_import + content[first_import:last_import] + '\n' + '\n'.join(seed_lines) + '\n' + content[last_import:]
    with open('lib/init.ts', 'w') as f:
        f.write(content)
    print('init.ts patched')
" 2>/dev/null && echo -e "    init.ts patched" || echo -e "    init.ts skip"

# --- Patch 2: Targets ---
sed -i 's/target: "node12"/target: "node18"/g' build/build.ts 2>/dev/null || true
sed -i 's/target: "node12.13.0"/target: "node18"/g' build/build.ts 2>/dev/null || true
sed -i 's/--target=node12/--target=node18/g' package.json 2>/dev/null || true

# --- Patch 3: seedPlugin for both with/assert ---
sed -i 's/if (args.with?\.\["type"\] !== "text") return undefined;/if ((args.with?.["type"] || args.assert?.["type"]) !== "text") return undefined;/' build/build.ts 2>/dev/null || true

# --- Patch 4: rmdir/mkdir tolerant ---
sed -i 's|await fsAsync.rmdir(dirPath);|try { await fsAsync.rmdir(dirPath); } catch(err) { if(err.code !== "EBUSY" \&\& err.code !== "ENOTEMPTY") throw err; }|' build/build.ts 2>/dev/null || true
sed -i 's|await fsAsync.mkdir(OUTPUT_DIR);|await fsAsync.mkdir(OUTPUT_DIR).catch((err) => { if (err.code !== "EEXIST") throw err; });|' build/build.ts 2>/dev/null || true

# --- Patch 5: Pre-compile Tailwind CSS ---
python3 -c "
import re
with open('build/build.ts', 'r') as f:
    content = f.read()

old_func = '''async function generateCss'''
new_func = '''async function generateCss(): Promise<void> {
  const appCssPath = path.join(INPUT_DIR, \"ui/css/app.css\");
  const { stdout } = await execAsync(\`npx @tailwindcss/cli -i \${appCssPath}\`);
  const compiledCssPath = path.join(INPUT_DIR, \"ui/css/app-compiled.css\");
  await fsAsync.writeFile(compiledCssPath, stdout);
'''
if old_func in content:
    # Replace the function body approach
    content = content.replace('entryPoints: [\"ui/css/app.css\"]', 'entryPoints: [\"ui/css/app-compiled.css\"]')
    content = content.replace('if (v.entryPoint === \"ui/css/app.css\")', 'if (v.entryPoint === \"ui/css/app-compiled.css\")')
    
    # Remove the tailwindPlugin (onLoad hook)
    content = re.sub(
        r'const tailwindPlugin = \{.*?\} as esbuild\.Plugin;\s*',
        '',
        content,
        flags=re.DOTALL
    )
    content = content.replace('plugins: [tailwindPlugin],', '')
    print('CSS build patched')
    with open('build/build.ts', 'w') as f:
        f.write(content)
" 2>/dev/null && echo -e "    CSS build patched" || echo -e "    CSS patch skip"

echo -e "${YELLOW}  npm install...${NC}"
npm install 2>&1 | tail -3

echo -e "${YELLOW}  npm build...${NC}"
npm run build 2>&1 | tail -5

if [ ! -d "dist/bin" ]; then
    echo -e "${RED}  BUILD FAILED - dist/bin not found${NC}"
    echo -e "${YELLOW}  Trying fallback build...${NC}"
    rm -rf dist node_modules
    npm install 2>&1 | tail -3
    npm run build 2>&1 | tail -5
fi

if [ ! -d "dist/bin" ]; then
    echo -e "${RED}FATAL: GenieACS build failed${NC}"
    exit 1
fi

echo -e "  GenieACS built OK"

# ---- Config ----
mkdir -p dist/config/ext
JWT_SECRET=$(openssl rand -hex 32)
cat > dist/config/config.json << EOF
{
  "MONGODB_CONNECTION_URL": "mongodb://127.0.0.1/genieacs",
  "CWMP_PORT": 7547, "NBI_PORT": 7557,
  "FS_PORT": 7567, "UI_PORT": 3000,
  "UI_JWT_SECRET": "${JWT_SECRET}"
}
EOF

# ---- Seed + Assets ----
cp -r seed dist/ 2>/dev/null || true
cd dist/public
for f in app-*.css; do cp "$f" app.css 2>/dev/null; done
for f in app-*.js; do cp "$f" app.js 2>/dev/null; done
for f in icons-*.svg; do cp "$f" icons.svg 2>/dev/null; done

# ============================================================
# STEP 3: Panel
# ============================================================
echo -e "${GREEN}[3/7] Installing Panel...${NC}"

if [ -d "$INSTALL_DIR/genieacs-panel" ] && [ ! -f "$INSTALL_DIR/genieacs-panel/README.md" ]; then
    rm -rf "$INSTALL_DIR/genieacs-panel"
fi

if [ ! -d "$INSTALL_DIR/genieacs-panel" ]; then
    git clone "$PANEL_REPO" "$INSTALL_DIR/genieacs-panel" 2>&1 | tail -1
fi

cd "$INSTALL_DIR/genieacs-panel/backend"
npm install 2>&1 | tail -1
cat > .env << EOF
SQLITE_PATH=../database.sqlite
APP_PORT=3001
APP_ENV=production
SECRET_KEY=$(openssl rand -hex 32)
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=24h
REFRESH_TOKEN_EXPIRES_IN=7d
GENIEACS_URL=http://127.0.0.1:7557
EOF

cd "$INSTALL_DIR/genieacs-panel/frontend"
npm install 2>&1 | tail -1
cat > .env.local << EOF
NEXT_PUBLIC_API_URL=http://${SERVER_IP}:3001
EOF

cd "$INSTALL_DIR/genieacs-panel"
node -e "
const D=require('./backend/node_modules/better-sqlite3');
const b=require('./backend/node_modules/bcryptjs');
const db=new D('./database.sqlite');
db.prepare('INSERT OR REPLACE INTO users(id,username,password,role) VALUES(1,?,?,?)').run('admin',b.hashSync('admin123',12),'admin');
db.close();
" 2>/dev/null

# ============================================================
# STEP 4: systemd
# ============================================================
echo -e "${GREEN}[4/7] Creating services...${NC}"

for svc in cwmp nbi fs ui; do
    cat > "/etc/systemd/system/genieacs-${svc}.service" << EOF2
[Unit]
Description=GenieACS ${svc^^}
After=network.target mongod.service
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/genieacs/dist
Environment=GENIEACS_MONGODB_CONNECTION_URL=mongodb://127.0.0.1/genieacs
$( [ "$svc" = "ui" ] && echo "Environment=GENIEACS_UI_JWT_SECRET=${JWT_SECRET}" )
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs/dist/bin/genieacs-${svc}
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF2
done

cat > /etc/systemd/system/genieacs-panel-api.service << EOF
[Unit]
Description=GenieACS Panel API
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/genieacs-panel/backend
ExecStart=/usr/bin/node $INSTALL_DIR/genieacs-panel/backend/src/server.js
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/genieacs-panel-frontend.service << EOF
[Unit]
Description=GenieACS Panel Frontend
After=network.target
[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/genieacs-panel/frontend
ExecStart=/usr/bin/npm run dev
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

# ============================================================
# STEP 5: Firewall
# ============================================================
echo -e "${GREEN}[5/7] Firewall...${NC}"
ufw --force enable 2>/dev/null || true
for port in 22 7547 7557 7567 3000 3001 3002; do
    ufw allow $port/tcp 2>/dev/null || true
done

# ============================================================
# STEP 6: Start
# ============================================================
echo -e "${GREEN}[6/7] Starting services...${NC}"
for svc in genieacs-cwmp genieacs-nbi genieacs-fs genieacs-ui genieacs-panel-api genieacs-panel-frontend; do
    systemctl enable "$svc" 2>/dev/null || true
    systemctl restart "$svc" 2>/dev/null || true
    sleep 1
    systemctl is-active --quiet "$svc" 2>/dev/null && echo -e "  ${GREEN}OK${NC} $svc" || echo -e "  ${RED}FAIL${NC} $svc"
done

# ============================================================
# DONE
# ============================================================
echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}  Done!${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "  ACS URL:   ${YELLOW}http://${SERVER_IP}:7547/${NC}"
echo -e "  UI:        ${YELLOW}http://${SERVER_IP}:3000${NC}  (admin/admin)"
echo -e "  Panel:     ${YELLOW}http://${SERVER_IP}:3002${NC}  (admin/admin123)"
