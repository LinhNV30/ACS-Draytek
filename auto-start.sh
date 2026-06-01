#!/bin/bash
# ACS Auto-Start - Enable all GenieACS services on boot
# Run: wget -qO auto-start.sh https://raw.githubusercontent.com/LinhNV30/ACS-Draytek/main/auto-start.sh && sudo bash auto-start.sh

SERVICES=(
    mongod
    genieacs-cwmp
    genieacs-nbi
    genieacs-fs
    genieacs-ui
    genieacs-panel-api
    genieacs-panel-frontend
)

echo "=== Enabling ACS auto-start on boot ==="

for svc in "${SERVICES[@]}"; do
    sudo systemctl enable "$svc" 2>/dev/null
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        echo -e "  \033[32mOK\033[0m $svc"
    else
        echo -e "  \033[31mFAIL\033[0m $svc"
    fi
done

echo ""
echo "=== Checking current status ==="
for svc in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo -e "  \033[32mRUNNING\033[0m $svc"
    else
        echo -e "  \033[33mSTOPPED\033[0m $svc"
        sudo systemctl restart "$svc" 2>/dev/null
    fi
done

echo ""
echo "=== Done ==="
echo "ACS will auto-start on boot."
echo "Check: sudo systemctl status genieacs-cwmp"
