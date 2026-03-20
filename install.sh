#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  PVE Hardware Monitor - Install Script
#  Real-time fan RPM, temps, battery & system monitoring for Proxmox
#  https://github.com/YOUR_USERNAME/pve-hardware-monitor
#
#  Usage:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/YOUR_USERNAME/pve-hardware-monitor/main/install.sh)"
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
  echo -e "  ${DM}Version ${APP_VERSION} · github.com/YOUR_USERNAME/pve-hardware-monitor${CL}"
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
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@300;400;500;600&family=DM+Sans:wght@400;500;600;700&display=swap');
*{margin:0;padding:0;box-sizing:border-box}
:root{--bg:#06090d;--s1:#0c1117;--s2:#111922;--s3:#172030;--bdr:#1a2640;--bdr2:#243352;--tx:#cdd8e8;--dim:#4a6080;--blue:#2d7ff9;--cyan:#00c2d1;--green:#00d48a;--amber:#ffb020;--red:#ff4060;--violet:#9775fa}
body{font-family:'DM Sans',sans-serif;background:var(--bg);color:var(--tx);min-height:100vh}
.noise{position:fixed;inset:0;opacity:.02;pointer-events:none;background:url("data:image/svg+xml,%3Csvg viewBox='0 0 512 512' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='.7' numOctaves='5' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E")}
.orb{position:fixed;border-radius:50%;filter:blur(120px);pointer-events:none;opacity:.04}
.orb1{width:500px;height:500px;top:-150px;left:-80px;background:var(--blue)}
.orb2{width:400px;height:400px;bottom:-100px;right:-50px;background:var(--cyan)}
.app{max-width:1080px;margin:0 auto;padding:24px 16px;position:relative;z-index:1}
.hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:24px;padding-bottom:16px;border-bottom:1px solid var(--bdr)}
.brand{display:flex;align-items:center;gap:12px}
.brand-mark{width:36px;height:36px;border-radius:8px;background:linear-gradient(135deg,var(--blue),var(--cyan));display:grid;place-items:center;font-size:18px;box-shadow:0 0 20px rgba(45,127,249,.2)}
.brand h1{font-size:16px;font-weight:600;letter-spacing:-.3px}
.brand small{display:block;font-size:10px;font-family:'IBM Plex Mono',monospace;color:var(--dim);margin-top:1px;letter-spacing:.5px}
.conn{display:flex;align-items:center;gap:6px;font-size:10px;font-family:'IBM Plex Mono',monospace;color:var(--dim);padding:5px 12px;background:var(--s1);border:1px solid var(--bdr);border-radius:99px}
.conn-dot{width:6px;height:6px;border-radius:50%;background:var(--red);transition:background .3s}
.conn-dot.ok{background:var(--green);box-shadow:0 0 8px rgba(0,212,138,.4)}
.g{display:grid;gap:12px;margin-bottom:12px}
.g2{grid-template-columns:1fr 1fr}.g3{grid-template-columns:1fr 1fr 1fr}
.c{background:var(--s1);border:1px solid var(--bdr);border-radius:10px;padding:16px;position:relative;overflow:hidden;transition:border-color .25s;animation:fadeUp .4s ease both}
.c:hover{border-color:var(--bdr2)}.c-full{grid-column:1/-1}
.c-glow{position:absolute;top:-25px;right:-25px;width:70px;height:70px;border-radius:50%;filter:blur(30px);opacity:.06}
.lbl{font-size:10px;font-weight:500;text-transform:uppercase;letter-spacing:.8px;color:var(--dim);margin-bottom:8px;display:flex;align-items:center;gap:6px}
.lbl-dot{width:6px;height:6px;border-radius:2px}
.tag{font-family:'IBM Plex Mono',monospace;font-size:9px;padding:2px 6px;border-radius:4px;background:var(--s2);border:1px solid var(--bdr);color:var(--dim)}
.big{font-family:'IBM Plex Mono',monospace;font-size:38px;font-weight:600;line-height:1;letter-spacing:-2px;margin-bottom:2px}
.mid{font-family:'IBM Plex Mono',monospace;font-size:22px;font-weight:500;line-height:1;letter-spacing:-1px}
.unit{font-size:12px;color:var(--dim);font-weight:400;margin-left:2px}
.sub{font-family:'IBM Plex Mono',monospace;font-size:11px;color:var(--dim);margin-top:2px}
.bar-bg{width:100%;height:3px;background:var(--s3);border-radius:2px;margin:8px 0;overflow:hidden}
.bar-f{height:100%;border-radius:2px;transition:width .5s cubic-bezier(.22,1,.36,1)}
.ms{display:flex;justify-content:space-between;font-family:'IBM Plex Mono',monospace;font-size:10px;color:var(--dim);padding:4px 0}
.ms b{color:var(--tx);font-weight:500}
.modes{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
.mbtn{padding:12px 10px;border:1px solid var(--bdr);border-radius:8px;background:var(--s2);color:var(--tx);cursor:pointer;font-family:'DM Sans',sans-serif;font-size:12px;font-weight:500;transition:all .2s;text-align:center}
.mbtn:hover{border-color:var(--bdr2);background:var(--s3)}
.mbtn.on{border-color:var(--blue);background:rgba(45,127,249,.08);color:var(--blue)}
.mbtn.on.boost{border-color:var(--red);background:rgba(255,64,96,.06);color:var(--red)}
.mbtn.on.silent{border-color:var(--green);background:rgba(0,212,138,.06);color:var(--green)}
.mbtn em{font-style:normal;font-size:16px;display:block;margin-bottom:2px}
.mbtn span{font-size:8px;color:var(--dim);display:block;margin-top:1px;font-family:'IBM Plex Mono',monospace}
.tg{display:grid;grid-template-columns:repeat(auto-fill,minmax(90px,1fr));gap:6px}
.tg-item{background:var(--s2);border-radius:6px;padding:8px 10px;text-align:center}
.tg-item .val{font-family:'IBM Plex Mono',monospace;font-size:16px;font-weight:500}
.tg-item .name{font-size:9px;color:var(--dim);margin-top:2px;font-family:'IBM Plex Mono',monospace}
canvas{width:100%!important;height:120px!important}
.bat-shell{width:100%;height:16px;background:var(--s3);border-radius:4px;overflow:hidden;position:relative}
.bat-fill{height:100%;border-radius:4px;transition:width .5s}
.bat-text{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-family:'IBM Plex Mono',monospace;font-size:9px;font-weight:500;color:var(--tx)}
.ftr{font-family:'IBM Plex Mono',monospace;font-size:9px;color:var(--dim);display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;padding-top:10px;border-top:1px solid var(--bdr);margin-top:4px}
.ftr b{color:var(--tx);font-weight:500}
.toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%) translateY(80px);background:var(--s1);border:1px solid var(--bdr);border-radius:8px;padding:8px 16px;font-size:11px;z-index:99;transition:transform .3s cubic-bezier(.22,1,.36,1);box-shadow:0 4px 20px rgba(0,0,0,.5)}
.toast.show{transform:translateX(-50%) translateY(0)}.toast.ok{border-color:rgba(0,212,138,.4)}.toast.err{border-color:rgba(255,64,96,.4)}
@keyframes fadeUp{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}
.g .c:nth-child(1){animation-delay:0s}.g .c:nth-child(2){animation-delay:.05s}.g .c:nth-child(3){animation-delay:.1s}.g .c:nth-child(4){animation-delay:.15s}
.hide{display:none!important}
@media(max-width:700px){.g2,.g3{grid-template-columns:1fr}.hdr{flex-direction:column;gap:10px;align-items:flex-start}.ftr{flex-direction:column}.big{font-size:32px}}
</style>
</head>
<body>
<div class="noise"></div><div class="orb orb1"></div><div class="orb orb2"></div>
<div class="app">
  <div class="hdr">
    <div class="brand"><div class="brand-mark">🌀</div><div><h1>Hardware Monitor</h1><small id="modelTxt">Proxmox VE</small></div></div>
    <div class="conn"><div class="conn-dot" id="dot"></div><span id="stxt">CONNECTING</span></div>
  </div>
  <!-- Fans -->
  <div class="g g2" id="fansGrid"></div>
  <!-- Temps + Battery + System -->
  <div class="g g3" id="infoRow">
    <div class="c"><div class="lbl"><div class="lbl-dot" style="background:var(--amber)"></div>CPU CORES</div><div class="tg" id="coreGrid"></div><div class="ms" style="margin-top:8px"><span>EC Temp</span><b id="ecT">--</b></div><div class="ms"><span>PCH</span><b id="pchT">--</b></div></div>
    <div class="c"><div class="lbl"><div class="lbl-dot" style="background:var(--violet)"></div>NVME STORAGE</div><div class="tg" id="nvmeGrid"></div></div>
    <div class="c" id="batCard"><div class="lbl"><div class="lbl-dot" style="background:var(--green)"></div>BATTERY</div><div class="mid" id="batPct" style="color:var(--green)">--<span class="unit">%</span></div><div class="sub" id="batSt">--</div><div class="bat-shell" style="margin-top:8px"><div class="bat-fill" id="batBar" style="width:0%;background:var(--green)"></div><div class="bat-text" id="batTxt">--</div></div><div class="ms" style="margin-top:8px"><span>Power</span><b id="batP">--</b></div><div class="ms"><span>Voltage</span><b id="batV">--</b></div><div class="ms"><span>Energy</span><b id="batE">--</b></div></div>
  </div>
  <!-- System + Fan Profile -->
  <div class="g g2">
    <div class="c"><div class="lbl"><div class="lbl-dot" style="background:var(--dim)"></div>SYSTEM</div><div class="ms"><span>Uptime</span><b id="sUp">--</b></div><div class="ms"><span>Load (1/5/15)</span><b id="sLoad">--</b></div><div class="ms"><span>Memory</span><b id="sMem">--</b></div><div class="bar-bg"><div class="bar-f" id="memBar" style="width:0%;background:var(--amber)"></div></div></div>
    <div class="c" id="modeCard"><div class="lbl"><div class="lbl-dot" style="background:var(--blue)"></div>FAN PROFILE</div><div class="modes"><button class="mbtn silent" id="m2" onclick="setMode(2)"><em>🤫</em>Silent<span>Quiet</span></button><button class="mbtn" id="m0" onclick="setMode(0)"><em>⚖️</em>Normal<span>Default</span></button><button class="mbtn boost" id="m1" onclick="setMode(1)"><em>🔥</em>Boost<span>Max</span></button></div></div>
  </div>
  <!-- Chart -->
  <div class="g"><div class="c c-full"><div class="lbl">HISTORY — 5 MINUTES</div><canvas id="chart"></canvas></div></div>
  <div class="ftr"><span>Model: <b id="fModel">--</b></span><span>BIOS: <b id="fBios">--</b></span><span>Mode: <b id="fMode">--</b></span><span>Updated: <b id="fTime">--</b></span></div>
</div>
<div class="toast" id="toast"></div>
<script>
const API=window.location.origin;
const H={fans:{},temp:[]},MAX=100;
const colors=['#2d7ff9','#00c2d1','#00d48a','#ffb020','#ff4060','#9775fa'];

function fmt_up(s){if(!s)return'--';const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?`${d}d ${h}h ${m}m`:`${h}h ${m}m`}
function tc(t){return t>80?'var(--red)':t>65?'var(--amber)':'var(--green)'}

function buildFanCards(fans){
  const g=document.getElementById('fansGrid');
  if(!fans||!fans.length)return;
  g.innerHTML=fans.map((f,i)=>{
    const col=colors[i%colors.length];
    const id=f.name.replace(/[^a-zA-Z0-9]/g,'');
    return`<div class="c"><div class="c-glow" style="background:${col}"></div>
      <div class="card-hd" style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px">
        <div class="lbl" style="margin:0"><div class="lbl-dot" style="background:${col}"></div>${f.name} FAN</div>
        ${f.duty!=null?`<span class="tag" id="${id}D">${f.duty}/8</span>`:''}
      </div>
      <div class="big" style="color:${col}" id="${id}R">${f.rpm}<span class="unit">RPM</span></div>
      <div class="bar-bg"><div class="bar-f" id="${id}B" style="width:0%;background:${col}"></div></div>
      <div class="ms"><span>Temperature</span><b id="${id}T">--</b></div>
      ${f.raw!=null?`<div class="ms"><span>EC Raw</span><b id="${id}W">${f.raw}</b></div>`:''}</div>`
  }).join('');
}

let fansBuilt=false;

async function poll(){
  try{
    const r=await fetch(API+'/api/status',{signal:AbortSignal.timeout(3000)});
    const d=await r.json();if(!d.ok)throw 0;
    document.getElementById('dot').className='conn-dot ok';
    document.getElementById('stxt').textContent='CONNECTED';
    document.getElementById('modelTxt').textContent=`${d.model||'Proxmox'} · Proxmox VE`;

    // Fans
    if(!fansBuilt&&d.fans&&d.fans.length){buildFanCards(d.fans);fansBuilt=true}
    if(d.fans)d.fans.forEach((f,i)=>{
      const id=f.name.replace(/[^a-zA-Z0-9]/g,''),col=colors[i%colors.length],mxR=6000;
      const el=n=>document.getElementById(id+n);
      if(el('R'))el('R').innerHTML=`${f.rpm}<span class="unit">RPM</span>`;
      if(el('B'))el('B').style.width=Math.min(100,f.rpm/mxR*100)+'%';
      if(el('D')&&f.duty!=null)el('D').textContent=f.duty+'/8';
      if(el('T'))el('T').textContent=(d.cpu_temp||'--')+'°C';
      if(el('W')&&f.raw!=null)el('W').textContent=f.raw;
      // History
      if(!H.fans[f.name])H.fans[f.name]=[];
      H.fans[f.name].push(f.rpm);
      if(H.fans[f.name].length>MAX)H.fans[f.name].shift();
    });
    H.temp.push(d.cpu_temp||0);if(H.temp.length>MAX)H.temp.shift();

    // Cores
    const cg=document.getElementById('coreGrid');
    if(d.core_temps&&d.core_temps.length)cg.innerHTML=d.core_temps.map(c=>`<div class="tg-item"><div class="val" style="color:${tc(c.temp)}">${c.temp}°</div><div class="name">${c.label}</div></div>`).join('');
    document.getElementById('ecT').textContent=(d.ec_temp||'--')+'°C';
    document.getElementById('pchT').textContent=(d.pch_temp||'--')+'°C';

    // NVMe
    const ng=document.getElementById('nvmeGrid');
    if(d.nvme&&d.nvme.length)ng.innerHTML=d.nvme.map(n=>`<div class="tg-item"><div class="val" style="color:${n.temp>70?'var(--red)':n.temp>55?'var(--amber)':'var(--violet)'}">${n.temp}°</div><div class="name">${n.label}</div></div>`).join('');

    // Battery
    const bc=document.getElementById('batCard');
    if(!d.battery){bc.classList.add('hide')}else{
      bc.classList.remove('hide');const b=d.battery,bp=b.capacity||0;
      document.getElementById('batPct').innerHTML=`${bp}<span class="unit">%</span>`;
      document.getElementById('batPct').style.color=bp<20?'var(--red)':bp<50?'var(--amber)':'var(--green)';
      document.getElementById('batSt').textContent=b.status;
      document.getElementById('batBar').style.width=bp+'%';
      document.getElementById('batBar').style.background=bp<20?'var(--red)':bp<50?'var(--amber)':'var(--green)';
      document.getElementById('batTxt').textContent=bp+'%';
      document.getElementById('batP').textContent=(b.power||'--')+' W';
      document.getElementById('batV').textContent=(b.voltage||'--')+' V';
      document.getElementById('batE').textContent=`${b.energy_now||'--'} / ${b.energy_full||'--'} Wh`;
    }

    // System
    if(d.system){
      document.getElementById('sUp').textContent=fmt_up(d.system.uptime_s);
      document.getElementById('sLoad').textContent=d.system.load?d.system.load.join(' / '):'--';
      if(d.system.mem&&d.system.mem.total){
        document.getElementById('sMem').textContent=`${d.system.mem.used}/${d.system.mem.total} MB (${d.system.mem.pct}%)`;
        document.getElementById('memBar').style.width=d.system.mem.pct+'%';
      }
    }

    // Mode
    const mc=document.getElementById('modeCard');
    if(!d.has_boost)mc.classList.add('hide');
    else{mc.classList.remove('hide');['m0','m1','m2'].forEach(id=>{document.getElementById(id).classList.toggle('on',d.mode_raw===parseInt(id[1]))})}
    document.getElementById('fModel').textContent=d.model||'--';
    document.getElementById('fBios').textContent=d.bios||'--';
    document.getElementById('fMode').textContent=d.mode||'--';
    document.getElementById('fTime').textContent=new Date().toLocaleTimeString();

    drawChart();
  }catch(e){
    document.getElementById('dot').className='conn-dot';
    document.getElementById('stxt').textContent='DISCONNECTED';
  }
}

function drawChart(){
  const cv=document.getElementById('chart'),ctx=cv.getContext('2d');
  const dpr=window.devicePixelRatio||1,rect=cv.getBoundingClientRect();
  cv.width=rect.width*dpr;cv.height=120*dpr;ctx.scale(dpr,dpr);
  const W=rect.width,HH=120;ctx.clearRect(0,0,W,HH);
  const n=H.temp.length;if(n<2)return;
  const allRPM=Object.values(H.fans).flat();
  const maxR=Math.max(300,...allRPM),maxT=Math.max(60,...H.temp),minT=Math.min(30,...H.temp);
  const p={t:8,b:20,l:0,r:0},cw=W,ch=HH-p.t-p.b;
  const x=i=>p.l+(i/(n-1))*cw,yR=v=>p.t+ch-(v/maxR)*ch,yT=v=>p.t+ch-((v-minT+3)/(maxT-minT+6))*ch;
  ctx.strokeStyle='rgba(26,38,64,.6)';ctx.lineWidth=.5;
  for(let i=0;i<3;i++){const y=p.t+(ch/2)*i;ctx.beginPath();ctx.moveTo(0,y);ctx.lineTo(W,y);ctx.stroke()}
  let ci=0;
  Object.entries(H.fans).forEach(([name,data])=>{
    const col=colors[ci%colors.length];ci++;
    if(ci===1){ctx.beginPath();data.forEach((v,i)=>i?ctx.lineTo(x(i),yR(v)):ctx.moveTo(x(i),yR(v)));ctx.lineTo(x(n-1),HH-p.b);ctx.lineTo(x(0),HH-p.b);ctx.closePath();ctx.fillStyle=col.replace(')',',0.04)').replace('rgb','rgba');ctx.fill()}
    ctx.beginPath();ctx.strokeStyle=col;ctx.lineWidth=1.5;ctx.lineJoin='round';
    data.forEach((v,i)=>i?ctx.lineTo(x(i),yR(v)):ctx.moveTo(x(i),yR(v)));ctx.stroke();
  });
  ctx.beginPath();ctx.strokeStyle='#ffb020';ctx.lineWidth=1;ctx.setLineDash([3,3]);ctx.lineJoin='round';
  H.temp.forEach((v,i)=>i?ctx.lineTo(x(i),yT(v)):ctx.moveTo(x(i),yT(v)));ctx.stroke();ctx.setLineDash([]);
  ctx.font='9px IBM Plex Mono';let lx=4;
  Object.keys(H.fans).forEach((name,i)=>{ctx.fillStyle=colors[i%colors.length];ctx.fillText(name,lx,HH-4);lx+=name.length*6+12});
  ctx.fillStyle='#ffb020';ctx.fillText('TEMP',lx,HH-4);
  ctx.textAlign='right';let ly=p.t+10;
  Object.entries(H.fans).forEach(([name,data],i)=>{const v=data[data.length-1];ctx.fillStyle=colors[i%colors.length];ctx.fillText(v+' RPM',W-4,ly);ly+=10});
  ctx.fillStyle='#ffb020';ctx.fillText(H.temp[n-1]+'°C',W-4,ly);ctx.textAlign='left';
}

async function setMode(m){
  try{const r=await fetch(API+'/api/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m}),signal:AbortSignal.timeout(5000)});
  const d=await r.json();if(d.ok)toast('ok','✓ '+d.msg);else toast('err','✗ '+(d.error||'Failed'));setTimeout(poll,500)}catch(e){toast('err','✗ Connection failed')}
}
function toast(t,m){const e=document.getElementById('toast');e.textContent=m;e.className='toast '+t+' show';setTimeout(()=>e.className='toast',3000)}
window.addEventListener('resize',drawChart);
poll();setInterval(poll,3000);
</script>
</body>
</html>
HTMLEOF

  msg_ok "Dashboard generated at ${INSTALL_DIR}/${DASHBOARD_FILE}"
}

# ── Create Systemd Service ───────────────────────────────────────────
create_service() {
  msg_info "Creating systemd service..."

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=PVE Hardware Monitor
After=network.target
Documentation=https://github.com/YOUR_USERNAME/pve-hardware-monitor

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
