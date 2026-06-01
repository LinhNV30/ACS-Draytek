#!/bin/bash
# Fix panel - run: sudo bash fix.sh
cd /opt/genieacs-panel

echo "Fixing SQLite URL..."
node -e "
const D=require('./backend/node_modules/better-sqlite3');
const db=new D('./database.sqlite');
db.prepare(\"UPDATE settings SET value='http://127.0.0.1:7557' WHERE key='genieAcsUrl'\").run();
console.log('URL updated');
db.close();
"

echo "Fixing deviceService.js (POST/DELETE support)..."
cat > backend/src/services/deviceService.js << 'EOF'
import Setting from '../models/Setting.js';

class DeviceService {
  static async getGenieAcsUrl() {
    const settings = await Setting.getAll();
    return settings.genieAcsUrl;
  }

  static async getVirtualParameters() {
    const settings = await Setting.getAll();
    return {
      vpPppoeUsername: settings.vpPppoeUsername || 'VirtualParameters.pppoeUsername',
      vpWanBridge: settings.vpWanBridge || 'VirtualParameters.WANBRIDGE',
      vpRxPower: settings.vpRxPower || 'VirtualParameters.RXPower',
      vpTemperature: settings.vpTemperature || 'VirtualParameters.gettemp',
      vpActiveDevices: settings.vpActiveDevices || 'VirtualParameters.activedevices',
      vpSuperAdmin: settings.vpSuperAdmin || 'VirtualParameters.superAdmin',
      vpSuperPassword: settings.vpSuperPassword || 'VirtualParameters.superPassword',
      vpUserAdmin: settings.vpUserAdmin || 'VirtualParameters.userAdmin',
      vpUserPassword: settings.vpUserPassword || 'VirtualParameters.userPassword'
    };
  }

  static async fetchFromGenieAcs(endpoint, query = {}, method = 'GET', body = null) {
    try {
      const baseUrl = await this.getGenieAcsUrl();
      if (!baseUrl) throw new Error('GenieACS URL not configured');
      let url = new URL(baseUrl);
      if (!url.pathname.startsWith('/devices')) url.pathname = '/devices';
      url = new URL(endpoint, url);
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
    } catch(e) {
      console.error('fetchFromGenieAcs error:', e.message);
      throw e;
    }
  }

  static flattenValue(obj) {
    if (!obj || typeof obj !== 'object') return null;
    if (obj._value !== undefined) return obj._value;
    for (const k of Object.keys(obj)) {
      const v = this.flattenValue(obj[k]);
      if (v !== null && v !== undefined) return v;
    }
    return null;
  }

  static getParam(obj, path) {
    if (!obj || !path) return null;
    let cur = obj;
    for (const p of path.split('.')) {
      if (!cur || typeof cur !== 'object') return null;
      cur = cur[p];
    }
    return this.flattenValue(cur);
  }

  static processDeviceData(item, vp) {
    const brand = item.InternetGatewayDevice?.DeviceInfo?.Manufacturer?._value
      || item._deviceId?._ProductClass || '';
    const lastInform = item._lastInform
      ? new Date(item._lastInform).toLocaleString() : 'Never';
    const rxPower = this.getParam(item, vp.vpRxPower);
    const temperature = this.getParam(item, vp.vpTemperature);
    const activeDevices = this.getParam(item, vp.vpActiveDevices);
    return {
      id: item._id, serialNumber: item._id, deviceType: brand || 'Unknown',
      brand: brand || 'Unknown', productClass: brand || 'Unknown',
      pppoeUsername: this.getParam(item, vp.vpPppoeUsername) || 'N/A',
      rxPower: rxPower ? `${rxPower} dBm` : 'N/A',
      temperature: temperature ? `${temperature}°C` : 'N/A',
      activeDevices: activeDevices || '0',
      wifiSsid2G: this.getParam(item, 'InternetGatewayDevice.LANDevice.1.WLANConfiguration.1.SSID') || 'N/A',
      lastInform, vendorId: '', status: (item._lastInform && (Date.now() - new Date(item._lastInform).getTime()) < 300000) ? 'Online' : 'Offline',
      raw: item
    };
  }

  static async getDevices() {
    const vp = await this.getVirtualParameters();
    const proj = ['_id','_deviceId._ProductClass','_deviceId._SerialNumber',
      vp.vpPppoeUsername,vp.vpWanBridge,vp.vpRxPower,vp.vpTemperature,
      vp.vpActiveDevices,'_lastInform'];
    for (let i=1; i<=8; i++) proj.push(`InternetGatewayDevice.LANDevice.1.WLANConfiguration.${i}.SSID`);
    const data = await this.fetchFromGenieAcs(`?projection=${encodeURIComponent(proj.join(','))}`);
    if (!Array.isArray(data)) throw new Error('Invalid');
    return data.map(d => this.processDeviceData(d, vp));
  }

  static async getDetailDevice(deviceId) {
    const vp = await this.getVirtualParameters();
    const device = await this.fetchFromGenieAcs(`/${encodeURIComponent(deviceId)}`);
    const d = Array.isArray(device) ? device[0] : device;
    if (!d) throw new Error('Not found');
    return this.processDeviceData(d, vp);
  }

  static async deleteDevice(deviceId) {
    return await this.fetchFromGenieAcs(`/${encodeURIComponent(deviceId)}`, {}, 'DELETE');
  }

  static async rebootDevice(deviceId) {
    return await this.fetchFromGenieAcs(`/${encodeURIComponent(deviceId)}/tasks?reboot=1`, {}, 'POST', { name: 'reboot' });
  }
}
export default DeviceService;
EOF

echo "Restarting..."
sudo systemctl restart genieacs-panel-api

sleep 2
TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"admin123"}' | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

echo ""
echo "Devices:"
curl -s http://localhost:3001/api/devices -H "Authorization: Bearer $TOKEN" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Total: {len(d.get(\"data\",d))} devices')" 2>/dev/null || curl -s http://localhost:3001/api/devices -H "Authorization: Bearer $TOKEN" | head -c 200

echo ""
echo "=== DONE ==="
echo "Reload: http://$(hostname -I | awk '{print $1}'):3000"
