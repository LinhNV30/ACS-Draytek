#!/bin/bash
# Fix panel v2 - Fix device data mapping for NBI API
# Run: wget -qO fix2.sh https://raw.githubusercontent.com/LinhNV30/ACS-Draytek/main/fix2.sh && sudo bash fix2.sh

cd /opt/genieacs-panel

echo "Fixing deviceService.js for NBI API format..."
cat > backend/src/services/deviceService.js << 'EOF'
import Setting from '../models/Setting.js';

class DeviceService {
  static async getGenieAcsUrl() {
    const settings = await Setting.getAll();
    return settings.genieAcsUrl || 'http://127.0.0.1:7557';
  }

  static async fetchFromGenieAcs(endpoint, query = {}, method = 'GET', body = null) {
    const baseUrl = await this.getGenieAcsUrl();
    let url = new URL(baseUrl);
    if (!url.pathname.endsWith('/')) url.pathname += '/';
    url = new URL(endpoint.startsWith('/') ? endpoint.slice(1) : endpoint, url);
    Object.keys(query).forEach(k => {
      if (query[k] !== undefined && query[k] !== null) url.searchParams.append(k, query[k]);
    });
    const ctrl = new AbortController();
    const tid = setTimeout(() => ctrl.abort(), 30000);
    try {
      const opts = { method, headers: { 'Accept': 'application/json' }, signal: ctrl.signal };
      if (body && method !== 'GET') {
        opts.headers['Content-Type'] = 'application/json';
        opts.body = JSON.stringify(body);
      }
      const resp = await fetch(url, opts);
      clearTimeout(tid);
      if (!resp.ok) throw new Error(`ACS API ${resp.status}`);
      const text = await resp.text();
      return text ? JSON.parse(text) : {};
    } catch(e) { clearTimeout(tid); throw e; }
  }

  static extract(obj, path) {
    if (!obj || !path) return null;
    let cur = obj;
    for (const p of path.split('.')) {
      if (!cur || typeof cur !== 'object') return null;
      cur = cur[p];
    }
    if (!cur || typeof cur !== 'object') return cur;
    if (cur._value !== undefined) return cur._value;
    for (const k of Object.keys(cur)) {
      const v = this.extract(cur[k], '');
      if (v !== null && v !== undefined) return v;
    }
    return null;
  }

  static processDevice(d) {
    const now = Date.now();
    const lastInform = d._lastInform;
    const age = lastInform ? now - new Date(lastInform).getTime() : Infinity;
    const deviceId = d._id || '';
    const idParts = deviceId.split('-');
    const brand = this.extract(d, 'InternetGatewayDevice.DeviceInfo.Manufacturer')
      || idParts[1] || 'Unknown';
    const model = this.extract(d, 'InternetGatewayDevice.DeviceInfo.ModelNumber')
      || idParts[2] || '';
    const serial = this.extract(d, 'InternetGatewayDevice.DeviceInfo.SerialNumber')
      || idParts[idParts.length-1] || deviceId;

    return {
      id: deviceId,
      serialNumber: deviceId,
      brand: brand,
      productClass: model,
      deviceType: brand,
      status: age < 300000 ? 'Online' : 'Offline',
      pppoeUsername: 'N/A',
      rxPower: 'N/A',
      temperature: 'N/A',
      activeDevices: '0',
      wifiSsid2G: 'N/A',
      lastInform: lastInform ? new Date(lastInform).toLocaleString() : 'Never',
      vendorId: '',
      raw: d
    };
  }

  static async getDevices() {
    const data = await this.fetchFromGenieAcs('devices');
    const list = Array.isArray(data) ? data : (data.data || []);
    return list.map(d => this.processDevice(d));
  }

  static async getDetailDevice(deviceId) {
    const data = await this.fetchFromGenieAcs(`devices/${encodeURIComponent(deviceId)}`);
    const d = Array.isArray(data) ? data[0] : data;
    if (!d) throw new Error('Not found');
    return this.processDevice(d);
  }

  static async deleteDevice(deviceId) {
    return await this.fetchFromGenieAcs(`devices/${encodeURIComponent(deviceId)}`, {}, 'DELETE');
  }

  static async rebootDevice(deviceId) {
    return await this.fetchFromGenieAcs(
      `devices/${encodeURIComponent(deviceId)}/tasks?reboot=1`, {}, 'POST', { name: 'reboot' }
    );
  }

  static async getVirtualParameters() {
    const settings = await Setting.getAll();
    return {
      vpPppoeUsername: settings.vpPppoeUsername || 'VirtualParameters.pppoeUsername',
      vpWanBridge: settings.vpWanBridge || 'VirtualParameters.WANBRIDGE',
      vpRxPower: settings.vpRxPower || 'VirtualParameters.RXPower',
      vpTemperature: settings.vpTemperature || 'VirtualParameters.gettemp',
      vpActiveDevices: settings.vpActiveDevices || 'VirtualParameters.activedevices',
    };
  }
}
export default DeviceService;
EOF

echo "Fixing summonDevice controller..."
cat > backend/src/controllers/deviceController.js << 'EOF'
import DeviceService from '../services/deviceService.js';
import { createResponse, createErrorResponse } from '../utils/helpers.js';

class DeviceController {
  static async getDevices(req, res) {
    try {
      const devices = await DeviceService.getDevices();
      return res.json(createResponse('OK', devices));
    } catch(e) {
      console.error('getDevices:', e);
      return res.status(500).json(createErrorResponse('Failed', e.message));
    }
  }

  static async getDeviceDetail(req, res) {
    try {
      const d = await DeviceService.getDetailDevice(req.params.deviceId);
      return res.json(createResponse('OK', d));
    } catch(e) {
      console.error('getDetail:', e);
      return res.status(404).json(createErrorResponse('Not found', e.message));
    }
  }

  static async deleteDevice(req, res) {
    try {
      await DeviceService.deleteDevice(req.params.deviceId);
      return res.json(createResponse('Deleted'));
    } catch(e) {
      return res.status(500).json(createErrorResponse('Failed', e.message));
    }
  }

  static async rebootDevice(req, res) {
    try {
      const r = await DeviceService.rebootDevice(req.body.deviceId);
      return res.json(createResponse('Rebooting', r));
    } catch(e) {
      return res.status(500).json(createErrorResponse('Failed', e.message));
    }
  }

  static async summonDevice(req, res) {
    try {
      const { id } = req.params;
      const genieAcsUrl = await DeviceService.getGenieAcsUrl();
      const url = `${genieAcsUrl}/devices/${encodeURIComponent(id)}/tasks?connection_request=1`;
      const data = await DeviceService.fetchFromGenieAcs(
        `devices/${encodeURIComponent(id)}/tasks?connection_request=1`,
        {}, 'POST', { name: 'refreshParameters' }
      );
      return res.json(createResponse('Summoned', data));
    } catch(e) {
      console.error('summon:', e);
      return res.status(500).json(createErrorResponse('Failed', e.message));
    }
  }

  static async updateWanConfig(req, res) { return res.json({}); }
  static async updateCredentials(req, res) { return res.json({}); }
}
export default DeviceController;
EOF

echo "Restarting..."
sudo systemctl restart genieacs-panel-api
sleep 2

TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

echo ""
echo "=== Devices via API ==="
curl -s http://localhost:3001/api/devices -H "Authorization: Bearer $TOKEN" | python3 -c "
import sys,json
d=json.load(sys.stdin)
data=d.get('data',d)
if isinstance(data,list):
    for dev in data:
        print(f\"  {dev.get('serialNumber','?')} | {dev.get('brand','?')} | {dev.get('status','?')} | {dev.get('lastInform','?')}\")
else:
    print(json.dumps(data,indent=2)[:500])
" 2>/dev/null

echo ""
echo "=== DONE - Reload http://$(hostname -I | awk '{print $1}'):3000 ==="
