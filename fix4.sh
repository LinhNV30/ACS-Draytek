#!/bin/bash
# Fix4 - Update frontend API URL + clear cache
cd /opt/genieacs-panel

IP=$(hostname -I | awk '{print $1}')

echo "Updating frontend API URL to http://${IP}:3001..."
echo "NEXT_PUBLIC_API_URL=http://${IP}:3001" > frontend/.env.local

echo "Clearing Next.js cache..."
rm -rf frontend/.next

echo "Restarting frontend..."
sudo systemctl restart genieacs-panel-frontend

sleep 8

echo ""
echo "=== Verify ==="
curl -s -o /dev/null -w "Frontend: HTTP %{http_code}\n" http://localhost:3000/login/
curl -s http://localhost:3001/api/devices | head -c 100

echo ""
echo "=== Opening browser... ==="
echo "URL: http://${IP}:3000"
echo "Login: admin / admin123"
