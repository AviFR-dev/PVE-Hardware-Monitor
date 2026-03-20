#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  PVE Hardware Monitor - Install Script
#  Real-time fan RPM, temps, battery & system monitoring for Proxmox
#  https://github.com/AviFR-dev/PVE-Hardware-Monitor
#
#  Usage:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/AviFR-dev/PVE-Hardware-Monitor/main/install.sh)"
#
#  Supports: Any Proxmox VE host with lm-sensors / EC / IPMI
#  Special support: ASUS laptops with EC-based fan control
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colors & Formatting ──────────────────────────────────────────────
BL='\033[36m'   # Cyan
GN='\033[32m'   # Green
YW='\033[33m'   # Yellow
RD='\033[31m'   # Red
DM='\033[90m'   # Dim
BD='\033[1m'    # Bold
CL='\033[0m'    # Reset

CHECKMARK="${GN}✓${CL}"
CROSSMARK="${RD}✗${CL}"
ARROW="${BL}▸${CL}"
WARN="${YW}⚠${CL}"

APP_NAME="PVE Hardware Monitor"
APP_VERSION="1.0.0"
API_PORT=9099
INSTALL_DIR="/opt/pve-hwmonitor"
SERVICE_NAME="pve-hwmonitor"
DASHBOARD_FILE="dashboard.html"
API_FILE="api.py"

# ── Helper Functions ─────────────────────────────────────────────────
msg_info()  { echo -e " ${ARROW} ${1}"; }
msg_ok()    { echo -e " ${CHECKMARK} ${1}"; }
msg_warn()  { echo -e " ${WARN} ${1}"; }
msg_error() { echo -e " ${CROSSMARK} ${1}"; }

header() {
  clear
  echo -e "${BL}${BD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║       PVE Hardware Monitor Installer         ║"
  echo "  ║       Real-time Proxmox HW Dashboard         ║"
  echo "  ╚══════════════════════════════════════════════╝"
  echo -e "${CL}"
  echo -e "  ${DM}Version ${APP_VERSION} · github.com/AviFR-dev/PVE-Hardware-Monitor${CL}"
  echo ""
}

cleanup() {
  if [[ $? -ne 0 ]]; then
    echo ""
    msg_error "Installation failed. Check the output above for errors."
    msg_info "You can re-run this script after fixing any issues."
  fi
}
trap cleanup EXIT

# ── Pre-flight Checks ────────────────────────────────────────────────
preflight() {
  header

  # Must be root
  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root."
    exit 1
  fi
  msg_ok "Running as root"

  # Must be Proxmox (or at least Debian-based)
  if command -v pveversion &>/dev/null; then
    PVE_VER=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+')
    msg_ok "Proxmox VE ${PVE_VER} detected"
  else
    msg_warn "Proxmox VE not detected — installing as generic Debian monitor"
    PVE_VER="generic"
  fi

  # Python3 required
  if ! command -v python3 &>/dev/null; then
    msg_error "Python 3 is required but not found."
    exit 1
  fi
  PYTHON_VER=$(python3 --version 2>&1 | grep -oP '[0-9]+\.[0-9]+')
  msg_ok "Python ${PYTHON_VER} found"

  echo ""
}

# ── Detect Hardware ──────────────────────────────────────────────────
detect_hardware() {
  msg_info "Detecting hardware..."

  # System model
  SYSTEM_MODEL=$(dmidecode -s system-product-name 2>/dev/null || echo "Unknown")
  SYSTEM_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null || echo "Unknown")
  BIOS_VER=$(dmidecode -s bios-version 2>/dev/null || echo "Unknown")
  msg_ok "System: ${SYSTEM_VENDOR} ${SYSTEM_MODEL} (BIOS: ${BIOS_VER})"

  # CPU info
  CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
  CPU_CORES=$(nproc 2>/dev/null || echo "?")
  msg_ok "CPU: ${CPU_MODEL} (${CPU_CORES} threads)"

  # Detect hwmon devices
  msg_info "Scanning hwmon sensors..."
  declare -gA HWMON_MAP
  HWMON_LIST=""
  for hw in /sys/class/hwmon/hwmon*/; do
    idx=$(basename "$hw")
    name=$(cat "${hw}name" 2>/dev/null || echo "unknown")
    HWMON_MAP[$name]="${hw}"
    HWMON_LIST="${HWMON_LIST}  ${idx} = ${name}\n"
  done
  echo -e "${DM}${HWMON_LIST}${CL}"

  # Coretemp
  HW_CORETEMP="${HWMON_MAP[coretemp]:-}"
  if [[ -n "$HW_CORETEMP" ]]; then
    msg_ok "CPU temp sensor: coretemp (${HW_CORETEMP})"
  else
    # Try k10temp for AMD
    HW_CORETEMP="${HWMON_MAP[k10temp]:-}"
    if [[ -n "$HW_CORETEMP" ]]; then
      msg_ok "CPU temp sensor: k10temp (${HW_CORETEMP})"
    else
      msg_warn "No CPU temp sensor found"
    fi
  fi

  # NVMe
  HW_NVME="${HWMON_MAP[nvme]:-}"
  if [[ -n "$HW_NVME" ]]; then
    msg_ok "NVMe temp sensor found (${HW_NVME})"
  else
    msg_warn "No NVMe sensor found"
  fi

  # PCH (Intel chipset)
  HW_PCH=""
  for name in pch_skylake pch_cannonlake pch_cometlake pch_alderlake pch_raptorlake; do
    if [[ -n "${HWMON_MAP[$name]:-}" ]]; then
      HW_PCH="${HWMON_MAP[$name]}"
      msg_ok "PCH temp sensor: ${name} (${HW_PCH})"
      break
    fi
  done
  [[ -z "$HW_PCH" ]] && msg_warn "No PCH sensor found"

  # EC (Embedded Controller) — for laptops
  HAS_EC="false"
  if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    HAS_EC="true"
    msg_ok "EC (Embedded Controller) accessible"
    # Try to load ec_sys with write support
    if ! lsmod | grep -q ec_sys; then
      modprobe ec_sys write_support=1 2>/dev/null || true
    fi
  else
    msg_info "No EC found (normal for desktops/servers)"
  fi

  # ASUS fan_boost_mode
  HAS_BOOST="false"
  BOOST_PATH=""
  if [[ -f /sys/devices/platform/asus-nb-wmi/fan_boost_mode ]]; then
    HAS_BOOST="true"
    BOOST_PATH="/sys/devices/platform/asus-nb-wmi/fan_boost_mode"
    msg_ok "ASUS fan_boost_mode available"
  elif [[ -f /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy ]]; then
    HAS_BOOST="true"
    BOOST_PATH="/sys/devices/platform/asus-nb-wmi/throttle_thermal_policy"
    msg_ok "ASUS throttle_thermal_policy available"
  fi

  # IPMI (for servers)
  HAS_IPMI="false"
  if command -v ipmitool &>/dev/null; then
    HAS_IPMI="true"
    msg_ok "IPMI tools available"
  fi

  # Battery
  BAT_PATH=""
  for bat in BAT0 BAT1 BATT; do
    if [[ -d "/sys/class/power_supply/${bat}" ]]; then
      BAT_PATH="/sys/class/power_supply/${bat}"
      msg_ok "Battery found: ${bat}"
      break
    fi
  done
  [[ -z "$BAT_PATH" ]] && msg_info "No battery (normal for desktops/servers)"

  # Fan sensors via lm-sensors
  HAS_HWMON_FAN="false"
  for f in /sys/class/hwmon/hwmon*/fan*_input; do
    if [[ -f "$f" ]]; then
      val=$(cat "$f" 2>/dev/null || echo 0)
      if [[ "$val" -gt 0 ]]; then
        HAS_HWMON_FAN="true"
        msg_ok "Hardware fan sensor found: ${f} (${val} RPM)"
        break
      fi
    fi
  done

  # Detect EC fan RPM registers (ASUS laptops)
  EC_FAN_REGS="false"
  if [[ "$HAS_EC" == "true" ]]; then
    # Check if 0x66-0x69 have plausible fan values
    val=$(python3 -c "
import struct
try:
    with open('/sys/kernel/debug/ec/ec0/io','rb') as f:
        f.seek(0x66); r=struct.unpack('<H',f.read(2))[0]
        if 100 < r < 10000: print('yes')
        else: print('no')
except: print('no')
" 2>/dev/null)
    if [[ "$val" == "yes" ]]; then
      EC_FAN_REGS="true"
      msg_ok "EC fan RPM registers detected (0x66/0x68)"
    fi
  fi

  # Detect host IP
  HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -z "$HOST_IP" ]]; then
    HOST_IP="127.0.0.1"
  fi
  msg_ok "Host IP: ${HOST_IP}"

  echo ""
}

# ── Install Dependencies ─────────────────────────────────────────────
install_deps() {
  msg_info "Installing dependencies..."

  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq lm-sensors >/dev/null 2>&1
  msg_ok "lm-sensors installed"

  # Run sensors-detect non-interactively
  if ! sensors &>/dev/null; then
    yes "" | sensors-detect --auto >/dev/null 2>&1 || true
    msg_ok "Sensors auto-detected"
  fi

  echo ""
}

# ── Generate API Server ──────────────────────────────────────────────
generate_api() {
  msg_info "Generating API server..."

  mkdir -p "${INSTALL_DIR}"

  cat > "${INSTALL_DIR}/${API_FILE}" << 'APIEOF'
#!/usr/bin/env python3
"""PVE Hardware Monitor API — auto-generated by installer"""
import http.server, json, struct, os, glob

PORT = __PORT__
EC_PATH = '/sys/kernel/debug/ec/ec0/io'
BOOST_PATH = '__BOOST_PATH__'
BAT_PATH = '__BAT_PATH__'
HW_CORETEMP = '__HW_CORETEMP__'
HW_NVME = '__HW_NVME__'
HW_PCH = '__HW_PCH__'
HAS_EC = __HAS_EC__
EC_FAN_REGS = __EC_FAN_REGS__
HAS_BOOST = __HAS_BOOST__
SYSTEM_MODEL = '__SYSTEM_MODEL__'
BIOS_VER = '__BIOS_VER__'

def read_ec(o, c=1):
    if not HAS_EC: return None
    try:
        with open(EC_PATH, 'rb') as f: f.seek(o); return f.read(c)
    except: return None

def rf(p):
    if not p: return None
    try:
        with open(p) as f: return f.read().strip()
    except: return None

def ri(p):
    v = rf(p)
    return int(v) if v and v.lstrip('-').isdigit() else None

def wf(p, v):
    try:
        with open(p, 'w') as f: f.write(str(v)); return True
    except Exception as e: return str(e)

def get_temps(hw_path, prefix='temp', max_idx=10):
    if not hw_path: return []
    items = []
    for i in range(1, max_idx):
        t = ri(f'{hw_path}temp{i}_input')
        lbl = rf(f'{hw_path}temp{i}_label')
        if t is not None:
            items.append({'label': lbl or f'Sensor {i}', 'temp': round(t/1000, 1)})
    return items

def get_fans_hwmon():
    """Get fan RPM from any hwmon fan*_input"""
    fans = []
    for f in sorted(glob.glob('/sys/class/hwmon/hwmon*/fan*_input')):
        val = ri(f)
        if val is not None:
            hwname = rf(os.path.join(os.path.dirname(f), 'name')) or '?'
            label = rf(f.replace('_input', '_label')) or os.path.basename(f).replace('_input','')
            fans.append({'name': f'{hwname}/{label}', 'rpm': val, 'source': 'hwmon'})
    return fans

def get_fans_ec():
    """Get fan RPM from EC registers (ASUS laptops)"""
    if not EC_FAN_REGS: return []
    fans = []
    for name, offset, duty_offset in [('CPU', 0x66, 0x97), ('GPU', 0x68, 0x98)]:
        raw_b = read_ec(offset, 2)
        duty_b = read_ec(duty_offset)
        raw = struct.unpack('<H', raw_b)[0] if raw_b else 0
        duty = struct.unpack('B', duty_b)[0] if duty_b else 0
        rpm = round(2156250 / raw) if raw > 0 else 0
        fans.append({'name': name, 'rpm': rpm, 'raw': raw, 'duty': duty, 'source': 'ec'})
    return fans

def get_battery():
    if not BAT_PATH or not os.path.isdir(BAT_PATH): return None
    status = rf(f'{BAT_PATH}/status'); capacity = ri(f'{BAT_PATH}/capacity')
    e_now = ri(f'{BAT_PATH}/energy_now') or ri(f'{BAT_PATH}/charge_now')
    e_full = ri(f'{BAT_PATH}/energy_full') or ri(f'{BAT_PATH}/charge_full')
    power = ri(f'{BAT_PATH}/power_now') or ri(f'{BAT_PATH}/current_now')
    voltage = ri(f'{BAT_PATH}/voltage_now')
    return {
        'status': status or 'Unknown', 'capacity': capacity,
        'energy_now': round(e_now/1e6, 2) if e_now else None,
        'energy_full': round(e_full/1e6, 2) if e_full else None,
        'power': round(power/1e6, 2) if power else None,
        'voltage': round(voltage/1e6, 2) if voltage else None,
    }

def get_system():
    uptime = None
    try:
        with open('/proc/uptime') as f: uptime = float(f.read().split()[0])
    except: pass
    load = None
    try:
        with open('/proc/loadavg') as f: p = f.read().split(); load = [float(p[0]),float(p[1]),float(p[2])]
    except: pass
    mem = {}
    try:
        with open('/proc/meminfo') as f:
            for l in f:
                if l.startswith('MemTotal:'): mem['total'] = int(l.split()[1])//1024
                elif l.startswith('MemAvailable:'): mem['available'] = int(l.split()[1])//1024
    except: pass
    if 'total' in mem and 'available' in mem:
        mem['used'] = mem['total'] - mem['available']
        mem['pct'] = round(mem['used']/mem['total']*100, 1)
    return {'uptime_s': uptime, 'load': load, 'mem': mem}

def get_status():
    ec_temp_b = read_ec(0x58)
    ec_temp = struct.unpack('B', ec_temp_b)[0] if ec_temp_b else None
    board_b = read_ec(0xC5)
    board_temp = struct.unpack('B', board_b)[0] if board_b else None

    coretemp_list = get_temps(HW_CORETEMP)
    pkg_temp = coretemp_list[0]['temp'] if coretemp_list else ec_temp
    core_temps = coretemp_list[1:] if len(coretemp_list) > 1 else []

    nvme = get_temps(HW_NVME)
    pch_list = get_temps(HW_PCH)
    pch_temp = pch_list[0]['temp'] if pch_list else None

    # Fans: prefer EC, fall back to hwmon
    fans_ec = get_fans_ec()
    fans_hw = get_fans_hwmon()
    fans = fans_ec if fans_ec else fans_hw

    battery = get_battery()
    system = get_system()

    boost_str = rf(BOOST_PATH) if HAS_BOOST else None
    bv = int(boost_str) if boost_str and boost_str.isdigit() else None

    return {
        'ok': True,
        'model': SYSTEM_MODEL, 'bios': BIOS_VER,
        'cpu_temp': pkg_temp, 'core_temps': core_temps,
        'ec_temp': ec_temp, 'board_temp': board_temp, 'pch_temp': pch_temp,
        'nvme': nvme, 'fans': fans, 'battery': battery, 'system': system,
        'mode': {0:'normal',1:'boost',2:'silent'}.get(bv,'n/a') if bv is not None else 'n/a',
        'mode_raw': bv,
        'has_boost': HAS_BOOST,
    }

class Handler(http.server.BaseHTTPRequestHandler):
    def _c(self):
        self.send_header('Access-Control-Allow-Origin','*')
        self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Content-Type')
    def do_OPTIONS(self): self.send_response(200);self._c();self.end_headers()
    def _j(self,code,data):
        self.send_response(code);self.send_header('Content-Type','application/json')
        self._c();self.end_headers();self.wfile.write(json.dumps(data).encode())
    def do_GET(self):
        if self.path == '/api/status':
            try: self._j(200, get_status())
            except Exception as e: self._j(500, {'ok':False,'error':str(e)})
        elif self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type','text/html')
            self.end_headers()
            dash = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dashboard.html')
            with open(dash, 'rb') as f: self.wfile.write(f.read())
        else: self._j(404, {'ok':False,'error':'not found'})
    def do_POST(self):
        if self.path == '/api/mode' and HAS_BOOST:
            try:
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                mode = int(body.get('mode',0))
                if mode not in (0,1,2): self._j(400,{'ok':False,'error':'mode 0/1/2'});return
                names = {0:'Normal',1:'Boost',2:'Silent'}
                res = wf(BOOST_PATH, str(mode))
                if res is True: self._j(200,{'ok':True,'msg':f'Fan profile: {names[mode]}'})
                else: self._j(500,{'ok':False,'error':str(res)})
            except Exception as e: self._j(500,{'ok':False,'error':str(e)})
        else: self._j(404,{'ok':False,'error':'not found or fan control unavailable'})
    def log_message(self,*a): pass

print(f"PVE Hardware Monitor API on port {PORT}")
print(f"  Dashboard: http://0.0.0.0:{PORT}/")
http.server.HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()
APIEOF

  # Replace placeholders with detected values
  sed -i "s|__PORT__|${API_PORT}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BOOST_PATH__|${BOOST_PATH}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BAT_PATH__|${BAT_PATH}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_CORETEMP__|${HW_CORETEMP}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_NVME__|${HW_NVME}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_PCH__|${HW_PCH}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HAS_EC__|${HAS_EC^}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__EC_FAN_REGS__|${EC_FAN_REGS^}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HAS_BOOST__|${HAS_BOOST^}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__SYSTEM_MODEL__|${SYSTEM_MODEL}|g" "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BIOS_VER__|${BIOS_VER}|g" "${INSTALL_DIR}/${API_FILE}"

  chmod +x "${INSTALL_DIR}/${API_FILE}"
  msg_ok "API server generated at ${INSTALL_DIR}/${API_FILE}"
}

# ── Generate Dashboard HTML ──────────────────────────────────────────
generate_dashboard() {
  msg_info "Generating dashboard..."

  cat > "${INSTALL_DIR}/${DASHBOARD_FILE}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PVE Hardware Monitor</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&family=Outfit:wght@300;400;500;600;700&display=swap');
*{margin:0;padding:0;box-sizing:border-box}
:root{
  --bg:#07080b;
  --s1:#0e1117;--s2:#141920;--s3:#1b222e;--s4:#222b3a;
  --bdr:#1e2a3c;--bdr2:#2a3d56;--bdr3:#364f6b;
  --tx:#d6e4f5;--tx2:#8ba3be;--tx3:#4a6480;
  --blue:#3d8ef8;--cyan:#00c8d8;--green:#00df8c;
  --amber:#ffc030;--red:#ff3d5c;--violet:#a87fff;--teal:#00c9a7;
  --blue-a:rgba(61,142,248,.1);--cyan-a:rgba(0,200,216,.1);
  --green-a:rgba(0,223,140,.08);--red-a:rgba(255,61,92,.1);
  --amber-a:rgba(255,192,48,.08);--violet-a:rgba(168,127,255,.1);
}
body{font-family:'Outfit',sans-serif;background:var(--bg);color:var(--tx);min-height:100vh;overflow-x:hidden}
.bg-grid{position:fixed;inset:0;pointer-events:none;opacity:.025;
  background-image:linear-gradient(var(--bdr) 1px,transparent 1px),linear-gradient(90deg,var(--bdr) 1px,transparent 1px);
  background-size:32px 32px}
.bg-orb{position:fixed;border-radius:50%;pointer-events:none;filter:blur(140px)}
.orb1{width:600px;height:600px;top:-200px;left:-100px;background:radial-gradient(circle,rgba(61,142,248,.06),transparent 70%)}
.orb2{width:500px;height:500px;bottom:-150px;right:-80px;background:radial-gradient(circle,rgba(0,200,216,.05),transparent 70%)}
.orb3{width:300px;height:300px;top:40%;left:30%;background:radial-gradient(circle,rgba(0,223,140,.03),transparent 70%)}
.app{max-width:1120px;margin:0 auto;padding:20px 16px 32px;position:relative;z-index:1}

/* Header */
.hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px;padding:14px 18px;
  background:var(--s1);border:1px solid var(--bdr);border-radius:12px;flex-wrap:wrap;gap:10px}
.brand{display:flex;align-items:center;gap:14px}
.brand-icon{width:38px;height:38px;border-radius:9px;
  background:linear-gradient(135deg,#1a56ff 0%,#00c8d8 100%);
  display:grid;place-items:center;flex-shrink:0;position:relative;overflow:hidden}
.brand-icon::after{content:'';position:absolute;inset:0;background:linear-gradient(135deg,rgba(255,255,255,.15),transparent)}
.brand-icon svg{width:20px;height:20px;fill:none;stroke:#fff;stroke-width:2;stroke-linecap:round}
.brand-info h1{font-size:15px;font-weight:600;letter-spacing:-.2px;color:var(--tx)}
.brand-info small{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3);letter-spacing:.4px}
.hdr-right{display:flex;align-items:center;gap:10px}
.conn-pill{display:flex;align-items:center;gap:7px;padding:6px 14px;
  background:var(--s2);border:1px solid var(--bdr);border-radius:99px;
  font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3)}
.pulse{width:7px;height:7px;border-radius:50%;background:var(--red);flex-shrink:0;position:relative;transition:background .3s}
.pulse.ok{background:var(--green);box-shadow:0 0 0 3px rgba(0,223,140,.15)}
@keyframes ping{75%,100%{transform:scale(2.5);opacity:0}}
.btn{padding:6px 12px;background:var(--s2);border:1px solid var(--bdr);border-radius:7px;
  color:var(--tx3);font-size:11px;font-family:'Outfit',sans-serif;cursor:pointer;transition:all .2s}
.btn:hover{border-color:var(--bdr3);color:var(--tx)}

/* Alert */
.alert-bar{display:none;align-items:center;gap:8px;padding:8px 14px;
  background:rgba(255,61,92,.07);border:1px solid rgba(255,61,92,.2);
  border-radius:8px;margin-bottom:12px;font-size:12px;color:#ff8099}
.alert-bar.show{display:flex}
.alert-bar svg{flex-shrink:0;width:14px;height:14px;stroke:#ff3d5c;stroke-width:2;fill:none}

/* Section label */
.sec{font-size:10px;font-weight:500;text-transform:uppercase;letter-spacing:1.2px;
  color:var(--tx3);margin-bottom:8px;padding-left:2px;display:flex;align-items:center;gap:8px;margin-top:12px}
.sec::after{content:'';flex:1;height:1px;background:var(--bdr)}

/* Grid */
.g{display:grid;gap:10px;margin-bottom:0}
.g2{grid-template-columns:1fr 1fr}
.g3{grid-template-columns:1fr 1fr 1fr}

/* Card */
.c{background:var(--s1);border:1px solid var(--bdr);border-radius:11px;padding:16px;
  position:relative;overflow:hidden;transition:border-color .25s}
.c:hover{border-color:var(--bdr2)}
.c-full{grid-column:1/-1}
.c-accent{position:absolute;top:0;left:0;right:0;height:2px;border-radius:11px 11px 0 0}
.c-bg{position:absolute;top:-40px;right:-40px;width:110px;height:110px;border-radius:50%;filter:blur(40px);opacity:.05;pointer-events:none}

.lbl{font-size:10px;font-weight:500;text-transform:uppercase;letter-spacing:.9px;
  color:var(--tx3);margin-bottom:10px;display:flex;align-items:center;gap:7px}
.lbl-dot{width:5px;height:5px;border-radius:50%;flex-shrink:0}
.lbl-tag{font-family:'JetBrains Mono',monospace;font-size:9px;padding:2px 7px;
  border-radius:4px;background:var(--s3);border:1px solid var(--bdr);color:var(--tx3);margin-left:auto}

.big{font-family:'JetBrains Mono',monospace;font-size:40px;font-weight:600;
  line-height:1;letter-spacing:-2.5px;margin-bottom:4px}
.mid{font-family:'JetBrains Mono',monospace;font-size:24px;font-weight:500;line-height:1;letter-spacing:-1px}
.unit{font-size:13px;color:var(--tx3);font-weight:400;margin-left:2px;letter-spacing:0}
.sub{font-family:'JetBrains Mono',monospace;font-size:11px;color:var(--tx3);margin-top:3px}

/* Threshold bar */
.tbar{position:relative;width:100%;height:4px;background:var(--s4);border-radius:2px;margin:8px 0;overflow:hidden}
.tbar-f{height:100%;border-radius:2px;transition:width .6s cubic-bezier(.22,1,.36,1)}
.tbar-w{position:absolute;top:0;bottom:0;left:65%;width:1px;background:rgba(255,192,48,.35)}
.tbar-c{position:absolute;top:0;bottom:0;left:80%;width:1px;background:rgba(255,61,92,.35)}
.bar-track{width:100%;height:3px;background:var(--s4);border-radius:2px;margin:6px 0;overflow:hidden}
.bar-fill{height:100%;border-radius:2px;transition:width .6s cubic-bezier(.22,1,.36,1)}

/* Stat row */
.ms{display:flex;justify-content:space-between;align-items:center;
  font-family:'JetBrains Mono',monospace;font-size:10.5px;color:var(--tx3);
  padding:4px 0;border-bottom:1px solid rgba(255,255,255,.03)}
.ms:last-child{border-bottom:none}
.ms b{color:var(--tx);font-weight:500}

/* Chip grid */
.chip-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(88px,1fr));gap:6px}
.chip{background:var(--s2);border:1px solid var(--bdr);border-radius:8px;padding:9px 10px;text-align:center}
.chip-val{font-family:'JetBrains Mono',monospace;font-size:17px;font-weight:500;line-height:1}
.chip-name{font-size:9px;color:var(--tx3);margin-top:3px;font-family:'JetBrains Mono',monospace}
.chip-bar{width:100%;height:2px;background:var(--s4);border-radius:1px;margin-top:5px;overflow:hidden}
.chip-bar-f{height:100%;border-radius:1px;transition:width .5s}

/* Fan mode */
.mode-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:7px}
.mbtn{padding:13px 8px;border:1px solid var(--bdr);border-radius:9px;background:var(--s2);
  color:var(--tx2);cursor:pointer;font-family:'Outfit',sans-serif;font-size:12px;font-weight:500;
  transition:all .2s;text-align:center;line-height:1.3}
.mbtn:hover{border-color:var(--bdr3);background:var(--s3)}
.mbtn.on{border-color:var(--blue);background:var(--blue-a);color:var(--blue)}
.mbtn.on.boost{border-color:var(--red);background:var(--red-a);color:var(--red)}
.mbtn.on.silent{border-color:var(--green);background:var(--green-a);color:var(--green)}
.mbtn-icon{font-size:18px;display:block;margin-bottom:4px}
.mbtn-sub{font-size:8.5px;color:var(--tx3);display:block;margin-top:2px;font-family:'JetBrains Mono',monospace}

/* Gauge */
.gauge-wrap{display:flex;gap:14px;align-items:center;margin-bottom:10px}
.gauge{width:78px;height:78px;flex-shrink:0}
.gauge-info{flex:1}

/* Uptime parts */
.uptime-parts{display:flex;gap:7px;margin-bottom:10px}
.upart{background:var(--s3);border-radius:7px;padding:6px 10px;text-align:center;flex:1}
.upart-val{font-family:'JetBrains Mono',monospace;font-size:16px;font-weight:500;color:var(--cyan)}
.upart-lbl{font-size:9px;color:var(--tx3);margin-top:1px;font-family:'JetBrains Mono',monospace}

/* Battery */
.bat-outer{width:100%;height:18px;background:var(--s3);border-radius:5px;overflow:hidden;position:relative;margin:8px 0}
.bat-fill{height:100%;border-radius:5px;transition:width .6s}
.bat-label{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  font-family:'JetBrains Mono',monospace;font-size:10px;font-weight:500;color:rgba(255,255,255,.85)}

/* Chart */
.chart-wrap{position:relative;height:140px}
canvas{display:block;width:100%!important}

/* Toast */
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(90px);
  background:var(--s1);border:1px solid var(--bdr);border-radius:9px;
  padding:9px 18px;font-size:11.5px;z-index:99;
  transition:transform .3s cubic-bezier(.22,1,.36,1);box-shadow:0 8px 32px rgba(0,0,0,.5)}
.toast.show{transform:translateX(-50%) translateY(0)}
.toast.ok{border-color:rgba(0,223,140,.35);color:var(--green)}
.toast.err{border-color:rgba(255,61,92,.35);color:var(--red)}

/* Footer */
.ftr{font-family:'JetBrains Mono',monospace;font-size:9.5px;color:var(--tx3);
  display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;
  padding:12px 16px;background:var(--s1);border:1px solid var(--bdr);border-radius:9px;margin-top:10px}
.ftr b{color:var(--tx2);font-weight:500}
.ftr-item{display:flex;align-items:center;gap:5px}

/* Animations */
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.c{animation:fadeUp .35s ease both}
.g .c:nth-child(1){animation-delay:.04s}.g .c:nth-child(2){animation-delay:.08s}
.g .c:nth-child(3){animation-delay:.12s}.g .c:nth-child(4){animation-delay:.16s}

/* Responsive */
@media(max-width:760px){.g2,.g3{grid-template-columns:1fr 1fr}}
@media(max-width:480px){.g2,.g3{grid-template-columns:1fr}}
::-webkit-scrollbar{width:5px}::-webkit-scrollbar-track{background:var(--bg)}::-webkit-scrollbar-thumb{background:var(--bdr2);border-radius:3px}
</style>
</head>
<body>
<div class="bg-grid"></div>
<div class="bg-orb orb1"></div><div class="bg-orb orb2"></div><div class="bg-orb orb3"></div>

<div class="app">

  <!-- Header -->
  <div class="hdr">
    <div class="brand">
      <div class="brand-icon">
        <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5.6 5.6l2.1 2.1M16.3 16.3l2.1 2.1M5.6 18.4l2.1-2.1M16.3 7.7l2.1-2.1"/></svg>
      </div>
      <div class="brand-info">
        <h1>PVE Hardware Monitor</h1>
        <small id="modelLabel">PROXMOX VE · SYSTEM MONITOR</small>
      </div>
    </div>
    <div class="hdr-right">
      <button class="btn" onclick="poll()">↻ Refresh</button>
      <div class="conn-pill">
        <div class="pulse" id="dot"></div>
        <span id="stxt">CONNECTING</span>
      </div>
    </div>
  </div>

  <!-- Alert bar -->
  <div class="alert-bar" id="alertBar">
    <svg viewBox="0 0 24 24"><path d="M10.3 3.3L1.5 18a2 2 0 0 0 1.7 3h17.6a2 2 0 0 0 1.7-3L13.7 3.3a2 2 0 0 0-3.4 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
    <span id="alertMsg"></span>
  </div>

  <!-- Fans -->
  <div class="sec">Fan speeds</div>
  <div class="g" id="fanGrid"></div>

  <!-- Temperatures -->
  <div class="sec">Temperatures</div>
  <div class="g g3">
    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--amber),transparent)"></div>
      <div class="c-bg" style="background:var(--amber)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--amber)"></div>CPU CORES</div>
      <div class="gauge-wrap">
        <svg class="gauge" viewBox="0 0 78 78">
          <circle cx="39" cy="39" r="30" fill="none" stroke="#1b222e" stroke-width="7"/>
          <circle cx="39" cy="39" r="30" fill="none" stroke="url(#cpuArcGrad)" stroke-width="7"
            stroke-linecap="round" stroke-dasharray="0 188" id="cpuArc"
            style="transition:stroke-dasharray .6s cubic-bezier(.22,1,.36,1);transform:rotate(-90deg);transform-origin:50% 50%"/>
          <defs><linearGradient id="cpuArcGrad" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="#ffc030"/><stop offset="100%" stop-color="#ff3d5c"/>
          </linearGradient></defs>
          <text x="39" y="36" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="14" font-weight="600" fill="#d6e4f5" id="cpuGaugeVal">--</text>
          <text x="39" y="48" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="8" fill="#4a6480">°C</text>
        </svg>
        <div class="gauge-info">
          <div class="lbl" style="margin-bottom:3px;font-size:9px">PACKAGE TEMP</div>
          <div class="big" id="cpuPkg" style="font-size:30px;color:var(--amber)">--<span class="unit">°C</span></div>
          <div class="sub" id="cpuPkgSub">--</div>
        </div>
      </div>
      <div class="chip-grid" id="coreGrid"></div>
      <div class="ms" style="margin-top:8px"><span>EC Temp</span><b id="ecT">--</b></div>
      <div class="ms"><span>PCH Chipset</span><b id="pchT">--</b></div>
    </div>

    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--violet),transparent)"></div>
      <div class="c-bg" style="background:var(--violet)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--violet)"></div>NVME STORAGE</div>
      <div class="chip-grid" id="nvmeGrid"></div>
      <div id="nvmeStats" style="margin-top:8px"></div>
    </div>

    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--green),transparent)"></div>
      <div class="c-bg" style="background:var(--green)"></div>
      <div class="lbl"><div class="lbl-dot" id="batDot" style="background:var(--green)"></div>BATTERY
        <span class="lbl-tag" id="batStatus">--</span>
      </div>
      <div class="gauge-wrap" style="margin-bottom:6px">
        <svg class="gauge" viewBox="0 0 78 78">
          <circle cx="39" cy="39" r="30" fill="none" stroke="#1b222e" stroke-width="7"/>
          <circle cx="39" cy="39" r="30" fill="none" stroke="url(#batGrad)" stroke-width="7"
            stroke-linecap="round" stroke-dasharray="0 188" id="batArc"
            style="transition:stroke-dasharray .6s;transform:rotate(-90deg);transform-origin:50% 50%"/>
          <defs><linearGradient id="batGrad" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="#00df8c" id="batG1"/><stop offset="100%" stop-color="#00c9a7" id="batG2"/>
          </linearGradient></defs>
          <text x="39" y="36" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="14" font-weight="600" fill="#d6e4f5" id="batPctGauge">--</text>
          <text x="39" y="48" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="8" fill="#4a6480">%</text>
        </svg>
        <div class="gauge-info">
          <div class="mid" id="batPct" style="color:var(--green)">--<span class="unit">%</span></div>
          <div class="sub" id="batSt" style="margin-top:4px">--</div>
        </div>
      </div>
      <div class="ms"><span>Power draw</span><b id="batP">--</b></div>
      <div class="ms"><span>Voltage</span><b id="batV">--</b></div>
      <div class="ms"><span>Capacity</span><b id="batE">--</b></div>
      <div class="ms" id="batCycleRow" style="display:none"><span>Charge cycles</span><b id="batCycles">--</b></div>
    </div>
  </div>

  <!-- System + Fan Profile -->
  <div class="sec">System</div>
  <div class="g g2">
    <div class="c">
      <div class="lbl"><div class="lbl-dot" style="background:var(--teal)"></div>SYSTEM METRICS</div>
      <div class="uptime-parts" id="uptimeParts"></div>
      <div class="ms"><span>Load avg (1/5/15)</span><b id="sLoad">--</b></div>
      <div class="ms"><span>Memory</span><b id="sMem">--</b></div>
      <div class="bar-track"><div class="bar-fill" id="memBar" style="width:0%;background:linear-gradient(90deg,var(--teal),var(--cyan))"></div></div>
      <div class="ms"><span>Board temp</span><b id="boardT">--</b></div>
    </div>
    <div class="c">
      <div class="lbl"><div class="lbl-dot" style="background:var(--blue)"></div>FAN PROFILE</div>
      <div class="mode-grid">
        <button class="mbtn silent" id="m2" onclick="setMode(2)">
          <span class="mbtn-icon">🤫</span>Silent<span class="mbtn-sub">LOW NOISE</span>
        </button>
        <button class="mbtn" id="m0" onclick="setMode(0)">
          <span class="mbtn-icon">⚖️</span>Normal<span class="mbtn-sub">BALANCED</span>
        </button>
        <button class="mbtn boost" id="m1" onclick="setMode(1)">
          <span class="mbtn-icon">🔥</span>Boost<span class="mbtn-sub">MAX PERF</span>
        </button>
      </div>
      <div style="margin-top:12px;padding-top:10px;border-top:1px solid var(--bdr)">
        <div class="ms"><span>Active profile</span><b id="fMode" style="color:var(--blue)">--</b></div>
        <div class="ms"><span>Last updated</span><b id="fTime">--</b></div>
      </div>
    </div>
  </div>

  <!-- History -->
  <div class="sec">History — 5 minutes</div>
  <div class="g">
    <div class="c c-full" style="padding-bottom:12px">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;flex-wrap:wrap;gap:8px">
        <div style="display:flex;gap:14px;flex-wrap:wrap" id="chartLegend"></div>
        <div style="display:flex;gap:5px">
          <button class="btn" id="btnRPM" onclick="setChart('rpm')" style="font-size:10px;padding:4px 10px">RPM</button>
          <button class="btn" id="btnTemp" onclick="setChart('temp')" style="font-size:10px;padding:4px 10px">TEMP</button>
          <button class="btn" id="btnAll" onclick="setChart('all')" style="font-size:10px;padding:4px 10px;border-color:var(--blue);color:var(--blue)">ALL</button>
        </div>
      </div>
      <div class="chart-wrap"><canvas id="chart" height="140"></canvas></div>
    </div>
  </div>

  <!-- Footer -->
  <div class="ftr">
    <div class="ftr-item">Model&nbsp;<b id="fModel">--</b></div>
    <div class="ftr-item">API&nbsp;<b>:9099</b></div>
    <div class="ftr-item">Poll&nbsp;<b>3s</b></div>
    <div class="ftr-item">Updated&nbsp;<b id="fTime2">--</b></div>
    <div class="ftr-item">Uptime&nbsp;<b id="fUptime">--</b></div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const API = 'http://10.100.102.18:9099';
const CIRC = 2 * Math.PI * 30; // ~188 for r=30
const H = { cpuR:[], gpuR:[], cpuT:[], nvmeT:[] };
const MAX = 100;
let chartMode = 'all';

function tc(t){if(!t)return'var(--tx3)';if(t>85)return'var(--red)';if(t>70)return'var(--amber)';if(t>55)return'#f0c040';return'var(--green)'}
function tcNvme(t){if(!t)return'var(--tx3)';if(t>70)return'var(--red)';if(t>55)return'var(--amber)';return'var(--violet)'}
function setEl(id,v){const e=document.getElementById(id);if(e)e.textContent=v}
function setColor(id,c){const e=document.getElementById(id);if(e)e.style.color=c}
function setWidth(id,p){const e=document.getElementById(id);if(e)e.style.width=Math.max(0,Math.min(100,p))+'%'}
function setArc(id,pct){const el=document.getElementById(id);if(!el)return;const f=Math.max(0,Math.min(1,pct/100))*CIRC;el.setAttribute('stroke-dasharray',f.toFixed(1)+' '+CIRC)}
function fmtUptime(s){if(!s)return{d:0,h:0,m:0};return{d:Math.floor(s/86400),h:Math.floor(s%86400/3600),m:Math.floor(s%3600/60)}}

function setChart(mode){
  chartMode=mode;
  ['btnRPM','btnTemp','btnAll'].forEach(id=>{const b=document.getElementById(id);b.style.borderColor='';b.style.color=''});
  const k={rpm:'btnRPM',temp:'btnTemp',all:'btnAll'}[mode];
  document.getElementById(k).style.borderColor='var(--blue)';
  document.getElementById(k).style.color='var(--blue)';
  drawChart();
}

function drawChart(){
  const cv=document.getElementById('chart'),ctx=cv.getContext('2d');
  const dpr=window.devicePixelRatio||1,rect=cv.getBoundingClientRect();
  cv.width=rect.width*dpr;cv.height=140*dpr;ctx.scale(dpr,dpr);
  const W=rect.width,HH=140;ctx.clearRect(0,0,W,HH);
  if(H.cpuR.length<2)return;
  const n=H.cpuR.length,P={t:10,b:22,l:4,r:4};
  const cw=W-P.l-P.r,ch=HH-P.t-P.b;
  const x=i=>P.l+(i/(n-1))*cw;
  // Grid
  ctx.strokeStyle='rgba(30,42,60,.8)';ctx.lineWidth=.5;
  for(let i=0;i<=4;i++){const y=P.t+(ch/4)*i;ctx.beginPath();ctx.moveTo(P.l,y);ctx.lineTo(W-P.r,y);ctx.stroke()}
  const series=[];
  if(chartMode==='rpm'||chartMode==='all'){
    const maxR=Math.max(500,...H.cpuR,...H.gpuR);
    const yR=v=>P.t+ch-(v/maxR)*ch;
    series.push({data:H.cpuR,color:'#3d8ef8',y:yR,label:'CPU fan',unit:'RPM',width:1.5});
    series.push({data:H.gpuR,color:'#00c8d8',y:yR,label:'GPU fan',unit:'RPM',width:1.5});
  }
  if(chartMode==='temp'||chartMode==='all'){
    const minT=Math.min(25,...H.cpuT),maxT=Math.max(60,...H.cpuT);
    const yT=v=>P.t+ch-((v-minT+2)/(maxT-minT+4))*ch;
    series.push({data:H.cpuT,color:'#ffc030',y:yT,label:'CPU temp',unit:'°C',dash:[3,3],width:1.5});
    if(H.nvmeT.some(v=>v>0))
      series.push({data:H.nvmeT,color:'#a87fff',y:yT,label:'NVMe',unit:'°C',dash:[2,4],width:1});
  }
  if(series.length>0){
    const s=series[0];
    ctx.beginPath();
    s.data.forEach((v,i)=>i?ctx.lineTo(x(i),s.y(v)):ctx.moveTo(x(i),s.y(v)));
    ctx.lineTo(x(n-1),HH-P.b);ctx.lineTo(x(0),HH-P.b);ctx.closePath();
    ctx.fillStyle=s.color+'12';ctx.fill();
  }
  series.forEach(s=>{
    ctx.beginPath();ctx.strokeStyle=s.color;ctx.lineWidth=s.width||1.5;
    ctx.lineJoin='round';ctx.lineCap='round';
    if(s.dash)ctx.setLineDash(s.dash);else ctx.setLineDash([]);
    s.data.forEach((v,i)=>i?ctx.lineTo(x(i),s.y(v)):ctx.moveTo(x(i),s.y(v)));
    ctx.stroke();ctx.setLineDash([]);
    ctx.beginPath();ctx.arc(x(n-1),s.y(s.data[n-1]),3,0,Math.PI*2);
    ctx.fillStyle=s.color;ctx.fill();
  });
  ctx.font='400 9px "JetBrains Mono",monospace';
  let lx=P.l+2;
  series.forEach(s=>{
    const last=s.data[n-1];
    ctx.fillStyle=s.color;
    ctx.beginPath();if(ctx.roundRect)ctx.roundRect(lx,HH-P.b+4,8,8,2);else ctx.rect(lx,HH-P.b+4,8,8);
    ctx.fill();
    ctx.fillText(s.label+'  '+last+s.unit,lx+11,HH-P.b+11);
    lx+=ctx.measureText(s.label+'  '+last+s.unit).width+22;
  });
}

function renderFans(fans){
  const grid=document.getElementById('fanGrid');
  const colors=['--blue','--cyan','--teal','--violet'];
  if(grid.children.length!==fans.length){
    grid.innerHTML='';
    grid.style.gridTemplateColumns=fans.length===1?'1fr':fans.length===2?'1fr 1fr':'repeat(3,1fr)';
    fans.forEach((f,i)=>{
      const col=colors[i%colors.length],card=document.createElement('div');
      card.className='c';card.id='fanCard'+i;
      card.innerHTML=`
        <div class="c-accent" style="background:linear-gradient(90deg,var(${col}),transparent)"></div>
        <div class="c-bg" style="background:var(${col})"></div>
        <div class="lbl"><div class="lbl-dot" style="background:var(${col})"></div>${f.name.toUpperCase()} FAN
          <span class="lbl-tag" id="fanDuty${i}">--</span></div>
        <div class="big" style="color:var(${col})" id="fanRpm${i}">--<span class="unit">RPM</span></div>
        <div class="tbar"><div class="tbar-f" id="fanBar${i}" style="width:0%;background:linear-gradient(90deg,var(${col}),var(--cyan))"></div>
          <div class="tbar-w"></div><div class="tbar-c"></div></div>
        <div class="ms"><span>Duty cycle</span><b id="fanDutyPct${i}">--</b></div>
        <div class="ms"><span>EC raw</span><b id="fanRaw${i}">--</b></div>
        <div class="ms"><span>Source</span><b id="fanSrc${i}" style="color:var(${col})">--</b></div>`;
      grid.appendChild(card);
    });
  }
  fans.forEach((f,i)=>{
    const pct=Math.min(100,(f.rpm||0)/6500*100);
    document.getElementById('fanRpm'+i).innerHTML=`${f.rpm||0}<span class="unit">RPM</span>`;
    setWidth('fanBar'+i,pct);
    setEl('fanDuty'+i,(f.duty??'--')+'/8');
    setEl('fanDutyPct'+i,f.duty!=null?Math.round(f.duty/8*100)+'%':'--');
    setEl('fanRaw'+i,f.raw||'--');
    setEl('fanSrc'+i,(f.source||'hwmon').toUpperCase());
  });
}

async function poll(){
  try{
    const r=await fetch(API+'/api/status',{signal:AbortSignal.timeout(4000)});
    const d=await r.json();if(!d.ok)throw 0;
    document.getElementById('dot').className='pulse ok';
    setEl('stxt','LIVE');
    setEl('modelLabel',(d.model||'PROXMOX HOST')+' · PVE HARDWARE MONITOR');
    setEl('fModel',d.model||'--');
    const now=new Date().toLocaleTimeString();
    setEl('fTime',now);setEl('fTime2',now);

    if(d.fans)renderFans(d.fans);

    // CPU temp
    const cpuT=d.cpu_temp||0;
    document.getElementById('cpuPkg').innerHTML=`${cpuT}<span class="unit">°C</span>`;
    document.getElementById('cpuPkg').style.color=tc(cpuT);
    setEl('cpuPkgSub',cpuT>80?'⚠ HIGH':cpuT>65?'WARM':'NORMAL');
    setEl('cpuGaugeVal',cpuT);
    setArc('cpuArc',cpuT);
    // Cores
    if(d.core_temps&&d.core_temps.length){
      document.getElementById('coreGrid').innerHTML=d.core_temps.map(c=>{
        const p=Math.min(100,(c.temp/100)*100);
        return`<div class="chip"><div class="chip-val" style="color:${tc(c.temp)}">${c.temp}°</div><div class="chip-name">${c.label}</div><div class="chip-bar"><div class="chip-bar-f" style="width:${p}%;background:${tc(c.temp)}"></div></div></div>`;
      }).join('');
    }
    setEl('ecT',d.ec_temp!=null?d.ec_temp+'°C':'--');
    setEl('pchT',d.pch_temp!=null?d.pch_temp+'°C':'--');
    setEl('boardT',d.board_temp!=null?d.board_temp+'°C':'--');
    setColor('ecT',tc(d.ec_temp));setColor('pchT',tc(d.pch_temp));setColor('boardT',tc(d.board_temp));

    // NVMe
    if(d.nvme&&d.nvme.length){
      document.getElementById('nvmeGrid').innerHTML=d.nvme.map(n=>{
        const p=Math.min(100,(n.temp/80)*100);
        return`<div class="chip"><div class="chip-val" style="color:${tcNvme(n.temp)}">${n.temp}°</div><div class="chip-name">${n.label}</div><div class="chip-bar"><div class="chip-bar-f" style="width:${p}%;background:${tcNvme(n.temp)}"></div></div></div>`;
      }).join('');
      document.getElementById('nvmeStats').innerHTML=d.nvme.map(n=>`<div class="ms"><span>${n.label}</span><b style="color:${tcNvme(n.temp)}">${n.temp}°C</b></div>`).join('');
    }

    // Battery
    const b=d.battery;
    if(b){
      const bp=b.capacity||0;
      const bc=bp<20?'var(--red)':bp<45?'var(--amber)':'var(--green)';
      document.getElementById('batPct').innerHTML=`${bp}<span class="unit">%</span>`;
      document.getElementById('batPct').style.color=bc;
      setEl('batStatus',b.status||'--');setEl('batSt',b.status||'--');
      setEl('batPctGauge',bp);setArc('batArc',bp);
      document.getElementById('batG1').setAttribute('stop-color',bp<20?'#ff3d5c':bp<45?'#ffc030':'#00df8c');
      document.getElementById('batG2').setAttribute('stop-color',bp<20?'#ff6080':bp<45?'#ffdb80':'#00c9a7');
      setEl('batP',b.power!=null?b.power+' W':'--');
      setEl('batV',b.voltage!=null?b.voltage+' V':'--');
      setEl('batE',b.energy_now!=null?`${b.energy_now} / ${b.energy_full} Wh`:'--');
      if(b.cycles!=null){document.getElementById('batCycleRow').style.display='flex';setEl('batCycles',b.cycles+' cycles')}
    }

    // System
    const s=d.system;
    if(s){
      const ut=fmtUptime(s.uptime_s);
      document.getElementById('uptimeParts').innerHTML=[{val:ut.d,lbl:'DAYS'},{val:ut.h,lbl:'HRS'},{val:ut.m,lbl:'MIN'}]
        .map(p=>`<div class="upart"><div class="upart-val">${String(p.val).padStart(2,'0')}</div><div class="upart-lbl">${p.lbl}</div></div>`).join('');
      setEl('sLoad',s.load?s.load.map(v=>v.toFixed(2)).join(' / '):'--');
      setEl('fUptime',`${ut.d}d ${ut.h}h ${ut.m}m`);
      if(s.mem&&s.mem.total){
        const ug=(s.mem.used/1024).toFixed(1),tg=(s.mem.total/1024).toFixed(1);
        setEl('sMem',`${ug} / ${tg} GB (${s.mem.pct}%)`);
        setWidth('memBar',s.mem.pct);
      }
    }

    // Fan mode
    const ml={normal:'Normal',boost:'Boost',silent:'Silent'};
    setEl('fMode',ml[d.mode]||d.mode||'--');
    setColor('fMode',d.mode==='boost'?'var(--red)':d.mode==='silent'?'var(--green)':'var(--blue)');
    if(d.has_boost!==false){
      ['m0','m1','m2'].forEach(id=>document.getElementById(id).classList.toggle('on',d.mode_raw===parseInt(id[1])));
    }

    // History + chart
    H.cpuR.push((d.fans[0]||{}).rpm||0);
    H.gpuR.push((d.fans[1]||{}).rpm||0);
    H.cpuT.push(d.cpu_temp||0);
    H.nvmeT.push(d.nvme&&d.nvme[0]?d.nvme[0].temp:0);
    if(H.cpuR.length>MAX){H.cpuR.shift();H.gpuR.shift();H.cpuT.shift();H.nvmeT.shift()}
    drawChart();

    // Alerts
    const alerts=[];
    if(d.cpu_temp>90)alerts.push('CPU '+d.cpu_temp+'°C — critical');
    if(d.nvme&&d.nvme.some(n=>n.temp>70))alerts.push('NVMe temp critical');
    if(d.battery&&d.battery.capacity<10)alerts.push('Battery '+d.battery.capacity+'% — very low');
    const ab=document.getElementById('alertBar');
    if(alerts.length){ab.classList.add('show');setEl('alertMsg',alerts.join('  ·  '))}
    else ab.classList.remove('show');

  }catch(e){
    document.getElementById('dot').className='pulse';
    setEl('stxt','OFFLINE');
  }
}

async function setMode(m){
  try{
    const r=await fetch(API+'/api/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m}),signal:AbortSignal.timeout(5000)});
    const d=await r.json();
    if(d.ok)toast('ok','✓ '+d.msg);else toast('err','✗ '+(d.error||'Failed'));
    setTimeout(poll,500);
  }catch(e){toast('err','✗ Connection failed')}
}

function toast(t,m){const e=document.getElementById('toast');e.textContent=m;e.className='toast '+t+' show';setTimeout(()=>e.className='toast',3000)}
window.addEventListener('resize',drawChart);
setChart('all');
poll();
setInterval(poll,3000);
</script>
</body>
</html>

HTMLEOF

  # Patch the API URL with the actual host IP detected at install time
  sed -i "s|http://10\.100\.102\.18:${API_PORT}|http://${HOST_IP}:${API_PORT}|g" "${INSTALL_DIR}/${DASHBOARD_FILE}"
  msg_ok "Dashboard generated at ${INSTALL_DIR}/${DASHBOARD_FILE} (API → http://${HOST_IP}:${API_PORT})"
}

# ── Create Systemd Service ───────────────────────────────────────────
create_service() {
  msg_info "Creating systemd service..."

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=PVE Hardware Monitor
After=network.target
Documentation=https://github.com/AviFR-dev/PVE-Hardware-Monitor

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${API_FILE}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  # Ensure ec_sys is loaded with write support on boot (for laptops)
  if [[ "$HAS_EC" == "true" ]]; then
    if ! grep -q "ec_sys" /etc/modules 2>/dev/null; then
      echo "ec_sys" >> /etc/modules
    fi
    if [[ ! -f /etc/modprobe.d/ec_sys.conf ]]; then
      echo "options ec_sys write_support=1" > /etc/modprobe.d/ec_sys.conf
    fi
    msg_ok "EC write support configured for boot"
  fi

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}" --quiet
  systemctl restart "${SERVICE_NAME}"

  # Wait for service to start
  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg_ok "Service ${SERVICE_NAME} is running"
  else
    msg_error "Service failed to start. Check: journalctl -u ${SERVICE_NAME}"
    exit 1
  fi
}

# ── Uninstall Function ───────────────────────────────────────────────
uninstall() {
  header
  msg_info "Uninstalling ${APP_NAME}..."

  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload

  rm -rf "${INSTALL_DIR}"
  msg_ok "${APP_NAME} has been removed."
  msg_info "Note: lm-sensors and ec_sys config were left intact."
  echo ""
  exit 0
}

# ── Print Summary ────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GN}${BD}  ╔══════════════════════════════════════════════╗"
  echo "  ║          Installation Complete!               ║"
  echo -e "  ╚══════════════════════════════════════════════╝${CL}"
  echo ""
  echo -e "  ${BD}Dashboard URL:${CL}"
  echo -e "  ${BL}${BD}  http://${HOST_IP}:${API_PORT}/${CL}"
  echo ""
  echo -e "  ${BD}API Endpoint:${CL}"
  echo -e "  ${DM}  http://${HOST_IP}:${API_PORT}/api/status${CL}"
  echo ""
  echo -e "  ${BD}Detected Hardware:${CL}"
  echo -e "  ${DM}  System:    ${SYSTEM_VENDOR} ${SYSTEM_MODEL}${CL}"
  echo -e "  ${DM}  CPU:       ${CPU_MODEL}${CL}"
  echo -e "  ${DM}  EC:        ${HAS_EC}  |  EC Fan Regs: ${EC_FAN_REGS}${CL}"
  echo -e "  ${DM}  ASUS Boost:${HAS_BOOST}  |  Battery: $([ -n "$BAT_PATH" ] && echo "yes" || echo "no")${CL}"
  echo ""
  echo -e "  ${BD}Management:${CL}"
  echo -e "  ${DM}  Status:    systemctl status ${SERVICE_NAME}${CL}"
  echo -e "  ${DM}  Logs:      journalctl -u ${SERVICE_NAME} -f${CL}"
  echo -e "  ${DM}  Restart:   systemctl restart ${SERVICE_NAME}${CL}"
  echo -e "  ${DM}  Uninstall: bash <(curl -fsSL URL) --uninstall${CL}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  # Handle --uninstall flag
  if [[ "${1:-}" == "--uninstall" ]]; then
    uninstall
  fi

  preflight
  detect_hardware
  install_deps
  generate_api
  generate_dashboard
  create_service
  print_summary
}

main "$@"
