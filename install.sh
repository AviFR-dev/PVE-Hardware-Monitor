#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  PVE Hardware Monitor - Install Script
#  Real-time fan RPM, temps, battery, IPMI & system monitoring
#  https://github.com/AviFR-dev/PVE-Hardware-Monitor
#
#  Usage:
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/AviFR-dev/PVE-Hardware-Monitor/main/install.sh)"
#
#  Supports: Any Proxmox VE host with lm-sensors / EC / IPMI
#  Special support: ASUS laptops (EC fan control), Dell/HP/Supermicro servers (IPMI)
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

BL='\033[36m'; GN='\033[32m'; YW='\033[33m'; RD='\033[31m'; DM='\033[90m'; BD='\033[1m'; CL='\033[0m'
CHECKMARK="${GN}✓${CL}"; CROSSMARK="${RD}✗${CL}"; ARROW="${BL}▸${CL}"; WARN="${YW}⚠${CL}"

APP_NAME="PVE Hardware Monitor"
APP_VERSION="1.1.0"
API_PORT=9099
INSTALL_DIR="/opt/pve-hwmonitor"
SERVICE_NAME="pve-hwmonitor"
DASHBOARD_FILE="dashboard.html"
API_FILE="api.py"

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
  echo -e "  ╚══════════════════════════════════════════════╝${CL}"
  echo ""
  echo -e "  ${DM}Version ${APP_VERSION} · github.com/AviFR-dev/PVE-Hardware-Monitor${CL}"
  echo ""
}

cleanup() {
  if [[ $? -ne 0 ]]; then
    echo ""
    msg_error "Installation failed. Check the output above for errors."
    msg_info  "You can re-run this script after fixing any issues."
  fi
}
trap cleanup EXIT

# ── Pre-flight Checks ────────────────────────────────────────────────
preflight() {
  header

  if [[ $EUID -ne 0 ]]; then
    msg_error "This script must be run as root."
    exit 1
  fi
  msg_ok "Running as root"

  if command -v pveversion &>/dev/null; then
    PVE_VER=$(pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+')
    msg_ok "Proxmox VE ${PVE_VER} detected"
  else
    msg_warn "Proxmox VE not detected — installing as generic Debian monitor"
    PVE_VER="generic"
  fi

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

  SYSTEM_MODEL=$(dmidecode -s system-product-name 2>/dev/null || echo "Unknown")
  SYSTEM_VENDOR=$(dmidecode -s system-manufacturer 2>/dev/null || echo "Unknown")
  BIOS_VER=$(dmidecode -s bios-version 2>/dev/null || echo "Unknown")
  msg_ok "System: ${SYSTEM_VENDOR} ${SYSTEM_MODEL} (BIOS: ${BIOS_VER})"

  CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
  CPU_CORES=$(nproc 2>/dev/null || echo "?")
  msg_ok "CPU: ${CPU_MODEL} (${CPU_CORES} threads)"

  # Detect hwmon devices
  msg_info "Scanning hwmon sensors..."
  declare -gA HWMON_MAP
  HWMON_LIST=""
  for hw in /sys/class/hwmon/hwmon*/; do
    [[ -d "$hw" ]] || continue
    idx=$(basename "$hw")
    name=$(cat "${hw}name" 2>/dev/null || echo "unknown")
    HWMON_MAP[$name]="${hw%/}/"
    HWMON_LIST="${HWMON_LIST}  ${idx} = ${name}\n"
  done
  echo -e "${DM}${HWMON_LIST}${CL}"

  # Coretemp / k10temp
  HW_CORETEMP="${HWMON_MAP[coretemp]:-${HWMON_MAP[k10temp]:-}}"
  if [[ -n "$HW_CORETEMP" ]]; then
    msg_ok "CPU temp sensor found (${HW_CORETEMP})"
  else
    msg_warn "No CPU temp sensor found"
  fi

  # NVMe — may have multiple, grab first; API scans all
  HW_NVME="${HWMON_MAP[nvme]:-}"
  [[ -n "$HW_NVME" ]] && msg_ok "NVMe temp sensor found (${HW_NVME})" || msg_warn "No NVMe sensor found"

  # PCH
  HW_PCH=""
  for pchname in pch_skylake pch_cannonlake pch_cometlake pch_alderlake pch_raptorlake pch_meteorlake; do
    if [[ -n "${HWMON_MAP[$pchname]:-}" ]]; then
      HW_PCH="${HWMON_MAP[$pchname]}"
      msg_ok "PCH temp sensor: ${pchname} (${HW_PCH})"
      break
    fi
  done
  [[ -z "$HW_PCH" ]] && msg_warn "No PCH sensor found (normal on servers)"

  # EC (laptops)
  HAS_EC="false"
  if [[ -f /sys/kernel/debug/ec/ec0/io ]]; then
    HAS_EC="true"
    msg_ok "EC (Embedded Controller) accessible"
    modprobe ec_sys write_support=1 2>/dev/null || true
  else
    msg_info "No EC found (normal for desktops/servers)"
  fi

  # ASUS fan boost
  HAS_BOOST="false"; BOOST_PATH=""
  for bp in /sys/devices/platform/asus-nb-wmi/fan_boost_mode \
            /sys/devices/platform/asus-nb-wmi/throttle_thermal_policy; do
    if [[ -f "$bp" ]]; then
      HAS_BOOST="true"; BOOST_PATH="$bp"
      msg_ok "ASUS fan profile control: ${bp}"
      break
    fi
  done

  # EC fan registers
  EC_FAN_REGS="false"
  if [[ "$HAS_EC" == "true" ]]; then
    val=$(python3 -c "
import struct
try:
    with open('/sys/kernel/debug/ec/ec0/io','rb') as f:
        f.seek(0x66); r=struct.unpack('<H',f.read(2))[0]
        print('yes' if 100 < r < 10000 else 'no')
except: print('no')
" 2>/dev/null)
    [[ "$val" == "yes" ]] && EC_FAN_REGS="true" && msg_ok "EC fan RPM registers detected (0x66/0x68)"
  fi

  # ── IPMI detection ──────────────────────────────────────────────────
  HAS_IPMI="false"
  IPMI_INTERFACE=""

  # Check for IPMI device nodes
  if [[ -c /dev/ipmi0 || -c /dev/ipmi/0 || -c /dev/ipmikcs ]]; then
    msg_ok "IPMI device node found"
    # Load kernel modules if needed
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si 2>/dev/null || true
    sleep 1
  fi

  # Try ipmitool — detect working interface
  if command -v ipmitool &>/dev/null; then
    for iface in open imb lan; do
      if timeout 5 ipmitool -I "$iface" mc info &>/dev/null 2>&1; then
        HAS_IPMI="true"
        IPMI_INTERFACE="$iface"
        IPMI_FW=$(timeout 5 ipmitool -I "$iface" mc info 2>/dev/null | grep "Firmware Revision" | awk '{print $NF}' || echo "?")
        msg_ok "IPMI accessible via interface '${iface}' (FW: ${IPMI_FW})"
        break
      fi
    done
    [[ "$HAS_IPMI" == "false" ]] && msg_warn "ipmitool found but IPMI not responding"
  else
    msg_info "ipmitool not installed yet (will install if IPMI device present)"
    # Check if we should install ipmitool
    if [[ -c /dev/ipmi0 || -c /dev/ipmi/0 ]]; then
      SHOULD_INSTALL_IPMI="true"
    else
      SHOULD_INSTALL_IPMI="false"
    fi
  fi

  # Probe IPMI SDR to categorize available sensors
  IPMI_HAS_FANS="false"
  IPMI_HAS_TEMPS="false"
  IPMI_HAS_POWER="false"
  IPMI_HAS_PSU="false"
  IPMI_HAS_VOLTAGE="false"

  if [[ "$HAS_IPMI" == "true" ]]; then
    msg_info "Probing IPMI sensor catalog..."
    SDR_OUT=$(timeout 15 ipmitool -I "$IPMI_INTERFACE" sdr type Fan 2>/dev/null || echo "")
    TEMP_OUT=$(timeout 15 ipmitool -I "$IPMI_INTERFACE" sdr type Temperature 2>/dev/null || echo "")
    PWR_OUT=$(timeout 15 ipmitool -I "$IPMI_INTERFACE" dcmi power reading 2>/dev/null || echo "")
    PSU_OUT=$(timeout 15 ipmitool -I "$IPMI_INTERFACE" sdr type "Power Supply" 2>/dev/null || echo "")
    VOLT_OUT=$(timeout 15 ipmitool -I "$IPMI_INTERFACE" sdr type Voltage 2>/dev/null || echo "")

    FAN_COUNT=$(echo "$SDR_OUT" | grep -c "RPM" || echo 0)
    TEMP_COUNT=$(echo "$TEMP_OUT" | grep -c "degrees" || echo 0)

    [[ "$FAN_COUNT"  -gt 0 ]] && IPMI_HAS_FANS="true"  && msg_ok "IPMI: ${FAN_COUNT} fan sensors"
    [[ "$TEMP_COUNT" -gt 0 ]] && IPMI_HAS_TEMPS="true" && msg_ok "IPMI: ${TEMP_COUNT} temperature sensors"
    [[ -n "$PWR_OUT" && "$PWR_OUT" =~ "Watts" ]] && IPMI_HAS_POWER="true" && msg_ok "IPMI: power consumption readings available"
    [[ -n "$PSU_OUT" ]] && IPMI_HAS_PSU="true"  && msg_ok "IPMI: PSU status sensors available"
    [[ -n "$VOLT_OUT" ]] && IPMI_HAS_VOLTAGE="true" && msg_ok "IPMI: voltage sensors available"
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

  # hwmon fans
  HAS_HWMON_FAN="false"
  for f in /sys/class/hwmon/hwmon*/fan*_input; do
    [[ -f "$f" ]] || continue
    val=$(cat "$f" 2>/dev/null || echo 0)
    if [[ "$val" -gt 0 ]]; then
      HAS_HWMON_FAN="true"
      msg_ok "hwmon fan sensor: ${f} (${val} RPM)"
      break
    fi
  done

  # Host IP
  HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [[ -z "$HOST_IP" ]] && HOST_IP="127.0.0.1"
  msg_ok "Host IP: ${HOST_IP}"

  # Generate a random API token for this installation
  API_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  msg_ok "API token generated"

  echo ""
}

# ── Install Dependencies ─────────────────────────────────────────────
install_deps() {
  msg_info "Installing dependencies..."

  apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq lm-sensors >/dev/null 2>&1
  msg_ok "lm-sensors installed"

  # Install IPMI tools if device present or already detected
  if [[ "$HAS_IPMI" == "true" || "${SHOULD_INSTALL_IPMI:-false}" == "true" || -c /dev/ipmi0 || -c /dev/ipmi/0 ]]; then
    apt-get install -y -qq ipmitool freeipmi-tools >/dev/null 2>&1
    msg_ok "ipmitool + freeipmi installed"
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si      2>/dev/null || true
    # Retry IPMI detection after installing tools
    if [[ "$HAS_IPMI" == "false" ]]; then
      for iface in open imb; do
        if timeout 5 ipmitool -I "$iface" mc info &>/dev/null 2>&1; then
          HAS_IPMI="true"; IPMI_INTERFACE="$iface"
          msg_ok "IPMI now accessible via '${iface}'"
          # Re-probe sensors
          SDR_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Fan 2>/dev/null || echo "")
          TEMP_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Temperature 2>/dev/null || echo "")
          PWR_OUT=$(timeout 15 ipmitool -I "$iface" dcmi power reading 2>/dev/null || echo "")
          PSU_OUT=$(timeout 15 ipmitool -I "$iface" sdr type "Power Supply" 2>/dev/null || echo "")
          VOLT_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Voltage 2>/dev/null || echo "")
          [[ $(echo "$SDR_OUT"  | grep -c "RPM"     || echo 0) -gt 0 ]] && IPMI_HAS_FANS="true"
          [[ $(echo "$TEMP_OUT" | grep -c "degrees" || echo 0) -gt 0 ]] && IPMI_HAS_TEMPS="true"
          [[ "$PWR_OUT" =~ "Watts" ]] && IPMI_HAS_POWER="true"
          [[ -n "$PSU_OUT" ]]  && IPMI_HAS_PSU="true"
          [[ -n "$VOLT_OUT" ]] && IPMI_HAS_VOLTAGE="true"
          break
        fi
      done
    fi
  fi

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
import http.server, json, struct, os, glob, subprocess, re
import sys, hmac, secrets, time, traceback, threading, concurrent.futures
from collections import defaultdict

PORT          = __PORT__
EC_PATH       = '/sys/kernel/debug/ec/ec0/io'
BOOST_PATH    = '__BOOST_PATH__'
BAT_PATH      = '__BAT_PATH__'
HW_CORETEMP   = '__HW_CORETEMP__'
HW_NVME       = '__HW_NVME__'
HW_PCH        = '__HW_PCH__'
HAS_EC        = __HAS_EC__
EC_FAN_REGS   = __EC_FAN_REGS__
HAS_BOOST     = __HAS_BOOST__
HAS_IPMI      = __HAS_IPMI__
IPMI_IFACE    = '__IPMI_INTERFACE__'
IPMI_HAS_FANS    = __IPMI_HAS_FANS__
IPMI_HAS_TEMPS   = __IPMI_HAS_TEMPS__
IPMI_HAS_POWER   = __IPMI_HAS_POWER__
IPMI_HAS_PSU     = __IPMI_HAS_PSU__
IPMI_HAS_VOLTAGE = __IPMI_HAS_VOLTAGE__
SYSTEM_MODEL  = '__SYSTEM_MODEL__'
BIOS_VER      = '__BIOS_VER__'
SDR_CACHE     = '/opt/pve-hwmonitor/sdr.cache'

# ── Security: token auth ─────────────────────────────────────────────
# Generated at install time by installer via secrets.token_hex(32)
API_TOKEN = os.environ.get('PVE_HWM_TOKEN', '__API_TOKEN__')

def _check_token(headers):
    """Constant-time comparison to prevent timing attacks."""
    provided = headers.get('X-Api-Token', '')
    if not API_TOKEN or API_TOKEN == '__API_TOKEN__':
        return True  # token not yet configured
    return hmac.compare_digest(provided.encode(), API_TOKEN.encode())

# ── Security: rate limiter (10 req/s per IP) ─────────────────────────
_rate_lock   = threading.Lock()
_rate_counts = defaultdict(lambda: [0, 0.0])  # ip -> [count, window_start]
RATE_LIMIT   = 10
RATE_WINDOW  = 1.0

def _rate_ok(ip):
    now = time.monotonic()
    with _rate_lock:
        count, start = _rate_counts[ip]
        if now - start > RATE_WINDOW:
            _rate_counts[ip] = [1, now]
            return True
        if count >= RATE_LIMIT:
            return False
        _rate_counts[ip][0] += 1
        return True

# ── Security: path validators ────────────────────────────────────────
SAFE_READ_PREFIXES  = ('/sys/', '/proc/', '/opt/pve-hwmonitor/', '/dev/')
ALLOWED_WRITE_PATHS = {BOOST_PATH} if BOOST_PATH else set()

def _safe_read_path(p):
    if not p: return False
    real = os.path.realpath(p)  # resolve symlinks before checking
    return any(real.startswith(px) for px in SAFE_READ_PREFIXES)

def _sdr_cache_valid():
    """Accept SDR cache only if root-owned and not group/world writable."""
    if not os.path.exists(SDR_CACHE): return False
    try:
        st = os.stat(SDR_CACHE)
        return st.st_uid == 0 and not (st.st_mode & 0o022)
    except OSError:
        return False

# ── Low-level helpers ────────────────────────────────────────────────

def read_ec(o, c=1):
    if not HAS_EC: return None
    try:
        with open(EC_PATH, 'rb') as f: f.seek(o); return f.read(c)
    except Exception:
        return None

def rf(p):
    if not _safe_read_path(p): return None
    try:
        with open(p) as f: return f.read().strip()
    except Exception:
        return None

def ri(p):
    v = rf(p)
    return int(v) if v and v.lstrip('-').isdigit() else None

def wf(p, v):
    if not p or p not in ALLOWED_WRITE_PATHS:
        return 'write to this path is not permitted'
    try:
        with open(p, 'w') as f: f.write(str(v)); return True
    except Exception:
        _log('wf', f'failed writing to {p}')
        return 'write failed'

def _log(ctx, msg):
    print(f'[ERROR] {ctx}: {msg}', flush=True)

def _log_exc(ctx):
    print(f'[ERROR] {ctx}:\n{traceback.format_exc()}', flush=True)

# ── hwmon helpers ────────────────────────────────────────────────────

def get_temps(hw_path, max_idx=16):
    if not hw_path: return []
    items = []
    for i in range(1, max_idx):
        t = ri(f'{hw_path}temp{i}_input')
        if t is None: continue
        lbl = rf(f'{hw_path}temp{i}_label') or f'Sensor {i}'
        items.append({'label': lbl, 'temp': round(t / 1000, 1)})
    return items

def get_fans_hwmon():
    fans = []
    for f in sorted(glob.glob('/sys/class/hwmon/hwmon*/fan*_input')):
        if not _safe_read_path(f): continue
        val = ri(f)
        if val is None: continue
        hwname = rf(os.path.join(os.path.dirname(f), 'name')) or '?'
        label  = rf(f.replace('_input', '_label')) or os.path.basename(f).replace('_input', '')
        fans.append({'name': f'{hwname}/{label}', 'rpm': val, 'source': 'hwmon'})
    return fans

def get_fans_ec():
    if not EC_FAN_REGS: return []
    fans = []
    for name, offset, duty_offset in [('CPU', 0x66, 0x97), ('GPU', 0x68, 0x98)]:
        raw_b  = read_ec(offset, 2)
        duty_b = read_ec(duty_offset)
        raw    = struct.unpack('<H', raw_b)[0] if raw_b else 0
        duty   = struct.unpack('B',  duty_b)[0] if duty_b else 0
        rpm    = round(2156250 / raw) if raw > 0 else 0
        fans.append({'name': name, 'rpm': rpm, 'raw': raw, 'duty': duty, 'source': 'ec'})
    return fans

# ── IPMI helpers ─────────────────────────────────────────────────────

def _ipmitool(*args, timeout=6):
    """Hard wall-clock timeout — frozen BMC never hangs the HTTP response."""
    if not HAS_IPMI: return []
    def _run():
        try:
            cmd = ['ipmitool', '-I', IPMI_IFACE, '-N', '3', '-R', '1']
            if _sdr_cache_valid():
                cmd += ['-S', SDR_CACHE]
            cmd += list(args)
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout - 1)
            return r.stdout.splitlines() if r.returncode == 0 else []
        except Exception:
            return []
    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as ex:
            return ex.submit(_run).result(timeout=timeout)
    except Exception:
        return []

def _parse_sdr_value(line):
    parts = [p.strip() for p in line.split('|')]
    if len(parts) < 3: return None
    name   = parts[0].strip()
    raw    = parts[1].strip()
    status = parts[2].strip().lower()
    m = re.match(r'^([\d.]+)\s*(.*)', raw)
    if not m: return None
    try:    val = float(m.group(1))
    except: return None
    return name, val, m.group(2).strip(), status

def get_ipmi_fans():
    if not IPMI_HAS_FANS: return []
    fans = []
    for line in _ipmitool('sdr', 'type', 'Fan'):
        r = _parse_sdr_value(line)
        if not r: continue
        name, val, unit, status = r
        if 'RPM' not in unit.upper(): continue
        fans.append({'name': name, 'rpm': int(val), 'status': status, 'source': 'ipmi'})
    return fans

def get_ipmi_temps():
    if not IPMI_HAS_TEMPS: return []
    temps = []
    for line in _ipmitool('sdr', 'type', 'Temperature'):
        r = _parse_sdr_value(line)
        if not r: continue
        name, val, unit, status = r
        if 'degrees' not in unit.lower() and '°' not in unit: continue
        if status in ('ns', 'na', 'n/a'): continue
        temps.append({'label': name, 'temp': round(val, 1), 'status': status})
    return temps

def get_ipmi_power():
    if not IPMI_HAS_POWER: return None
    result = {}
    for line in _ipmitool('dcmi', 'power', 'reading', timeout=6):
        line = line.strip()
        for pattern, key in [
            (r'Instantaneous power reading:\s+([\d.]+)\s+Watts', 'watts_now'),
            (r'Minimum.*?:\s+([\d.]+)\s+Watts',                  'watts_min'),
            (r'Maximum.*?:\s+([\d.]+)\s+Watts',                  'watts_max'),
            (r'Average.*?:\s+([\d.]+)\s+Watts',                  'watts_avg'),
        ]:
            m = re.search(pattern, line)
            if m: result[key] = float(m.group(1))
    return result if result else None

def get_ipmi_psu():
    if not IPMI_HAS_PSU: return []
    psus = []
    for line in _ipmitool('sdr', 'type', 'Power Supply'):
        r = _parse_sdr_value(line)
        if not r: continue
        name, val, unit, status = r
        psus.append({'name': name, 'value': val, 'unit': unit, 'status': status})
    return psus

def get_ipmi_voltages():
    if not IPMI_HAS_VOLTAGE: return []
    volts = []
    for line in _ipmitool('sdr', 'type', 'Voltage'):
        r = _parse_sdr_value(line)
        if not r: continue
        name, val, unit, status = r
        if status in ('ns', 'na', 'n/a'): continue
        volts.append({'label': name, 'value': round(val, 3), 'unit': unit, 'status': status})
    return volts

# ── Battery ──────────────────────────────────────────────────────────

def get_battery():
    if not BAT_PATH or not os.path.isdir(BAT_PATH): return None
    status   = rf(f'{BAT_PATH}/status')
    capacity = ri(f'{BAT_PATH}/capacity')
    e_now    = ri(f'{BAT_PATH}/energy_now')  or ri(f'{BAT_PATH}/charge_now')
    e_full   = ri(f'{BAT_PATH}/energy_full') or ri(f'{BAT_PATH}/charge_full')
    power    = ri(f'{BAT_PATH}/power_now')   or ri(f'{BAT_PATH}/current_now')
    voltage  = ri(f'{BAT_PATH}/voltage_now')
    cycles   = ri(f'{BAT_PATH}/cycle_count')
    return {
        'status':      status or 'Unknown',
        'capacity':    capacity,
        'energy_now':  round(e_now  / 1e6, 2) if e_now  else None,
        'energy_full': round(e_full / 1e6, 2) if e_full else None,
        'power':       round(power  / 1e6, 2) if power  else None,
        'voltage':     round(voltage/ 1e6, 2) if voltage else None,
        'cycles':      cycles,
    }

# ── System ───────────────────────────────────────────────────────────

def get_system():
    uptime = None
    try:
        with open('/proc/uptime') as f: uptime = float(f.read().split()[0])
    except Exception: pass
    load = None
    try:
        with open('/proc/loadavg') as f:
            p = f.read().split(); load = [float(p[0]), float(p[1]), float(p[2])]
    except Exception: pass
    mem = {}
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if   line.startswith('MemTotal:'):     mem['total']     = int(line.split()[1]) // 1024
                elif line.startswith('MemAvailable:'): mem['available'] = int(line.split()[1]) // 1024
    except Exception: pass
    if 'total' in mem and 'available' in mem:
        mem['used'] = mem['total'] - mem['available']
        mem['pct']  = round(mem['used'] / mem['total'] * 100, 1)
    return {'uptime_s': uptime, 'load': load, 'mem': mem}

# ── Main status builder ──────────────────────────────────────────────

def get_status():
    ec_temp_b  = read_ec(0x58)
    ec_temp    = struct.unpack('B', ec_temp_b)[0] if ec_temp_b else None
    board_b    = read_ec(0xC5)
    board_temp = struct.unpack('B', board_b)[0]   if board_b   else None

    coretemp_list = get_temps(HW_CORETEMP)
    pkg_temp      = coretemp_list[0]['temp'] if coretemp_list else ec_temp
    core_temps    = coretemp_list[1:] if len(coretemp_list) > 1 else []

    nvme = []
    for hw in sorted(glob.glob('/sys/class/hwmon/hwmon*/')):
        name = rf(hw + 'name') or ''
        if 'nvme' in name:
            for t in get_temps(hw):
                t['drive'] = hw.split('/')[-2]
                nvme.append(t)

    pch_list = get_temps(HW_PCH)
    pch_temp = pch_list[0]['temp'] if pch_list else None

    ipmi = None
    if HAS_IPMI:
        with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
            f_fans  = ex.submit(get_ipmi_fans)     if IPMI_HAS_FANS    else None
            f_temps = ex.submit(get_ipmi_temps)    if IPMI_HAS_TEMPS   else None
            f_power = ex.submit(get_ipmi_power)    if IPMI_HAS_POWER   else None
            f_psu   = ex.submit(get_ipmi_psu)      if IPMI_HAS_PSU     else None
            f_volts = ex.submit(get_ipmi_voltages) if IPMI_HAS_VOLTAGE else None
            def _get(fut, default):
                if fut is None: return default
                try: return fut.result(timeout=7)
                except Exception: return default
            ipmi_fans = _get(f_fans, [])
            ipmi = {
                'fans':     ipmi_fans,
                'temps':    _get(f_temps, []),
                'power':    _get(f_power, None),
                'psu':      _get(f_psu,   []),
                'voltages': _get(f_volts, []),
            }
    else:
        ipmi_fans = []

    fans_ec   = get_fans_ec()
    fans_hw   = get_fans_hwmon()
    fans_ipmi = ipmi_fans if ipmi else []
    if   fans_ec:   fans = fans_ec
    elif fans_hw:   fans = fans_hw
    elif fans_ipmi: fans = fans_ipmi
    else:           fans = []

    battery = get_battery()
    system  = get_system()

    boost_str = rf(BOOST_PATH) if HAS_BOOST else None
    bv = int(boost_str) if boost_str and boost_str.isdigit() else None

    return {
        'ok':         True,
        'model':      SYSTEM_MODEL,
        'cpu_temp':   pkg_temp,
        'core_temps': core_temps,
        'ec_temp':    ec_temp,
        'board_temp': board_temp,
        'pch_temp':   pch_temp,
        'nvme':       nvme,
        'fans':       fans,
        'battery':    battery,
        'system':     system,
        'ipmi':       ipmi,
        'has_ipmi':   HAS_IPMI,
        'mode':       {0:'normal',1:'boost',2:'silent'}.get(bv,'n/a') if bv is not None else 'n/a',
        'mode_raw':   bv,
        'has_boost':  HAS_BOOST,
    }

# ── HTTP server ──────────────────────────────────────────────────────

class Handler(http.server.BaseHTTPRequestHandler):

    def _client_ip(self):
        return self.client_address[0]

    def _cors(self):
        # Reflect request Origin instead of wildcard * — blocks cross-origin CSRF
        origin = self.headers.get('Origin', '')
        self.send_header('Access-Control-Allow-Origin', origin if origin else 'null')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, X-Api-Token')
        self.send_header('Vary', 'Origin')

    def _sec(self):
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Frame-Options', 'DENY')
        self.send_header('Cache-Control', 'no-store')

    def _json(self, code, data):
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self._cors(); self._sec()
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _rate_check(self):
        if not _rate_ok(self._client_ip()):
            self._json(429, {'ok': False, 'error': 'Too many requests'})
            return False
        return True

    def _auth_check(self):
        if not _check_token(self.headers):
            self._json(401, {'ok': False, 'error': 'Unauthorized'})
            return False
        return True

    def do_OPTIONS(self):
        self.send_response(204); self._cors(); self.end_headers()

    def do_GET(self):
        if not self._rate_check(): return
        if not self._auth_check(): return

        if self.path == '/api/status':
            try:
                self._json(200, get_status())
            except Exception:
                _log_exc('get_status')
                self._json(500, {'ok': False, 'error': 'Internal server error'})

        elif self.path in ('/', '/index.html'):
            try:
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self._sec()
                self.end_headers()
                dash = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dashboard.html')
                with open(dash, 'rb') as f: self.wfile.write(f.read())
            except Exception:
                _log_exc('serve_dashboard')
                self._json(500, {'ok': False, 'error': 'Internal server error'})

        else:
            self._json(404, {'ok': False, 'error': 'Not found'})

    def do_POST(self):
        if not self._rate_check(): return
        if not self._auth_check(): return

        if self.path == '/api/mode' and HAS_BOOST:
            try:
                length = int(self.headers.get('Content-Length', 0))
                if length > 1024:
                    self._json(413, {'ok': False, 'error': 'Payload too large'}); return
                body = json.loads(self.rfile.read(length))
                mode = int(body.get('mode', -1))
                if mode not in (0, 1, 2):
                    self._json(400, {'ok': False, 'error': 'mode must be 0, 1, or 2'}); return
                names = {0: 'Normal', 1: 'Boost', 2: 'Silent'}
                res = wf(BOOST_PATH, str(mode))
                if res is True:
                    self._json(200, {'ok': True, 'msg': f'Fan profile: {names[mode]}'})
                else:
                    self._json(500, {'ok': False, 'error': 'Write failed'})
            except Exception:
                _log_exc('set_mode')
                self._json(500, {'ok': False, 'error': 'Internal server error'})
        else:
            self._json(404, {'ok': False, 'error': 'Not found or unavailable'})

    def log_message(self, *a): pass

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (BrokenPipeError, ConnectionResetError)): return
        super().handle_error(request, client_address)

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

# ── Start ────────────────────────────────────────────────────────────

auth_note = 'ENABLED' if (API_TOKEN and API_TOKEN != '__API_TOKEN__') else 'DISABLED (token not configured)'
print(f'PVE Hardware Monitor API on :{PORT}')
print(f'  Auth:      {auth_note}')
print(f'  Dashboard: http://0.0.0.0:{PORT}/')
http.server.HTTPServer(('0.0.0.0', PORT), Handler).serve_forever()

APIEOF

  # Substitute all placeholders
  sed -i "s|__PORT__|${API_PORT}|g"                          "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BOOST_PATH__|${BOOST_PATH}|g"                  "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BAT_PATH__|${BAT_PATH}|g"                      "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_CORETEMP__|${HW_CORETEMP}|g"                "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_NVME__|${HW_NVME}|g"                        "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HW_PCH__|${HW_PCH}|g"                          "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HAS_EC__|${HAS_EC^}|g"                         "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__EC_FAN_REGS__|${EC_FAN_REGS^}|g"               "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HAS_BOOST__|${HAS_BOOST^}|g"                   "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__HAS_IPMI__|${HAS_IPMI^}|g"                     "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_INTERFACE__|${IPMI_INTERFACE:-open}|g"    "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_HAS_FANS__|${IPMI_HAS_FANS^}|g"           "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_HAS_TEMPS__|${IPMI_HAS_TEMPS^}|g"         "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_HAS_POWER__|${IPMI_HAS_POWER^}|g"         "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_HAS_PSU__|${IPMI_HAS_PSU^}|g"             "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__IPMI_HAS_VOLTAGE__|${IPMI_HAS_VOLTAGE^}|g"     "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__SYSTEM_MODEL__|${SYSTEM_MODEL}|g"               "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__BIOS_VER__|${BIOS_VER}|g"                      "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__API_TOKEN__|${API_TOKEN}|g"                    "${INSTALL_DIR}/${API_FILE}"
  sed -i "s|__DASHBOARD_TOKEN__|${API_TOKEN}|g"              "${INSTALL_DIR}/${DASHBOARD_FILE}"

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
  --bg:#07080b;--s1:#0e1117;--s2:#141920;--s3:#1b222e;--s4:#222b3a;
  --bdr:#1e2a3c;--bdr2:#2a3d56;--bdr3:#364f6b;
  --tx:#d6e4f5;--tx2:#8ba3be;--tx3:#4a6480;
  --blue:#3d8ef8;--cyan:#00c8d8;--green:#00df8c;
  --amber:#ffc030;--red:#ff3d5c;--violet:#a87fff;--teal:#00c9a7;--orange:#ff8c42;
  --blue-a:rgba(61,142,248,.1);--green-a:rgba(0,223,140,.08);
  --red-a:rgba(255,61,92,.1);--amber-a:rgba(255,192,48,.08);
}
body{font-family:'Outfit',sans-serif;background:var(--bg);color:var(--tx);min-height:100vh;overflow-x:hidden}
.bg-grid{position:fixed;inset:0;pointer-events:none;opacity:.025;
  background-image:linear-gradient(var(--bdr) 1px,transparent 1px),linear-gradient(90deg,var(--bdr) 1px,transparent 1px);
  background-size:32px 32px}
.bg-orb{position:fixed;border-radius:50%;pointer-events:none;filter:blur(140px)}
.orb1{width:600px;height:600px;top:-200px;left:-100px;background:radial-gradient(circle,rgba(61,142,248,.06),transparent 70%)}
.orb2{width:500px;height:500px;bottom:-150px;right:-80px;background:radial-gradient(circle,rgba(0,200,216,.05),transparent 70%)}
.orb3{width:300px;height:300px;top:40%;left:30%;background:radial-gradient(circle,rgba(0,223,140,.03),transparent 70%)}
.app{max-width:1200px;margin:0 auto;padding:20px 16px 32px;position:relative;z-index:1}

/* Header */
.hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px;padding:14px 18px;
  background:var(--s1);border:1px solid var(--bdr);border-radius:12px;flex-wrap:wrap;gap:10px}
.brand{display:flex;align-items:center;gap:14px}
.brand-icon{width:38px;height:38px;border-radius:9px;background:linear-gradient(135deg,#1a56ff 0%,#00c8d8 100%);
  display:grid;place-items:center;flex-shrink:0;position:relative;overflow:hidden}
.brand-icon::after{content:'';position:absolute;inset:0;background:linear-gradient(135deg,rgba(255,255,255,.15),transparent)}
.brand-icon svg{width:20px;height:20px;fill:none;stroke:#fff;stroke-width:2;stroke-linecap:round}
.brand-info h1{font-size:15px;font-weight:600;letter-spacing:-.2px}
.brand-info small{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3);letter-spacing:.4px}
.hdr-right{display:flex;align-items:center;gap:10px}
.conn-pill{display:flex;align-items:center;gap:7px;padding:6px 14px;background:var(--s2);
  border:1px solid var(--bdr);border-radius:99px;font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3)}
.pulse{width:7px;height:7px;border-radius:50%;background:var(--red);flex-shrink:0;transition:background .3s}
.pulse.ok{background:var(--green);box-shadow:0 0 0 3px rgba(0,223,140,.15)}
.btn{padding:6px 12px;background:var(--s2);border:1px solid var(--bdr);border-radius:7px;
  color:var(--tx3);font-size:11px;cursor:pointer;transition:all .2s}
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
.sec-badge{font-family:'JetBrains Mono',monospace;font-size:9px;padding:2px 8px;
  border-radius:4px;background:rgba(61,142,248,.1);border:1px solid rgba(61,142,248,.2);color:var(--blue);margin-left:4px}

/* Grid */
.g{display:grid;gap:10px;margin-bottom:0}
.g2{grid-template-columns:1fr 1fr}
.g3{grid-template-columns:1fr 1fr 1fr}
.g4{grid-template-columns:repeat(4,1fr)}

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

.big{font-family:'JetBrains Mono',monospace;font-size:38px;font-weight:600;line-height:1;letter-spacing:-2.5px;margin-bottom:4px}
.mid{font-family:'JetBrains Mono',monospace;font-size:22px;font-weight:500;line-height:1;letter-spacing:-1px}
.unit{font-size:12px;color:var(--tx3);font-weight:400;margin-left:2px}
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
.ms .ok{color:var(--green)}.ms .warn{color:var(--amber)}.ms .crit{color:var(--red)}

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
  color:var(--tx2);cursor:pointer;font-size:12px;font-weight:500;transition:all .2s;text-align:center;line-height:1.3}
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

/* IPMI Power card */
.power-big{font-family:'JetBrains Mono',monospace;font-size:48px;font-weight:600;
  line-height:1;letter-spacing:-3px;color:var(--orange)}
.power-stats{display:grid;grid-template-columns:1fr 1fr;gap:6px;margin-top:10px}
.pstat{background:var(--s2);border-radius:7px;padding:8px 10px}
.pstat-val{font-family:'JetBrains Mono',monospace;font-size:16px;font-weight:500}
.pstat-lbl{font-size:9px;color:var(--tx3);margin-top:2px;font-family:'JetBrains Mono',monospace}

/* PSU status pill */
.psu-pill{display:inline-flex;align-items:center;gap:5px;padding:3px 8px;
  border-radius:4px;font-family:'JetBrains Mono',monospace;font-size:10px;margin:2px 3px 2px 0}
.psu-ok{background:rgba(0,223,140,.08);border:1px solid rgba(0,223,140,.2);color:var(--green)}
.psu-warn{background:rgba(255,192,48,.08);border:1px solid rgba(255,192,48,.2);color:var(--amber)}
.psu-crit{background:rgba(255,61,92,.08);border:1px solid rgba(255,61,92,.2);color:var(--red)}
.psu-dot{width:5px;height:5px;border-radius:50%;flex-shrink:0}

/* Chart */
.chart-wrap{position:relative;height:140px}
canvas{display:block;width:100%!important}

/* Toast */
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(90px);
  background:var(--s1);border:1px solid var(--bdr);border-radius:9px;
  padding:9px 18px;font-size:11.5px;z-index:99;transition:transform .3s cubic-bezier(.22,1,.36,1);box-shadow:0 8px 32px rgba(0,0,0,.5)}
.toast.show{transform:translateX(-50%) translateY(0)}
.toast.ok{border-color:rgba(0,223,140,.35);color:var(--green)}
.toast.err{border-color:rgba(255,61,92,.35);color:var(--red)}

/* Footer */
.ftr{font-family:'JetBrains Mono',monospace;font-size:9.5px;color:var(--tx3);
  display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;
  padding:12px 16px;background:var(--s1);border:1px solid var(--bdr);border-radius:9px;margin-top:10px}
.ftr b{color:var(--tx2);font-weight:500}

/* Animations */
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.c{animation:fadeUp .35s ease both}
.g .c:nth-child(1){animation-delay:.04s}.g .c:nth-child(2){animation-delay:.08s}
.g .c:nth-child(3){animation-delay:.12s}.g .c:nth-child(4){animation-delay:.16s}

@media(max-width:900px){.g3,.g4{grid-template-columns:1fr 1fr}}
@media(max-width:600px){.g2,.g3,.g4{grid-template-columns:1fr}}
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
  <div class="g g3" id="tempRow">
    <!-- CPU -->
    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--amber),transparent)"></div>
      <div class="c-bg" style="background:var(--amber)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--amber)"></div>CPU CORES</div>
      <div class="gauge-wrap">
        <svg class="gauge" viewBox="0 0 78 78">
          <circle cx="39" cy="39" r="30" fill="none" stroke="#1b222e" stroke-width="7"/>
          <circle cx="39" cy="39" r="30" fill="none" stroke="url(#cpuGrad)" stroke-width="7"
            stroke-linecap="round" stroke-dasharray="0 188" id="cpuArc"
            style="transition:stroke-dasharray .6s cubic-bezier(.22,1,.36,1);transform:rotate(-90deg);transform-origin:50% 50%"/>
          <defs><linearGradient id="cpuGrad" x1="0%" y1="0%" x2="100%" y2="0%">
            <stop offset="0%" stop-color="#ffc030"/><stop offset="100%" stop-color="#ff3d5c"/>
          </linearGradient></defs>
          <text x="39" y="36" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="14" font-weight="600" fill="#d6e4f5" id="cpuGaugeVal">--</text>
          <text x="39" y="48" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="8" fill="#4a6480">°C</text>
        </svg>
        <div class="gauge-info">
          <div class="lbl" style="margin-bottom:3px;font-size:9px">PACKAGE</div>
          <div class="big" id="cpuPkg" style="font-size:30px;color:var(--amber)">--<span class="unit">°C</span></div>
          <div class="sub" id="cpuPkgSub">--</div>
        </div>
      </div>
      <div class="chip-grid" id="coreGrid"></div>
      <div class="ms" style="margin-top:8px"><span>EC Temp</span><b id="ecT">--</b></div>
      <div class="ms"><span>PCH Chipset</span><b id="pchT">--</b></div>
    </div>

    <!-- NVMe -->
    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--violet),transparent)"></div>
      <div class="c-bg" style="background:var(--violet)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--violet)"></div>NVME STORAGE</div>
      <div class="chip-grid" id="nvmeGrid"></div>
      <div id="nvmeStats" style="margin-top:8px"></div>
    </div>

    <!-- Battery (hidden on servers) -->
    <div class="c" id="batCard" style="display:none">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--green),transparent)"></div>
      <div class="c-bg" style="background:var(--green)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--green)"></div>BATTERY
        <span class="lbl-tag" id="batStatus">--</span></div>
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
      <div class="ms" id="batCycleRow" style="display:none"><span>Cycles</span><b id="batCycles">--</b></div>
    </div>
  </div>

  <!-- IPMI section — shown only when has_ipmi -->
  <div id="ipmiSection" style="display:none">

    <!-- IPMI Power -->
    <div id="ipmiPowerWrap" style="display:none">
      <div class="sec">Power consumption <span class="sec-badge">IPMI</span></div>
      <div class="g g4" id="ipmiPowerGrid"></div>
    </div>

    <!-- IPMI Temperatures -->
    <div id="ipmiTempWrap" style="display:none">
      <div class="sec">IPMI temperatures <span class="sec-badge">IPMI</span></div>
      <div class="g" id="ipmiTempGrid"></div>
    </div>

    <!-- IPMI Fans -->
    <div id="irmiFanWrap" style="display:none">
      <div class="sec">IPMI fan speeds <span class="sec-badge">IPMI</span></div>
      <div class="g" id="irmiFanGrid"></div>
    </div>

    <!-- PSU status -->
    <div id="ipmiPsuWrap" style="display:none">
      <div class="sec">PSU status <span class="sec-badge">IPMI</span></div>
      <div class="c c-full" style="grid-column:unset">
        <div class="lbl"><div class="lbl-dot" style="background:var(--green)"></div>POWER SUPPLIES</div>
        <div id="ipmiPsuList"></div>
      </div>
    </div>

    <!-- Voltages -->
    <div id="ipmiVoltWrap" style="display:none">
      <div class="sec">Voltages <span class="sec-badge">IPMI</span></div>
      <div class="g" id="ipmiVoltGrid"></div>
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
    <div class="c" id="modeCard" style="display:none">
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
      </div>
    </div>
  </div>

  <!-- History chart -->
  <div class="sec">History — 5 minutes</div>
  <div class="g">
    <div class="c c-full" style="padding-bottom:12px">
      <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;flex-wrap:wrap;gap:8px">
        <div style="display:flex;gap:14px;flex-wrap:wrap" id="chartLegend"></div>
        <div style="display:flex;gap:5px">
          <button class="btn" id="btnRPM"  onclick="setChart('rpm')"  style="font-size:10px;padding:4px 10px">RPM</button>
          <button class="btn" id="btnTemp" onclick="setChart('temp')" style="font-size:10px;padding:4px 10px">TEMP</button>
          <button class="btn" id="btnPwr"  onclick="setChart('pwr')"  style="font-size:10px;padding:4px 10px;display:none">POWER</button>
          <button class="btn" id="btnAll"  onclick="setChart('all')"  style="font-size:10px;padding:4px 10px;border-color:var(--blue);color:var(--blue)">ALL</button>
        </div>
      </div>
      <div class="chart-wrap"><canvas id="chart" height="140"></canvas></div>
    </div>
  </div>

  <!-- Footer -->
  <div class="ftr">
    <div>Model&nbsp;<b id="fModel">--</b></div>
    <div>BIOS&nbsp;<b id="fBios">--</b></div>
    <div>API&nbsp;<b>:9099</b></div>
    <div>Poll&nbsp;<b>3s</b></div>
    <div>Updated&nbsp;<b id="fTime">--</b></div>
    <div>Uptime&nbsp;<b id="fUptime">--</b></div>
  </div>
</div>

<div class="toast" id="toast"></div>

<script>
const API = window.location.origin.includes('file://') ? 'http://localhost:9099' : window.location.origin;

// API token — injected at install time, also readable from localStorage for reuse
let API_TOKEN = '__DASHBOARD_TOKEN__';
function _headers(extra) {
  const h = {'Content-Type': 'application/json'};
  if (API_TOKEN) h['X-Api-Token'] = API_TOKEN;
  return Object.assign(h, extra || {});
}
const CIRC = 2 * Math.PI * 30;
const H = { cpuR:[], gpuR:[], cpuT:[], nvmeT:[], watts:[] };
const MAX = 100;
let chartMode = 'all';

// ── Utilities ────────────────────────────────────────────────────────
function tc(t){if(!t&&t!==0)return'var(--tx3)';if(t>85)return'var(--red)';if(t>70)return'var(--amber)';if(t>55)return'#f0c040';return'var(--green)'}
function tcN(t){if(!t)return'var(--tx3)';if(t>70)return'var(--red)';if(t>55)return'var(--amber)';return'var(--violet)'}
function statusColor(s){const sl=(s||'').toLowerCase();if(sl==='ok'||sl==='presence detected')return'var(--green)';if(sl.includes('warn')||sl.includes('non-critical'))return'var(--amber)';if(sl.includes('crit')||sl.includes('fail'))return'var(--red)';return'var(--tx3)'}
function setEl(id,v){const e=document.getElementById(id);if(e)e.textContent=v}
function setColor(id,c){const e=document.getElementById(id);if(e)e.style.color=c}
function setWidth(id,p){const e=document.getElementById(id);if(e)e.style.width=Math.max(0,Math.min(100,p))+'%'}
function setArc(id,pct){const el=document.getElementById(id);if(!el)return;const f=Math.max(0,Math.min(1,pct/100))*CIRC;el.setAttribute('stroke-dasharray',f.toFixed(1)+' '+CIRC)}
function show(id,v=true){const e=document.getElementById(id);if(e)e.style.display=v?'':'none'}
function fmtUptime(s){if(!s)return{d:0,h:0,m:0};return{d:Math.floor(s/86400),h:Math.floor(s%86400/3600),m:Math.floor(s%3600/60)}}

// ── Chart ────────────────────────────────────────────────────────────
function setChart(mode){
  chartMode=mode;
  ['btnRPM','btnTemp','btnPwr','btnAll'].forEach(id=>{const b=document.getElementById(id);if(b){b.style.borderColor='';b.style.color=''}});
  const k={rpm:'btnRPM',temp:'btnTemp',pwr:'btnPwr',all:'btnAll'}[mode];
  const b=document.getElementById(k);if(b){b.style.borderColor='var(--blue)';b.style.color='var(--blue)'}
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
  ctx.strokeStyle='rgba(30,42,60,.8)';ctx.lineWidth=.5;
  for(let i=0;i<=4;i++){const y=P.t+(ch/4)*i;ctx.beginPath();ctx.moveTo(P.l,y);ctx.lineTo(W-P.r,y);ctx.stroke()}
  const series=[];
  if(chartMode==='rpm'||chartMode==='all'){
    const maxR=Math.max(500,...H.cpuR,...H.gpuR);
    const yR=v=>P.t+ch-(v/maxR)*ch;
    series.push({data:H.cpuR,color:'#3d8ef8',y:yR,label:'CPU fan',unit:'RPM',width:1.5});
    if(H.gpuR.some(v=>v>0))series.push({data:H.gpuR,color:'#00c8d8',y:yR,label:'Fan 2',unit:'RPM',width:1.5});
  }
  if(chartMode==='temp'||chartMode==='all'){
    const minT=Math.min(25,...H.cpuT),maxT=Math.max(60,...H.cpuT);
    const yT=v=>P.t+ch-((v-minT+2)/(maxT-minT+4))*ch;
    series.push({data:H.cpuT,color:'#ffc030',y:yT,label:'CPU temp',unit:'°C',dash:[3,3],width:1.5});
    if(H.nvmeT.some(v=>v>0))series.push({data:H.nvmeT,color:'#a87fff',y:yT,label:'NVMe',unit:'°C',dash:[2,4],width:1});
  }
  if((chartMode==='pwr'||chartMode==='all')&&H.watts.some(v=>v>0)){
    const maxW=Math.max(100,...H.watts);
    const yW=v=>P.t+ch-(v/maxW)*ch;
    series.push({data:H.watts,color:'#ff8c42',y:yW,label:'Power',unit:'W',dash:[4,2],width:1.5});
  }
  if(series.length>0){
    const s=series[0];
    ctx.beginPath();s.data.forEach((v,i)=>i?ctx.lineTo(x(i),s.y(v)):ctx.moveTo(x(i),s.y(v)));
    ctx.lineTo(x(n-1),HH-P.b);ctx.lineTo(x(0),HH-P.b);ctx.closePath();ctx.fillStyle=s.color+'12';ctx.fill();
  }
  series.forEach(s=>{
    ctx.beginPath();ctx.strokeStyle=s.color;ctx.lineWidth=s.width||1.5;ctx.lineJoin='round';ctx.lineCap='round';
    if(s.dash)ctx.setLineDash(s.dash);else ctx.setLineDash([]);
    s.data.forEach((v,i)=>i?ctx.lineTo(x(i),s.y(v)):ctx.moveTo(x(i),s.y(v)));ctx.stroke();ctx.setLineDash([]);
    ctx.beginPath();ctx.arc(x(n-1),s.y(s.data[n-1]),3,0,Math.PI*2);ctx.fillStyle=s.color;ctx.fill();
  });
  ctx.font='400 9px "JetBrains Mono",monospace';let lx=P.l+2;
  series.forEach(s=>{
    const last=s.data[n-1];ctx.fillStyle=s.color;
    ctx.beginPath();if(ctx.roundRect)ctx.roundRect(lx,HH-P.b+4,8,8,2);else ctx.rect(lx,HH-P.b+4,8,8);ctx.fill();
    ctx.fillText(s.label+'  '+last+s.unit,lx+11,HH-P.b+11);
    lx+=ctx.measureText(s.label+'  '+last+s.unit).width+22;
  });
}

// ── Fan cards ────────────────────────────────────────────────────────
function renderFans(fans){
  const grid=document.getElementById('fanGrid');
  const colors=['--blue','--cyan','--teal','--violet','--amber','--orange'];
  if(grid.children.length!==fans.length){
    grid.innerHTML='';
    const cols=fans.length<=2?fans.length:fans.length<=4?2:fans.length<=6?3:4;
    grid.style.gridTemplateColumns=`repeat(${cols},1fr)`;
    fans.forEach((f,i)=>{
      const col=colors[i%colors.length],card=document.createElement('div');
      card.className='c';card.id='fanCard'+i;
      card.innerHTML=`
        <div class="c-accent" style="background:linear-gradient(90deg,var(${col}),transparent)"></div>
        <div class="c-bg" style="background:var(${col})"></div>
        <div class="lbl"><div class="lbl-dot" style="background:var(${col})"></div><span id="fanName${i}">${f.name.toUpperCase()}</span>
          <span class="lbl-tag" id="fanSrc${i}">--</span></div>
        <div class="big" style="color:var(${col})" id="fanRpm${i}">--<span class="unit">RPM</span></div>
        <div class="tbar"><div class="tbar-f" id="fanBar${i}" style="width:0%;background:linear-gradient(90deg,var(${col}),var(--cyan))"></div>
          <div class="tbar-w"></div><div class="tbar-c"></div></div>
        <div class="ms" id="fanExtra${i}"></div>
        <div class="ms" id="fanStatus${i}" style="display:none"><span>Status</span><b id="fanStatusVal${i}">--</b></div>`;
      grid.appendChild(card);
    });
  }
  fans.forEach((f,i)=>{
    const pct=Math.min(100,(f.rpm||0)/6500*100);
    document.getElementById('fanRpm'+i).innerHTML=`${f.rpm||0}<span class="unit">RPM</span>`;
    setWidth('fanBar'+i,pct);
    setEl('fanSrc'+i,(f.source||'hwmon').toUpperCase());
    // Extra info row
    const extra=document.getElementById('fanExtra'+i);
    if(f.source==='ec'){
      extra.innerHTML=`<span>Duty</span><b>${f.duty??'--'}/8 (${f.duty!=null?Math.round(f.duty/8*100)+'%':'--'})</b>`;
    } else if(f.source==='ipmi'&&f.status){
      extra.innerHTML=`<span>IPMI status</span><b style="color:${statusColor(f.status)}">${f.status}</b>`;
    } else {
      extra.innerHTML='';
    }
  });
}

// ── IPMI rendering ───────────────────────────────────────────────────
function renderIpmi(ipmi){
  if(!ipmi) return;
  show('ipmiSection');

  // Power
  if(ipmi.power){
    show('ipmiPowerWrap');
    const p=ipmi.power;
    const grid=document.getElementById('ipmiPowerGrid');
    const items=[
      {label:'Now',   val:p.watts_now,  color:'var(--orange)'},
      {label:'Min',   val:p.watts_min,  color:'var(--green)'},
      {label:'Max',   val:p.watts_max,  color:'var(--red)'},
      {label:'Avg',   val:p.watts_avg,  color:'var(--amber)'},
    ].filter(i=>i.val!=null);
    grid.innerHTML=items.map(i=>`
      <div class="c">
        <div class="c-bg" style="background:${i.color}"></div>
        <div class="lbl"><div class="lbl-dot" style="background:${i.color}"></div>${i.label.toUpperCase()} POWER</div>
        <div class="big" style="color:${i.color};font-size:32px">${Math.round(i.val)}<span class="unit">W</span></div>
      </div>`).join('');
    // Show power history button
    show('btnPwr');
  }

  // IPMI temps
  if(ipmi.temps&&ipmi.temps.length){
    show('ipmiTempWrap');
    const grid=document.getElementById('ipmiTempGrid');
    const cols=Math.min(4,ipmi.temps.length);
    grid.style.gridTemplateColumns=`repeat(${cols},1fr)`;
    grid.innerHTML=ipmi.temps.map(t=>{
      const pct=Math.min(100,(t.temp/100)*100);
      const col=tc(t.temp);
      return`<div class="c">
        <div class="lbl"><div class="lbl-dot" style="background:${col}"></div>${t.label.toUpperCase()}</div>
        <div class="mid" style="color:${col}">${t.temp}<span class="unit">°C</span></div>
        <div class="bar-track"><div class="bar-fill" style="width:${pct}%;background:${col}"></div></div>
        <div class="ms"><span>Status</span><b style="color:${statusColor(t.status)}">${t.status}</b></div>
      </div>`;
    }).join('');
  }

  // IPMI fans (only show if not already showing hwmon/EC fans)
  if(ipmi.fans&&ipmi.fans.length){
    // Only show dedicated IPMI fan section if these differ from the main fan cards
    show('irmiFanWrap');
    const grid=document.getElementById('irmiFanGrid');
    const cols=Math.min(4,ipmi.fans.length);
    grid.style.gridTemplateColumns=`repeat(${cols},1fr)`;
    grid.innerHTML=ipmi.fans.map(f=>{
      const pct=Math.min(100,(f.rpm||0)/6500*100);
      const col=statusColor(f.status);
      return`<div class="c">
        <div class="lbl"><div class="lbl-dot" style="background:var(--cyan)"></div>${f.name.toUpperCase()}
          <span class="lbl-tag">IPMI</span></div>
        <div class="mid" style="color:var(--cyan)">${f.rpm}<span class="unit">RPM</span></div>
        <div class="bar-track"><div class="bar-fill" style="width:${pct}%;background:var(--cyan)"></div></div>
        <div class="ms"><span>Status</span><b style="color:${col}">${f.status}</b></div>
      </div>`;
    }).join('');
  }

  // PSU
  if(ipmi.psu&&ipmi.psu.length){
    show('ipmiPsuWrap');
    document.getElementById('ipmiPsuList').innerHTML=ipmi.psu.map(p=>{
      const cls=p.status.toLowerCase().includes('ok')||p.status.toLowerCase().includes('presence')?'psu-ok':
                p.status.toLowerCase().includes('warn')?'psu-warn':'psu-crit';
      const dotColor=cls==='psu-ok'?'var(--green)':cls==='psu-warn'?'var(--amber)':'var(--red)';
      return`<span class="psu-pill ${cls}"><span class="psu-dot" style="background:${dotColor}"></span>${p.name}: ${p.status}</span>`;
    }).join('');
  }

  // Voltages
  if(ipmi.voltages&&ipmi.voltages.length){
    show('ipmiVoltWrap');
    const grid=document.getElementById('ipmiVoltGrid');
    const cols=Math.min(4,Math.ceil(ipmi.voltages.length/2));
    grid.style.gridTemplateColumns=`repeat(${cols},1fr)`;
    if(!grid.hasChildNodes()||grid.children.length!==ipmi.voltages.length){
      grid.innerHTML=`<div class="c c-full"><div class="lbl"><div class="lbl-dot" style="background:var(--teal)"></div>RAIL VOLTAGES</div>
        <div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:6px" id="voltInner"></div></div>`;
    }
    const inner=document.getElementById('voltInner');
    inner.innerHTML=ipmi.voltages.map(v=>{
      const col=v.status.toLowerCase()==='ok'?'var(--green)':v.status.toLowerCase().includes('warn')?'var(--amber)':'var(--red)';
      return`<div class="ms"><span>${v.label}</span><b style="color:${col}">${v.value} ${v.unit}</b></div>`;
    }).join('');
  }
}

// ── Main poll ────────────────────────────────────────────────────────
async function poll(){
  try{
    const r=await fetch(API+'/api/status',{headers:_headers(),signal:AbortSignal.timeout(10000)});
    const d=await r.json();if(!d.ok)throw 0;
    document.getElementById('dot').className='pulse ok';
    setEl('stxt','LIVE');
    setEl('modelLabel',(d.model||'PROXMOX HOST')+' · PVE HARDWARE MONITOR');
    setEl('fModel',d.model||'--');
    setEl('fBios',d.bios||'--');
    const now=new Date().toLocaleTimeString();setEl('fTime',now);

    // Fans
    if(d.fans&&d.fans.length)renderFans(d.fans);

    // CPU
    const cpuT=d.cpu_temp||0;
    document.getElementById('cpuPkg').innerHTML=`${cpuT}<span class="unit">°C</span>`;
    document.getElementById('cpuPkg').style.color=tc(cpuT);
    setEl('cpuPkgSub',cpuT>80?'⚠ HIGH':cpuT>65?'WARM':'NORMAL');
    setEl('cpuGaugeVal',cpuT);setArc('cpuArc',cpuT);
    if(d.core_temps&&d.core_temps.length){
      document.getElementById('coreGrid').innerHTML=d.core_temps.map(c=>{
        const p=Math.min(100,(c.temp/100)*100);
        return`<div class="chip"><div class="chip-val" style="color:${tc(c.temp)}">${c.temp}°</div>
          <div class="chip-name">${c.label}</div>
          <div class="chip-bar"><div class="chip-bar-f" style="width:${p}%;background:${tc(c.temp)}"></div></div></div>`;
      }).join('');
    }
    setEl('ecT',d.ec_temp!=null?d.ec_temp+'°C':'--'); setColor('ecT',tc(d.ec_temp));
    setEl('pchT',d.pch_temp!=null?d.pch_temp+'°C':'--'); setColor('pchT',tc(d.pch_temp));
    setEl('boardT',d.board_temp!=null?d.board_temp+'°C':'--'); setColor('boardT',tc(d.board_temp));

    // NVMe
    if(d.nvme&&d.nvme.length){
      document.getElementById('nvmeGrid').innerHTML=d.nvme.map(n=>{
        const p=Math.min(100,(n.temp/80)*100);
        return`<div class="chip"><div class="chip-val" style="color:${tcN(n.temp)}">${n.temp}°</div>
          <div class="chip-name">${n.label}</div>
          <div class="chip-bar"><div class="chip-bar-f" style="width:${p}%;background:${tcN(n.temp)}"></div></div></div>`;
      }).join('');
      document.getElementById('nvmeStats').innerHTML=d.nvme
        .map(n=>`<div class="ms"><span>${n.label}</span><b style="color:${tcN(n.temp)}">${n.temp}°C</b></div>`).join('');
    }

    // Battery
    const b=d.battery;
    if(b&&b.capacity!=null){
      show('batCard');
      const bp=b.capacity||0,bc=bp<20?'var(--red)':bp<45?'var(--amber)':'var(--green)';
      document.getElementById('batPct').innerHTML=`${bp}<span class="unit">%</span>`;
      document.getElementById('batPct').style.color=bc;
      setEl('batStatus',b.status||'--');setEl('batSt',b.status||'--');
      setEl('batPctGauge',bp);setArc('batArc',bp);
      document.getElementById('batG1').setAttribute('stop-color',bp<20?'#ff3d5c':bp<45?'#ffc030':'#00df8c');
      document.getElementById('batG2').setAttribute('stop-color',bp<20?'#ff6080':bp<45?'#ffdb80':'#00c9a7');
      setEl('batP',b.power!=null?b.power+' W':'--');
      setEl('batV',b.voltage!=null?b.voltage+' V':'--');
      setEl('batE',b.energy_now!=null?`${b.energy_now} / ${b.energy_full} Wh`:'--');
      if(b.cycles!=null){show('batCycleRow');setEl('batCycles',b.cycles+' cycles')}
    }

    // IPMI
    if(d.has_ipmi&&d.ipmi)renderIpmi(d.ipmi);

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
        setEl('sMem',`${ug} / ${tg} GB (${s.mem.pct}%)`);setWidth('memBar',s.mem.pct);
      }
    }

    // Fan profile
    if(d.has_boost){
      show('modeCard');
      const ml={normal:'Normal',boost:'Boost',silent:'Silent'};
      setEl('fMode',ml[d.mode]||d.mode||'--');
      setColor('fMode',d.mode==='boost'?'var(--red)':d.mode==='silent'?'var(--green)':'var(--blue)');
      ['m0','m1','m2'].forEach(id=>document.getElementById(id).classList.toggle('on',d.mode_raw===parseInt(id[1])));
    }

    // History
    H.cpuR.push((d.fans[0]||{}).rpm||0);
    H.gpuR.push((d.fans[1]||{}).rpm||0);
    H.cpuT.push(d.cpu_temp||0);
    H.nvmeT.push(d.nvme&&d.nvme[0]?d.nvme[0].temp:0);
    H.watts.push(d.ipmi&&d.ipmi.power?d.ipmi.power.watts_now||0:0);
    if(H.cpuR.length>MAX){H.cpuR.shift();H.gpuR.shift();H.cpuT.shift();H.nvmeT.shift();H.watts.shift()}
    drawChart();

    // Alerts
    const alerts=[];
    if(d.cpu_temp>90)alerts.push('CPU '+d.cpu_temp+'°C — critical');
    if(d.nvme&&d.nvme.some(n=>n.temp>70))alerts.push('NVMe temp critical');
    if(d.battery&&d.battery.capacity<10)alerts.push('Battery '+d.battery.capacity+'% — very low');
    if(d.ipmi&&d.ipmi.temps)d.ipmi.temps.filter(t=>t.status&&t.status.toLowerCase().includes('crit'))
      .forEach(t=>alerts.push('IPMI: '+t.label+' '+t.temp+'°C — '+t.status));
    if(d.ipmi&&d.ipmi.psu)d.ipmi.psu.filter(p=>!p.status.toLowerCase().includes('ok')&&!p.status.toLowerCase().includes('presence'))
      .forEach(p=>alerts.push('PSU: '+p.name+' — '+p.status));
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
    const r=await fetch(API+'/api/mode',{method:'POST',headers:_headers(),body:JSON.stringify({mode:m}),signal:AbortSignal.timeout(5000)});
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

  # Patch API URL with detected host IP
  sed -i "s|http://localhost:9099|http://${HOST_IP}:${API_PORT}|g" "${INSTALL_DIR}/${DASHBOARD_FILE}"
  msg_ok "Dashboard generated at ${INSTALL_DIR}/${DASHBOARD_FILE} (API → http://${HOST_IP}:${API_PORT})"
}

# ── Create Systemd Service ───────────────────────────────────────────
create_service() {
  msg_info "Creating systemd service..."

  # Create dedicated low-privilege user for the service
  if ! id pve-hwmon &>/dev/null; then
    useradd -r -s /sbin/nologin -d /opt/pve-hwmonitor -c "PVE Hardware Monitor" pve-hwmon
    msg_ok "Created system user: pve-hwmon"
  fi

  # Grant pve-hwmon access to required paths
  chown -R pve-hwmon:pve-hwmon "${INSTALL_DIR}"
  # EC access (laptops)
  if [[ "$HAS_EC" == "true" ]] && command -v setfacl &>/dev/null; then
    setfacl -m u:pve-hwmon:r "${EC_PATH:-/sys/kernel/debug/ec/ec0/io}" 2>/dev/null || true
  fi
  # IPMI group access (servers)
  if [[ "$HAS_IPMI" == "true" ]] && getent group ipmi &>/dev/null; then
    usermod -aG ipmi pve-hwmon 2>/dev/null || true
    msg_ok "Added pve-hwmon to ipmi group"
  fi

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=PVE Hardware Monitor
After=network.target
Documentation=https://github.com/AviFR-dev/PVE-Hardware-Monitor

[Service]
Type=simple
User=pve-hwmon
Group=pve-hwmon
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${API_FILE}
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
# Harden the service
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

  # EC write support for laptops
  if [[ "$HAS_EC" == "true" ]]; then
    grep -q "ec_sys" /etc/modules 2>/dev/null || echo "ec_sys" >> /etc/modules
    [[ -f /etc/modprobe.d/ec_sys.conf ]] || echo "options ec_sys write_support=1" > /etc/modprobe.d/ec_sys.conf
    msg_ok "EC write support configured for boot"
  fi

  # Load IPMI modules persistently
  if [[ "$HAS_IPMI" == "true" ]]; then
    for mod in ipmi_devintf ipmi_si; do
      grep -q "$mod" /etc/modules 2>/dev/null || echo "$mod" >> /etc/modules
    done
    msg_ok "IPMI kernel modules configured for boot"
  fi

  systemctl daemon-reload
  systemctl enable  "${SERVICE_NAME}" --quiet
  systemctl restart "${SERVICE_NAME}"

  sleep 2
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg_ok "Service ${SERVICE_NAME} is running"
  else
    msg_error "Service failed to start. Check: journalctl -u ${SERVICE_NAME}"
    exit 1
  fi
}

# ── Uninstall ────────────────────────────────────────────────────────
uninstall() {
  header
  msg_info "Uninstalling ${APP_NAME}..."
  systemctl stop    "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
  systemctl daemon-reload
  rm -rf "${INSTALL_DIR}"
  msg_ok "${APP_NAME} has been removed."
  msg_info "Note: lm-sensors, ipmitool and ec_sys config were left intact."
  echo ""
  exit 0
}

# ── Print Summary ────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${GN}${BD}  ╔══════════════════════════════════════════════╗"
  echo    "  ║          Installation Complete!              ║"
  echo -e "  ╚══════════════════════════════════════════════╝${CL}"
  echo ""
  echo -e "  ${BD}Dashboard URL:${CL}"
  echo -e "  ${BL}${BD}  http://${HOST_IP}:${API_PORT}/${CL}"
  echo ""
  echo -e "  ${BD}Detected Hardware:${CL}"
  echo -e "  ${DM}  System:  ${SYSTEM_VENDOR} ${SYSTEM_MODEL}${CL}"
  echo -e "  ${DM}  CPU:     ${CPU_MODEL}${CL}"
  echo -e "  ${DM}  EC:      ${HAS_EC}  |  EC Fan Regs: ${EC_FAN_REGS}${CL}"
  echo -e "  ${DM}  IPMI:    ${HAS_IPMI}  |  Interface: ${IPMI_INTERFACE:-n/a}${CL}"
  echo -e "  ${DM}  IPMI sensors: fans=${IPMI_HAS_FANS} temps=${IPMI_HAS_TEMPS} power=${IPMI_HAS_POWER} psu=${IPMI_HAS_PSU} voltages=${IPMI_HAS_VOLTAGE}${CL}"
  echo -e "  ${DM}  Battery: $([ -n "$BAT_PATH" ] && echo "yes ($BAT_PATH)" || echo "no")${CL}"
  echo ""
  echo -e "  ${BD}API Token (keep this secret):${CL}"
  echo -e "  ${YW}  ${API_TOKEN}${CL}"
  echo ""
  echo -e "  ${DM}  Add to dashboard requests as header: X-Api-Token: <token>${CL}"
  echo -e "  ${DM}  Token is stored in: ${INSTALL_DIR}/api.py${CL}"
  echo ""
  echo -e "  ${BD}Firewall (restrict to LAN — recommended):${CL}"
  echo -e "  ${DM}  iptables -A INPUT -p tcp --dport ${API_PORT} -s 10.0.0.0/8 -j ACCEPT${CL}"
  echo -e "  ${DM}  iptables -A INPUT -p tcp --dport ${API_PORT} -s 192.168.0.0/16 -j ACCEPT${CL}"
  echo -e "  ${DM}  iptables -A INPUT -p tcp --dport ${API_PORT} ! -i lo -j DROP${CL}"
  echo ""
  echo -e "  ${BD}Management:${CL}"
  echo -e "  ${DM}  Status:  systemctl status ${SERVICE_NAME}${CL}"
  echo -e "  ${DM}  Logs:    journalctl -u ${SERVICE_NAME} -f${CL}"
  echo -e "  ${DM}  API:     curl -s http://${HOST_IP}:${API_PORT}/api/status | python3 -m json.tool${CL}"
  echo ""
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  [[ "${1:-}" == "--uninstall" ]] && uninstall

  preflight
  detect_hardware
  install_deps
  generate_api
  generate_dashboard
  create_service
  print_summary
}

main "$@"
