#!/bin/bash
# Fix GenieACS Panel issues for Ubuntu
# Run: sudo bash fix-panel.sh

set -e

echo "=== Fixing GenieACS Panel ==="

# 1. Update SQLite genieAcsUrl
echo "[1/4] Updating ACS URL in database..."
cd /opt/genieacs-panel
node -e "
const D=require('./backend/node_modules/better-sqlite3');
const db=new D('./database.sqlite');
db.prepare(\"UPDATE settings SET value='http://127.0.0.1:7557' WHERE key='genieAcsUrl'\").run();
const r=db.prepare(\"SELECT * FROM settings WHERE key='genieAcsUrl'\").get();
console.log('ACS URL:', r.value);
db.close();
"

# 2. Fix deviceService.js (support POST method)
echo "[2/4] Fixing deviceService.js..."

# Replace fetchFromGenieAcs to support POST
sudo sed -i 's|static async fetchFromGenieAcs(endpoint, query = {})|static async fetchFromGenieAcs(endpoint, query = {}, method = '\''GET'\'', body = null)|' /opt/genieacs-panel/backend/src/services/deviceService.js

# Replace the fetch call to use method/body
sudo sed -i 's|const response = await fetch(url, {|const opts = { method, headers: { '\''Accept'\'': '\''application/json'\'' }, signal: controller.signal }; if (body \&\& method !== '\''GET'\'') { opts.headers['\''Content-Type'\''] = '\''application/json'\''; opts.body = JSON.stringify(body); } const response = await fetch(url, opts);|' /opt/genieacs-panel/backend/src/services/deviceService.js

# Clean up duplicate fetch lines
sudo sed -i '/method: .GET.,$/d' /opt/genieacs-panel/backend/src/services/deviceService.js
sudo sed -i '/headers: {$/,/signal: controller.signal$/d' /opt/genieacs-panel/backend/src/services/deviceService.js

echo "deviceService.js patched"

# 3. Fix deleteDevice to use DELETE method
sudo sed -i "s|await this.fetchFromGenieAcs(deleteUrl);|await this.fetchFromGenieAcs(deleteUrl, {}, 'DELETE');|" /opt/genieacs-panel/backend/src/services/deviceService.js 2>/dev/null || true

# 4. Fix rebootDevice to use POST  
sudo sed -i "s|await this.fetchFromGenieAcs(rebootUrl);|await this.fetchFromGenieAcs(rebootUrl, {}, 'POST', { name: 'reboot' });|" /opt/genieacs-panel/backend/src/services/deviceService.js 2>/dev/null || true

# 5. Restart services
echo "[3/4] Restarting services..."
sudo systemctl restart genieacs-panel-api

# 6. Test
echo "[4/4] Testing..."
sleep 2
TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

echo "Devices:"
curl -s http://localhost:3001/api/devices -H "Authorization: Bearer $TOKEN" | python3 -m json.tool 2>/dev/null | head -20

echo ""
echo "=== Done! Reload Panel at http://$(hostname -I | awk '{print $1}'):3000 ==="
