#!/bin/bash
# Fix3 - Clear frontend cache & restart
cd /opt/genieacs-panel

echo "Clearing Next.js cache..."
rm -rf frontend/.next

echo "Restarting all services..."
sudo systemctl restart genieacs-panel-api genieacs-panel-frontend

sleep 5

echo ""
echo "=== Check services ==="
sudo ss -tlnp | grep -E "3000|3001"

echo ""
echo "=== Test API ==="
TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

curl -s http://localhost:3001/api/devices -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get('data',d)
if isinstance(data,list):
    for dev in data:
        print(f\"  {dev.get('serialNumber','?')[:30]} | {dev.get('brand','?')} | {dev.get('status','?')}\")
" 2>/dev/null

echo ""
echo "=== DONE ==="
echo "Open: http://$(hostname -I | awk '{print $1}'):3000"
echo "Login: admin / admin123"
