#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
#  PVE Hardware Monitor v2.0 - Install Script
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

# Colors
BL='\033[36m'; GN='\033[32m'; YW='\033[33m'; RD='\033[31m'; DM='\033[90m'; BD='\033[1m'; CL='\033[0m'
CHECKMARK="${GN}✓${CL}"; CROSSMARK="${RD}✗${CL}"; ARROW="${BL}▸${CL}"; WARN="${YW}⚠${CL}"

# Defaults
APP_NAME="PVE Hardware Monitor"
APP_VERSION="2.0.0"
API_PORT=9099
INSTALL_DIR="/opt/pve-hwmonitor"
SERVICE_NAME="pve-hwmonitor"
CONFIG_FILE="config.json"
DASHBOARD_FILE="dashboard.html"
SERVER_FILE="server.py"

msg_info()  { echo -e " ${ARROW} ${1}"; }
msg_ok()    { echo -e " ${CHECKMARK} ${1}"; }
msg_warn()  { echo -e " ${WARN} ${1}"; }
msg_error() { echo -e " ${CROSSMARK} ${1}"; }

header() {
  clear
  echo -e "${BL}${BD}"
  echo "  ╔══════════════════════════════════════════════╗"
  echo "  ║       PVE Hardware Monitor Installer         ║"
  echo "  ║       Real-time Proxmox HW Dashboard        ║"
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

  # NVMe
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

  if [[ -c /dev/ipmi0 || -c /dev/ipmi/0 || -c /dev/ipmikcs ]]; then
    msg_ok "IPMI device node found"
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si 2>/dev/null || true
    sleep 1
  fi

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
    if [[ -c /dev/ipmi0 || -c /dev/ipmi/0 ]]; then
      SHOULD_INSTALL_IPMI="true"
    else
      SHOULD_INSTALL_IPMI="false"
    fi
  fi

  # Probe IPMI SDR
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

  # Generate API token
  API_TOKEN=$(python3 -c "import secrets; print(secrets.token_hex(32))")
  msg_ok "API token generated"

  echo ""
}

# ── Install Dependencies ─────────────────────────────────────────────
install_deps() {
  msg_info "Installing dependencies..."

  apt-get update -qq >/dev/null
  apt-get install -y -qq lm-sensors >/dev/null
  msg_ok "lm-sensors installed"

  if [[ "$HAS_IPMI" == "true" || "${SHOULD_INSTALL_IPMI:-false}" == "true" || -c /dev/ipmi0 || -c /dev/ipmi/0 ]]; then
    apt-get install -y -qq ipmitool freeipmi-tools >/dev/null
    msg_ok "ipmitool + freeipmi installed"
    modprobe ipmi_devintf 2>/dev/null || true
    modprobe ipmi_si      2>/dev/null || true
    if [[ "$HAS_IPMI" == "false" ]]; then
      for iface in open imb; do
        if timeout 5 ipmitool -I "$iface" mc info &>/dev/null 2>&1; then
          HAS_IPMI="true"; IPMI_INTERFACE="$iface"
          msg_ok "IPMI now accessible via '${iface}'"
          SDR_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Fan 2>/dev/null || echo "")
          TEMP_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Temperature 2>/dev/null || echo "")
          PWR_OUT=$(timeout 15 ipmitool -I "$iface" dcmi power reading 2>/dev/null || echo "")
          PSU_OUT=$(timeout 15 ipmitool -I "$iface" sdr type "Power Supply" 2>/dev/null || echo "")
          VOLT_OUT=$(timeout 15 ipmitool -I "$iface" sdr type Voltage 2>/dev/null || echo "")
          [[ $(echo "$SDR_OUT"  | grep -c "RPM"     || echo 0) -gt 0 ]] && IPMI_HAS_FANS="true"
          [[ $(echo "$TEMP_OUT" | grep -c "degrees" || echo 0) -gt 0 ]] && IPMI_HAS_TEMPS="true"
          [[ "$PWR_OUT" =~ "Watts" ]] && IPMI_HAS_POWER="true"
          [[ -n "$PSU_OUT"  ]] && IPMI_HAS_PSU="true"
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

# ── Generate Config JSON ─────────────────────────────────────────────
generate_config() {
  msg_info "Generating configuration..."

  mkdir -p "${INSTALL_DIR}"

  # Escape strings for JSON (outputs properly quoted JSON string or "null")
  escape_json() {
    if [[ -z "$1" ]]; then
      echo "null"
    else
      printf '%s' "$1" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'
    fi
  }

  SYSTEM_MODEL_ESC=$(escape_json "$SYSTEM_MODEL")
  BIOS_VER_ESC=$(escape_json "$BIOS_VER")
  HW_CORETEMP_ESC=$(escape_json "${HW_CORETEMP:-null}")
  HW_NVME_ESC=$(escape_json "${HW_NVME:-null}")
  HW_PCH_ESC=$(escape_json "${HW_PCH:-null}")
  BOOST_PATH_ESC=$(escape_json "${BOOST_PATH:-null}")
  BAT_PATH_ESC=$(escape_json "${BAT_PATH:-null}")

  cat > "${INSTALL_DIR}/${CONFIG_FILE}" << EOF
{
  "api": {
    "port": ${API_PORT},
    "host": "0.0.0.0",
    "tls": {
      "enabled": false,
      "cert_file": "${INSTALL_DIR}/cert.pem",
      "key_file": "${INSTALL_DIR}/key.pem",
      "auto_generate": true
    },
    "security": {
      "token": "${API_TOKEN}",
      "cors_origins": ["*"],
      "rate_limit": 10,
      "rate_window": 1.0,
      "audit_log": false,
      "audit_file": "${INSTALL_DIR}/audit.log"
    }
  },
  "sensor": {
    "has_ec": ${HAS_EC},
    "ec_fan_regs": ${EC_FAN_REGS},
    "has_boost": ${HAS_BOOST},
    "has_ipmi": ${HAS_IPMI},
    "ipmi_interface": "${IPMI_INTERFACE:-open}",
    "ipmi_has_fans": ${IPMI_HAS_FANS},
    "ipmi_has_temps": ${IPMI_HAS_TEMPS},
    "ipmi_has_power": ${IPMI_HAS_POWER},
    "ipmi_has_psu": ${IPMI_HAS_PSU},
    "ipmi_has_voltage": ${IPMI_HAS_VOLTAGE},
    "paths": {
      "ec_path": "/sys/kernel/debug/ec/ec0/io",
      "boost_path": __BOOST_PATH__,
      "bat_path": __BAT_PATH__,
      "hw_coretemp": __HW_CORETEMP__,
      "hw_nvme": __HW_NVME__,
      "hw_pch": __HW_PCH__
    }
  },
  "alert": {
    "enabled": true,
    "thresholds": {
      "cpu_warn": 80.0,
      "cpu_crit": 90.0,
      "nvme_warn": 55.0,
      "nvme_crit": 70.0,
      "battery_warn": 20.0,
      "battery_crit": 10.0,
      "fan_min_rpm": 500
    }
  },
  "cluster": {
    "enabled": false,
    "poll_interval": 3.0,
    "nodes": []
  },
  "cache": {
    "ipmi_cache_ttl": 2.0,
    "ipmi_cache_file": "${INSTALL_DIR}/ipmi_cache.json"
  },
  "history": {
    "enabled": true,
    "max_points": 100,
    "retention_minutes": 60
  },
  "system_model": "${SYSTEM_MODEL_ESC}",
  "bios_ver": "${BIOS_VER_ESC}",
  "sdr_cache": "${INSTALL_DIR}/sdr.cache"
}
EOF

  chmod 600 "${INSTALL_DIR}/${CONFIG_FILE}"

  # Use sed to replace placeholders
  sed -i "s|__BOOST_PATH__|${BOOST_PATH_ESC:-null}|g" "${INSTALL_DIR}/${CONFIG_FILE}"
  sed -i "s|__BAT_PATH__|${BAT_PATH_ESC:-null}|g" "${INSTALL_DIR}/${CONFIG_FILE}"
  sed -i "s|__HW_CORETEMP__|${HW_CORETEMP_ESC:-null}|g" "${INSTALL_DIR}/${CONFIG_FILE}"
  sed -i "s|__HW_NVME__|${HW_NVME_ESC:-null}|g" "${INSTALL_DIR}/${CONFIG_FILE}"
  sed -i "s|__HW_PCH__|${HW_PCH_ESC:-null}|g" "${INSTALL_DIR}/${CONFIG_FILE}"

  msg_ok "Configuration saved to ${INSTALL_DIR}/${CONFIG_FILE}"
}

# ── Generate API Server ──────────────────────────────────────────────
generate_server() {
  msg_info "Generating API server..."

  cat > "${INSTALL_DIR}/${SERVER_FILE}" << 'PYEOF'
#!/usr/bin/env python3
"""PVE Hardware Monitor API Server v2.0"""
import asyncio
import json
import os
import ssl
import sys
import time
import traceback
import hmac
from dataclasses import asdict
from pathlib import Path
from collections import defaultdict
from typing import Optional
import threading

VERSION = "2.0.0"
INSTALL_DIR = Path("/opt/pve-hwmonitor")
CONFIG_FILE = INSTALL_DIR / "config.json"


def load_config() -> dict:
    if not CONFIG_FILE.exists():
        return {}
    with open(CONFIG_FILE) as f:
        return json.load(f)


def save_config(cfg: dict) -> None:
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(cfg, f, indent=2)


config = load_config()

PORT = config.get("api", {}).get("port", 9099)
HOST = config.get("api", {}).get("host", "0.0.0.0")
API_TOKEN = os.environ.get("PVE_HWM_TOKEN", config.get("api", {}).get("security", {}).get("token", ""))
SECURITY = config.get("api", {}).get("security", {})
CORS_ORIGINS = SECURITY.get("cors_origins", ["*"])
RATE_LIMIT = SECURITY.get("rate_limit", 10)
RATE_WINDOW = SECURITY.get("rate_window", 1.0)
AUDIT_LOG = SECURITY.get("audit_log", False)
AUDIT_FILE = SECURITY.get("audit_file", str(INSTALL_DIR / "audit.log"))

SENSOR = config.get("sensor", {})
HAS_EC = SENSOR.get("has_ec", False)
EC_FAN_REGS = SENSOR.get("ec_fan_regs", False)
HAS_BOOST = SENSOR.get("has_boost", False)
HAS_IPMI = SENSOR.get("has_ipmi", False)
IPMI_INTERFACE = SENSOR.get("ipmi_interface", "open")
IPMI_HAS_FANS = SENSOR.get("ipmi_has_fans", False)
IPMI_HAS_TEMPS = SENSOR.get("ipmi_has_temps", False)
IPMI_HAS_POWER = SENSOR.get("ipmi_has_power", False)
IPMI_HAS_PSU = SENSOR.get("ipmi_has_psu", False)
IPMI_HAS_VOLTAGE = SENSOR.get("ipmi_has_voltage", False)
EC_PATH = SENSOR.get("paths", {}).get("ec_path", "/sys/kernel/debug/ec/ec0/io")
BOOST_PATH = SENSOR.get("paths", {}).get("boost_path") or ""
BAT_PATH = SENSOR.get("paths", {}).get("bat_path") or ""
HW_CORETEMP = SENSOR.get("paths", {}).get("hw_coretemp") or ""
HW_NVME = SENSOR.get("paths", {}).get("hw_nvme") or ""
HW_PCH = SENSOR.get("paths", {}).get("hw_pch") or ""
SYSTEM_MODEL = config.get("system_model", "Unknown")
SDR_CACHE = config.get("sdr_cache", str(INSTALL_DIR / "sdr.cache"))

CACHE = config.get("cache", {})
IPMI_CACHE_TTL = CACHE.get("ipmi_cache_ttl", 2.0)
IPMI_CACHE_FILE = CACHE.get("ipmi_cache_file", str(INSTALL_DIR / "ipmi_cache.json"))

ALERT = config.get("alert", {})
ALERT_ENABLED = ALERT.get("enabled", True)
THRESHOLDS = ALERT.get("thresholds", {})

SAFE_READ_PREFIXES = ("/sys/", "/proc/", "/opt/pve-hwmonitor/", "/dev/")
ALLOWED_WRITE_PATHS = {BOOST_PATH} if BOOST_PATH else set()

_ipmi_cache: dict = {}
_ipmi_cache_time: float = 0
_rate_lock = threading.Lock()
_rate_counts: dict = defaultdict(lambda: [0, 0.0])


def _safe_read_path(p: str) -> bool:
    if not p:
        return False
    try:
        real = os.path.realpath(p)
        return any(real.startswith(px) for px in SAFE_READ_PREFIXES)
    except (OSError, ValueError):
        return False


def rf(p: str) -> Optional[str]:
    if not _safe_read_path(p):
        return None
    try:
        with open(p) as f:
            return f.read().strip()
    except Exception:
        return None


def ri(p: str) -> Optional[int]:
    v = rf(p)
    if v and v.lstrip("-").isdigit():
        return int(v)
    return None


def wf(p: str, v: str) -> bool:
    if not p or p not in ALLOWED_WRITE_PATHS:
        return False
    try:
        with open(p, "w") as f:
            f.write(str(v))
        return True
    except Exception:
        return False


def _log(ctx: str, msg: str) -> None:
    print(f"[ERROR] {ctx}: {msg}", flush=True)


def _log_exc(ctx: str) -> None:
    print(f"[ERROR] {ctx}:\n{traceback.format_exc()}", flush=True)


def read_ec(o: int, c: int = 1) -> Optional[bytes]:
    if not HAS_EC:
        return None
    try:
        with open(EC_PATH, "rb") as f:
            f.seek(o)
            return f.read(c)
    except Exception:
        return None


def get_temps(hw_path: str, max_idx: int = 16) -> list:
    if not hw_path:
        return []
    items = []
    for i in range(1, max_idx):
        t = ri(f"{hw_path}temp{i}_input")
        if t is None:
            continue
        lbl = rf(f"{hw_path}temp{i}_label") or f"Sensor {i}"
        items.append({"label": lbl, "temp": round(t / 1000, 1)})
    return items


def get_fans_hwmon() -> list:
    import glob
    fans = []
    for f in sorted(glob.glob("/sys/class/hwmon/hwmon*/fan*_input")):
        if not _safe_read_path(f):
            continue
        val = ri(f)
        if val is None:
            continue
        import os
        hwname = rf(os.path.join(os.path.dirname(f), "name")) or "?"
        label = rf(f.replace("_input", "_label")) or os.path.basename(f).replace("_input", "")
        fans.append({"name": f"{hwname}/{label}", "rpm": val, "source": "hwmon"})
    return fans


def get_fans_ec() -> list:
    if not EC_FAN_REGS:
        return []
    import struct
    fans = []
    for name, offset, duty_offset in [("CPU", 0x66, 0x97), ("GPU", 0x68, 0x98)]:
        raw_b = read_ec(offset, 2)
        duty_b = read_ec(duty_offset)
        raw = struct.unpack("<H", raw_b)[0] if raw_b else 0
        duty = struct.unpack("B", duty_b)[0] if duty_b else 0
        rpm = round(2156250 / raw) if raw > 0 else 0
        fans.append({"name": name, "rpm": rpm, "raw": raw, "duty": duty, "source": "ec"})
    if all(f["raw"] == 0 for f in fans):
        return []
    return fans


def _sdr_cache_valid() -> bool:
    if not os.path.exists(SDR_CACHE):
        return False
    try:
        st = os.stat(SDR_CACHE)
        return st.st_uid == 0 and not (st.st_mode & 0o022)
    except OSError:
        return False


def _ipmitool(*args, timeout: int = 6):
    import subprocess
    if not HAS_IPMI:
        return []
    try:
        cmd = ["ipmitool", "-I", IPMI_INTERFACE, "-N", "3", "-R", "1"]
        if _sdr_cache_valid():
            cmd += ["-S", SDR_CACHE]
        cmd += list(args)
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout - 1)
        return r.stdout.splitlines() if r.returncode == 0 else []
    except Exception:
        return []


def _parse_sdr_value(line: str):
    import re
    parts = [p.strip() for p in line.split("|")]
    if len(parts) < 3:
        return None
    name = parts[0].strip()
    raw = parts[1].strip()
    status = parts[2].strip().lower()
    m = re.match(r"^([\d.]+)\s*(.*)", raw)
    if not m:
        return None
    try:
        val = float(m.group(1))
    except ValueError:
        return None
    return name, val, m.group(2).strip(), status


def get_ipmi_fans() -> list:
    if not IPMI_HAS_FANS:
        return []
    fans = []
    for line in _ipmitool("sdr", "type", "Fan"):
        r = _parse_sdr_value(line)
        if not r:
            continue
        name, val, unit, status = r
        if "RPM" not in unit.upper():
            continue
        fans.append({"name": name, "rpm": int(val), "status": status, "source": "ipmi"})
    return fans


def get_ipmi_temps() -> list:
    if not IPMI_HAS_TEMPS:
        return []
    temps = []
    for line in _ipmitool("sdr", "type", "Temperature"):
        r = _parse_sdr_value(line)
        if not r:
            continue
        name, val, unit, status = r
        if "degrees" not in unit.lower() and "°" not in unit:
            continue
        if status in ("ns", "na", "n/a"):
            continue
        temps.append({"label": name, "temp": round(val, 1), "status": status})
    return temps


def get_ipmi_power() -> Optional[dict]:
    if not IPMI_HAS_POWER:
        return None
    import re
    result = {}
    for line in _ipmitool("dcmi", "power", "reading", timeout=6):
        line = line.strip()
        for pattern, key in [
            (r"Instantaneous power reading:\s+([\d.]+)\s+Watts", "watts_now"),
            (r"Minimum.*?:\s+([\d.]+)\s+Watts", "watts_min"),
            (r"Maximum.*?:\s+([\d.]+)\s+Watts", "watts_max"),
            (r"Average.*?:\s+([\d.]+)\s+Watts", "watts_avg"),
        ]:
            m = re.search(pattern, line)
            if m:
                result[key] = float(m.group(1))
    return result if result else None


def get_ipmi_psu() -> list:
    if not IPMI_HAS_PSU:
        return []
    psus = []
    for line in _ipmitool("sdr", "type", "Power Supply"):
        r = _parse_sdr_value(line)
        if not r:
            continue
        name, val, unit, status = r
        psus.append({"name": name, "value": val, "unit": unit, "status": status})
    return psus


def get_ipmi_voltages() -> list:
    if not IPMI_HAS_VOLTAGE:
        return []
    volts = []
    for line in _ipmitool("sdr", "type", "Voltage"):
        r = _parse_sdr_value(line)
        if not r:
            continue
        name, val, unit, status = r
        if status in ("ns", "na", "n/a"):
            continue
        volts.append({"label": name, "value": round(val, 3), "unit": unit, "status": status})
    return volts


def get_battery() -> Optional[dict]:
    if not BAT_PATH or not os.path.isdir(BAT_PATH):
        return None
    status = rf(f"{BAT_PATH}/status")
    capacity = ri(f"{BAT_PATH}/capacity")
    e_now = ri(f"{BAT_PATH}/energy_now") or ri(f"{BAT_PATH}/charge_now")
    e_full = ri(f"{BAT_PATH}/energy_full") or ri(f"{BAT_PATH}/charge_full")
    power = ri(f"{BAT_PATH}/power_now") or ri(f"{BAT_PATH}/current_now")
    voltage = ri(f"{BAT_PATH}/voltage_now")
    cycles = ri(f"{BAT_PATH}/cycle_count")
    return {
        "status": status or "Unknown",
        "capacity": capacity,
        "energy_now": round(e_now / 1e6, 2) if e_now else None,
        "energy_full": round(e_full / 1e6, 2) if e_full else None,
        "power": round(power / 1e6, 2) if power else None,
        "voltage": round(voltage / 1e6, 2) if voltage else None,
        "cycles": cycles,
    }


def get_system() -> dict:
    uptime = None
    try:
        with open("/proc/uptime") as f:
            uptime = float(f.read().split()[0])
    except Exception:
        pass
    load = None
    try:
        with open("/proc/loadavg") as f:
            p = f.read().split()
            load = [float(p[0]), float(p[1]), float(p[2])]
    except Exception:
        pass
    mem = {}
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem["total"] = int(line.split()[1]) // 1024
                elif line.startswith("MemAvailable:"):
                    mem["available"] = int(line.split()[1]) // 1024
    except Exception:
        pass
    if "total" in mem and "available" in mem:
        mem["used"] = mem["total"] - mem["available"]
        mem["pct"] = round(mem["used"] / mem["total"] * 100, 1)
    return {"uptime_s": uptime, "load": load, "mem": mem}


def get_ipmi_cached() -> dict:
    global _ipmi_cache, _ipmi_cache_time
    now = time.time()
    if now - _ipmi_cache_time < IPMI_CACHE_TTL and _ipmi_cache:
        return _ipmi_cache
    import concurrent.futures
    ipmi = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as ex:
        futures = {}
        if IPMI_HAS_FANS:
            futures["fans"] = ex.submit(get_ipmi_fans)
        if IPMI_HAS_TEMPS:
            futures["temps"] = ex.submit(get_ipmi_temps)
        if IPMI_HAS_POWER:
            futures["power"] = ex.submit(get_ipmi_power)
        if IPMI_HAS_PSU:
            futures["psu"] = ex.submit(get_ipmi_psu)
        if IPMI_HAS_VOLTAGE:
            futures["voltages"] = ex.submit(get_ipmi_voltages)
        for key, fut in futures.items():
            try:
                ipmi[key] = fut.result(timeout=7)
            except Exception:
                pass
    _ipmi_cache = ipmi
    _ipmi_cache_time = now
    return ipmi


def get_alerts(status: dict) -> list:
    if not ALERT_ENABLED:
        return []
    alerts = []
    t = THRESHOLDS
    if status.get("cpu_temp"):
        if status["cpu_temp"] > t.get("cpu_crit", 90):
            alerts.append({"level": "critical", "message": f"CPU {status['cpu_temp']}°C — critical"})
        elif status["cpu_temp"] > t.get("cpu_warn", 80):
            alerts.append({"level": "warning", "message": f"CPU {status['cpu_temp']}°C — warm"})
    for nvme in status.get("nvme", []):
        if nvme.get("temp", 0) > t.get("nvme_crit", 70):
            alerts.append({"level": "critical", "message": f"NVMe {nvme['label']} {nvme['temp']}°C"})
            break
        elif nvme.get("temp", 0) > t.get("nvme_warn", 55):
            alerts.append({"level": "warning", "message": f"NVMe {nvme['label']} {nvme['temp']}°C"})
            break
    if status.get("battery", {}).get("capacity"):
        cap = status["battery"]["capacity"]
        if cap < t.get("battery_crit", 10):
            alerts.append({"level": "critical", "message": f"Battery {cap}% — very low"})
        elif cap < t.get("battery_warn", 20):
            alerts.append({"level": "warning", "message": f"Battery {cap}% — low"})
    return alerts


def get_status() -> dict:
    import struct
    ec_temp_b = read_ec(0x58)
    ec_temp = struct.unpack("B", ec_temp_b)[0] if ec_temp_b else None
    board_b = read_ec(0xC5)
    board_temp = struct.unpack("B", board_b)[0] if board_b else None

    coretemp_list = get_temps(HW_CORETEMP)
    pkg_temp = coretemp_list[0]["temp"] if coretemp_list else ec_temp
    core_temps = coretemp_list[1:] if len(coretemp_list) > 1 else []

    import glob
    nvme = []
    for hw in sorted(glob.glob("/sys/class/hwmon/hwmon*/")):
        name = rf(hw + "name") or ""
        if "nvme" in name:
            for t in get_temps(hw):
                t["drive"] = hw.split("/")[-2]
                nvme.append(t)

    pch_list = get_temps(HW_PCH)
    pch_temp = pch_list[0]["temp"] if pch_list else None

    ipmi = None
    if HAS_IPMI:
        ipmi_data = get_ipmi_cached()
        ipmi = {
            "fans": ipmi_data.get("fans", []),
            "temps": ipmi_data.get("temps", []),
            "power": ipmi_data.get("power"),
            "psu": ipmi_data.get("psu", []),
            "voltages": ipmi_data.get("voltages", []),
        }
        ipmi_fans = ipmi_data.get("fans", [])
    else:
        ipmi_fans = []

    fans_ec = get_fans_ec()
    fans_hw = get_fans_hwmon()
    if fans_ec:
        fans = fans_ec
    elif fans_hw:
        fans = fans_hw
    elif ipmi_fans:
        fans = ipmi_fans
    else:
        fans = []

    battery = get_battery()
    system = get_system()

    boost_str = rf(BOOST_PATH) if HAS_BOOST else None
    bv = int(boost_str) if boost_str and boost_str.isdigit() else None

    status = {
        "ok": True,
        "model": SYSTEM_MODEL,
        "cpu_temp": pkg_temp,
        "core_temps": core_temps,
        "ec_temp": ec_temp,
        "board_temp": board_temp,
        "pch_temp": pch_temp,
        "nvme": nvme,
        "fans": fans,
        "battery": battery,
        "system": system,
        "ipmi": ipmi,
        "has_ipmi": HAS_IPMI,
        "mode": {0: "normal", 1: "boost", 2: "silent"}.get(bv, "n/a") if bv is not None else "n/a",
        "mode_raw": bv,
        "has_boost": HAS_BOOST,
    }

    status["_alerts"] = get_alerts(status)
    return status


def audit_log(client_ip: str, method: str, path: str, status: int) -> None:
    if not AUDIT_LOG:
        return
    try:
        from datetime import datetime
        with open(AUDIT_FILE, "a") as f:
            f.write(f'{{"ts":"{datetime.utcnow().isoformat()}","ip":"{client_ip}","method":"{method}","path":"{path}","status":{status}}}\n')
    except Exception:
        pass


class Handler:
    pass


import http.server


class PVEHandler(http.server.BaseHTTPRequestHandler):
    def _client_ip(self):
        return self.client_address[0]

    def _cors(self):
        origin = self.headers.get("Origin", "")
        if "*" in CORS_ORIGINS or (origin and origin in CORS_ORIGINS):
            self.send_header("Access-Control-Allow-Origin", origin if origin else "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Api-Token")
        self.send_header("Vary", "Origin")

    def _sec(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")

    def _json(self, code, data):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self._cors()
        self._sec()
        self.end_headers()
        self.wfile.write(json.dumps(data).encode())

    def _rate_check(self):
        now = time.monotonic()
        with _rate_lock:
            count, start = _rate_counts[self._client_ip()]
            if now - start > RATE_WINDOW:
                _rate_counts[self._client_ip()] = [1, now]
                return True
            if count >= RATE_LIMIT:
                self._json(429, {"ok": False, "error": "Too many requests"})
                return False
            _rate_counts[self._client_ip()][0] += 1
        return True

    def _auth_check(self):
        if not API_TOKEN:
            return True
        provided = self.headers.get("X-Api-Token", "")
        if not hmac.compare_digest(provided, API_TOKEN):
            self._json(401, {"ok": False, "error": "Unauthorized"})
            return False
        return True

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        if not self._rate_check():
            return
        audit_log(self._client_ip(), "GET", self.path, 0)

        if self.path == "/api/status":
            try:
                status = get_status()
                alerts = status.pop("_alerts", [])
                resp = {"alerts": alerts}
                resp.update(status)
                audit_log(self._client_ip(), "GET", self.path, 200)
                self._json(200, resp)
            except Exception:
                _log_exc("get_status")
                audit_log(self._client_ip(), "GET", self.path, 500)
                self._json(500, {"ok": False, "error": "Internal server error"})

        elif self.path == "/api/alerts":
            try:
                status = get_status()
                alerts = status.get("_alerts", [])
                self._json(200, {"alerts": alerts})
            except Exception:
                self._json(500, {"ok": False, "error": "Internal server error"})

        elif self.path == "/api/config":
            try:
                cfg = load_config()
                cfg.get("api", {})["security"]["token"] = "***REDACTED***" if cfg.get("api", {}).get("security", {}).get("token") else None
                self._json(200, cfg)
            except Exception:
                self._json(500, {"ok": False, "error": "Internal server error"})

        elif self.path == "/api/metrics":
            try:
                status = get_status()
                lines = ["# HELP pve_hwmonitor_info Hardware monitor info", "# TYPE pve_hwmonitor_info gauge",
                         f'pve_hwmonitor_info{{model="{status.get("model", "")}"}} 1']
                if status.get("cpu_temp"):
                    lines.extend(["# HELP pve_cpu_temperature CPU temperature", "# TYPE pve_cpu_temperature gauge",
                                  f"pve_cpu_temperature {status['cpu_temp']}"])
                for fan in status.get("fans", []):
                    lines.extend(["# HELP pve_fan_rpm Fan speed", "# TYPE pve_fan_rpm gauge",
                                  f'pve_fan_rpm{{name="{fan["name"]}",source="{fan["source"]}"}} {fan["rpm"]}'])
                for nvme in status.get("nvme", []):
                    lines.extend(["# HELP pve_nvme_temperature NVMe temperature", "# TYPE pve_nvme_temperature gauge",
                                  f'pve_nvme_temperature{{label="{nvme["label"]}"}} {nvme["temp"]}'])
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self._sec()
                self.end_headers()
                self.wfile.write("\n".join(lines).encode())
            except Exception:
                self._json(500, {"ok": False, "error": "Internal server error"})

        elif self.path in ("/", "/index.html", "/dashboard.html", "/dashboard"):
            try:
                dash = INSTALL_DIR / "dashboard.html"
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self._sec()
                self.end_headers()
                with open(dash, "rb") as f:
                    self.wfile.write(f.read())
            except Exception:
                _log_exc("serve_dashboard")
                self._json(500, {"ok": False, "error": "Dashboard not found"})

        elif self.path == "/health":
            self._json(200, {"status": "ok", "version": VERSION})

        else:
            self._json(404, {"ok": False, "error": "Not found"})

    def do_POST(self):
        if not self._rate_check():
            return

        length = int(self.headers.get("Content-Length", 0))
        if length > 10240:
            self._json(413, {"ok": False, "error": "Payload too large"})
            return

        body = self.rfile.read(length) if length > 0 else b""

        if self.path == "/api/mode" and HAS_BOOST:
            if not self._auth_check():
                return
            try:
                data = json.loads(body) if body else {}
                mode = int(data.get("mode", -1))
                if mode not in (0, 1, 2):
                    self._json(400, {"ok": False, "error": "mode must be 0, 1, or 2"})
                    return
                names = {0: "Normal", 1: "Boost", 2: "Silent"}
                res = wf(BOOST_PATH, str(mode))
                if res:
                    self._json(200, {"ok": True, "msg": f"Fan profile: {names[mode]}"})
                else:
                    self._json(500, {"ok": False, "error": "Write failed"})
            except Exception:
                _log_exc("set_mode")
                self._json(500, {"ok": False, "error": "Internal server error"})

        elif self.path == "/api/config/thresholds":
            if not self._auth_check():
                return
            try:
                data = json.loads(body) if body else {}
                cfg = load_config()
                t = cfg.setdefault("alert", {}).setdefault("thresholds", {})
                for key in ["cpu_warn", "cpu_crit", "nvme_warn", "nvme_crit", "battery_warn", "battery_crit", "fan_min_rpm"]:
                    if key in data:
                        t[key] = data[key]
                save_config(cfg)
                global THRESHOLDS
                THRESHOLDS = t
                self._json(200, {"ok": True, "msg": "Thresholds updated"})
            except Exception:
                self._json(500, {"ok": False, "error": "Failed to update thresholds"})

        else:
            self._json(404, {"ok": False, "error": "Not found"})

    def log_message(self, format, *args):
        pass


def run_server():
    print(f"PVE Hardware Monitor v{VERSION}")
    print(f"  Config:   {CONFIG_FILE}")
    print(f"  API:      http://{HOST}:{PORT}/")
    print(f"  Dashboard: http://{HOST}:{PORT}/dashboard.html")
    print(f"  Auth:     {'ENABLED' if API_TOKEN else 'DISABLED'}")
    http.server.HTTPServer((HOST, PORT), PVEHandler).serve_forever()


if __name__ == "__main__":
    run_server()
PYEOF

  chmod +x "${INSTALL_DIR}/${SERVER_FILE}"
  msg_ok "Server generated at ${INSTALL_DIR}/${SERVER_FILE}"
}

# ── Deploy Dashboard ────────────────────────────────────────────────
deploy_dashboard() {
  msg_info "Deploying dashboard..."

  cat > "${INSTALL_DIR}/${DASHBOARD_FILE}" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en" data-theme="dark">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>PVE Hardware Monitor</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;600&family=Outfit:wght@300;400;500;600;700&display=swap');
*{margin:0;padding:0;box-sizing:border-box}
:root,[data-theme="dark"]{
  --bg:#07080b;--s1:#0e1117;--s2:#141920;--s3:#1b222e;--s4:#222b3a;
  --bdr:#1e2a3c;--bdr2:#2a3d56;--bdr3:#364f6b;
  --tx:#d6e4f5;--tx2:#8ba3be;--tx3:#4a6480;
  --blue:#3d8ef8;--cyan:#00c8d8;--green:#00df8c;
  --amber:#ffc030;--red:#ff3d5c;--violet:#a87fff;--teal:#00c9a7;
  --blue-a:rgba(61,142,248,.1);--cyan-a:rgba(0,200,216,.1);
  --green-a:rgba(0,223,140,.08);--red-a:rgba(255,61,92,.1);
  --amber-a:rgba(255,192,48,.08);--violet-a:rgba(168,127,255,.1);
}
[data-theme="light"]{
  --bg:#f5f7fa;--s1:#ffffff;--s2:#eef2f7;--s3:#e4eaf3;--s4:#d8e2ee;
  --bdr:#cdd7e4;--bdr2:#b8c5d6;--bdr3:#9eb0c8;
  --tx:#1a2332;--tx2:#4a5a73;--tx3:#7a8ba3;
  --blue:#2a6fd8;--cyan:#0095a8;--green:#00b36a;
  --amber:#cc8800;--red:#d62850;--violet:#7a4fd0;--teal:#00a080;
}
body{font-family:'Outfit',sans-serif;background:var(--bg);color:var(--tx);min-height:100vh;overflow-x:hidden}
.bg-grid{position:fixed;inset:0;pointer-events:none;opacity:.025;
  background-image:linear-gradient(var(--bdr) 1px,transparent 1px),linear-gradient(90deg,var(--bdr) 1px,transparent 1px);
  background-size:32px 32px}
.bg-orb{position:fixed;border-radius:50%;pointer-events:none;filter:blur(140px)}
.orb1{width:600px;height:600px;top:-200px;left:-100px;background:radial-gradient(circle,rgba(61,142,248,.06),transparent 70%)}
.orb2{width:500px;height:500px;bottom:-150px;right:-80px;background:radial-gradient(circle,rgba(0,200,216,.05),transparent 70%)}
.app{max-width:1120px;margin:0 auto;padding:20px 16px 32px;position:relative;z-index:1}
.hdr{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px;padding:14px 18px;
  background:var(--s1);border:1px solid var(--bdr);border-radius:12px;flex-wrap:wrap;gap:10px}
.brand{display:flex;align-items:center;gap:14px}
.brand-icon{width:38px;height:38px;border-radius:9px;
  background:linear-gradient(135deg,#1a56ff 0%,#00c8d8 100%);
  display:grid;place-items:center;flex-shrink:0;position:relative;overflow:hidden}
.brand-icon::after{content:'';position:absolute;inset:0;background:linear-gradient(135deg,rgba(255,255,255,.15),transparent)}
.brand-icon svg{width:20px;height:20px;fill:none;stroke:#fff;stroke-width:2;stroke-linecap:round}
.brand-info h1{font-size:15px;font-weight:600;letter-spacing:-.2px}
.brand-info small{font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3);letter-spacing:.4px}
.hdr-right{display:flex;align-items:center;gap:10px}
.conn-pill{display:flex;align-items:center;gap:7px;padding:6px 14px;
  background:var(--s2);border:1px solid var(--bdr);border-radius:99px;
  font-family:'JetBrains Mono',monospace;font-size:10px;color:var(--tx3)}
.pulse{width:7px;height:7px;border-radius:50%;background:var(--red);flex-shrink:0;position:relative;transition:background .3s}
.pulse.ok{background:var(--green);box-shadow:0 0 0 3px rgba(0,223,140,.15)}
.btn{padding:6px 12px;background:var(--s2);border:1px solid var(--bdr);border-radius:7px;
  color:var(--tx3);font-size:11px;font-family:'Outfit',sans-serif;cursor:pointer;transition:all .2s}
.btn:hover{border-color:var(--bdr3);color:var(--tx)}
.alert-bar{display:none;align-items:center;gap:8px;padding:8px 14px;
  background:rgba(255,61,92,.07);border:1px solid rgba(255,61,92,.2);
  border-radius:8px;margin-bottom:12px;font-size:12px}
.alert-bar.show{display:flex}
.alert-bar svg{flex-shrink:0;width:14px;height:14px;stroke:#ff3d5c;stroke-width:2;fill:none}
[data-theme="light"] .alert-bar{background:rgba(214,40,80,.07);border-color:rgba(214,40,80,.2)}
[data-theme="light"] .alert-bar svg{stroke:#d62850}
.sec{font-size:10px;font-weight:500;text-transform:uppercase;letter-spacing:1.2px;
  color:var(--tx3);margin-bottom:8px;padding-left:2px;display:flex;align-items:center;gap:8px;margin-top:12px}
.sec::after{content:'';flex:1;height:1px;background:var(--bdr)}
.g{display:grid;gap:10px;margin-bottom:0}
.g2{grid-template-columns:1fr 1fr}
.g3{grid-template-columns:1fr 1fr 1fr}
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
.tbar{position:relative;width:100%;height:4px;background:var(--s4);border-radius:2px;margin:8px 0;overflow:hidden}
.tbar-f{height:100%;border-radius:2px;transition:width .6s cubic-bezier(.22,1,.36,1)}
.tbar-w{position:absolute;top:0;bottom:0;left:65%;width:1px;background:rgba(255,192,48,.35)}
.tbar-c{position:absolute;top:0;bottom:0;left:80%;width:1px;background:rgba(255,61,92,.35)}
.bar-track{width:100%;height:3px;background:var(--s4);border-radius:2px;margin:6px 0;overflow:hidden}
.bar-fill{height:100%;border-radius:2px;transition:width .6s cubic-bezier(.22,1,.36,1)}
.ms{display:flex;justify-content:space-between;align-items:center;
  font-family:'JetBrains Mono',monospace;font-size:10.5px;color:var(--tx3);
  padding:4px 0;border-bottom:1px solid rgba(255,255,255,.03)}
.ms:last-child{border-bottom:none}
.ms b{color:var(--tx);font-weight:500}
.chip-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(88px,1fr));gap:6px}
.chip{background:var(--s2);border:1px solid var(--bdr);border-radius:8px;padding:9px 10px;text-align:center}
.chip-val{font-family:'JetBrains Mono',monospace;font-size:17px;font-weight:500;line-height:1}
.chip-name{font-size:9px;color:var(--tx3);margin-top:3px;font-family:'JetBrains Mono',monospace}
.chip-bar{width:100%;height:2px;background:var(--s4);border-radius:1px;margin-top:5px;overflow:hidden}
.chip-bar-f{height:100%;border-radius:1px;transition:width .5s}
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
.gauge-wrap{display:flex;gap:14px;align-items:center;margin-bottom:10px}
.gauge{width:78px;height:78px;flex-shrink:0}
.gauge-info{flex:1}
.uptime-parts{display:flex;gap:7px;margin-bottom:10px}
.upart{background:var(--s3);border-radius:7px;padding:6px 10px;text-align:center;flex:1}
.upart-val{font-family:'JetBrains Mono',monospace;font-size:16px;font-weight:500;color:var(--cyan)}
.upart-lbl{font-size:9px;color:var(--tx3);margin-top:1px;font-family:'JetBrains Mono',monospace}
.chart-wrap{position:relative;height:140px}
canvas{display:block;width:100%!important}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(90px);
  background:var(--s1);border:1px solid var(--bdr);border-radius:9px;
  padding:9px 18px;font-size:11.5px;z-index:99;
  transition:transform .3s cubic-bezier(.22,1,.36,1);box-shadow:0 8px 32px rgba(0,0,0,.5)}
.toast.show{transform:translateX(-50%) translateY(0)}
.toast.ok{border-color:rgba(0,223,140,.35);color:var(--green)}
.toast.err{border-color:rgba(255,61,92,.35);color:var(--red)}
.ftr{font-family:'JetBrains Mono',monospace;font-size:9.5px;color:var(--tx3);
  display:flex;justify-content:space-between;flex-wrap:wrap;gap:6px;
  padding:12px 16px;background:var(--s1);border:1px solid var(--bdr);border-radius:9px;margin-top:10px}
.ftr b{color:var(--tx2);font-weight:500}
@keyframes fadeUp{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:translateY(0)}}
.c{animation:fadeUp .35s ease both}
@media(max-width:760px){.g2,.g3{grid-template-columns:1fr 1fr}}
@media(max-width:480px){.g2,.g3{grid-template-columns:1fr}}
::-webkit-scrollbar{width:5px}::-webkit-scrollbar-track{background:var(--bg)}::-webkit-scrollbar-thumb{background:var(--bdr2);border-radius:3px}
</style>
</head>
<body>
<div class="bg-grid"></div>
<div class="bg-orb orb1"></div><div class="bg-orb orb2"></div>
<div class="app">
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
      <button class="btn" onclick="toggleTheme()" title="Toggle theme">🌓</button>
      <button class="btn" onclick="exportJSON()">📥 JSON</button>
      <button class="btn" onclick="exportCSV()">📥 CSV</button>
      <button class="btn" onclick="poll()">↻ Refresh</button>
      <div class="conn-pill">
        <div class="pulse" id="dot"></div>
        <span id="stxt">CONNECTING</span>
      </div>
    </div>
  </div>
  <div class="alert-bar" id="alertBar">
    <svg viewBox="0 0 24 24"><path d="M10.3 3.3L1.5 18a2 2 0 0 0 1.7 3h17.6a2 2 0 0 0 1.7-3L13.7 3.3a2 2 0 0 0-3.4 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>
    <span id="alertMsg"></span>
  </div>
  <div class="sec">Fan speeds</div>
  <div class="g" id="fanGrid"></div>
  <div class="sec">Temperatures</div>
  <div class="g g3">
    <div class="c">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--amber),transparent)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--amber)"></div>CPU CORES</div>
      <div class="gauge-wrap">
        <svg class="gauge" viewBox="0 0 78 78">
          <circle cx="39" cy="39" r="30" fill="none" stroke="var(--s4)" stroke-width="7"/>
          <circle cx="39" cy="39" r="30" fill="none" stroke="url(#cpuGrad)" stroke-width="7" stroke-linecap="round" stroke-dasharray="0 188" id="cpuArc" style="transition:stroke-dasharray .6s;transform:rotate(-90deg);transform-origin:50% 50%"/>
          <defs><linearGradient id="cpuGrad" x1="0%" y1="0%" x2="100%" y2="0%"><stop offset="0%" stop-color="#ffc030"/><stop offset="100%" stop-color="#ff3d5c"/></linearGradient></defs>
          <text x="39" y="36" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="14" font-weight="600" fill="var(--tx)" id="cpuGaugeVal">--</text>
          <text x="39" y="48" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="8" fill="var(--tx3)">°C</text>
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
      <div class="lbl"><div class="lbl-dot" style="background:var(--violet)"></div>NVME STORAGE</div>
      <div class="chip-grid" id="nvmeGrid"></div>
      <div id="nvmeStats" style="margin-top:8px"></div>
    </div>
    <div class="c" id="batCard" style="display:none">
      <div class="c-accent" style="background:linear-gradient(90deg,var(--green),transparent)"></div>
      <div class="lbl"><div class="lbl-dot" style="background:var(--green)"></div>BATTERY<span class="lbl-tag" id="batStatus">--</span></div>
      <div class="gauge-wrap" style="margin-bottom:6px">
        <svg class="gauge" viewBox="0 0 78 78">
          <circle cx="39" cy="39" r="30" fill="none" stroke="var(--s4)" stroke-width="7"/>
          <circle cx="39" cy="39" r="30" fill="none" stroke="url(#batGrad)" stroke-width="7" stroke-linecap="round" stroke-dasharray="0 188" id="batArc" style="transition:stroke-dasharray .6s;transform:rotate(-90deg);transform-origin:50% 50%"/>
          <defs><linearGradient id="batGrad" x1="0%" y1="0%" x2="100%" y2="0%"><stop offset="0%" stop-color="#00df8c" id="batG1"/><stop offset="100%" stop-color="#00c9a7" id="batG2"/></linearGradient></defs>
          <text x="39" y="36" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="14" font-weight="600" fill="var(--tx)" id="batPctGauge">--</text>
          <text x="39" y="48" text-anchor="middle" font-family="JetBrains Mono,monospace" font-size="8" fill="var(--tx3)">%</text>
        </svg>
        <div class="gauge-info">
          <div class="mid" id="batPct" style="color:var(--green)">--<span class="unit">%</span></div>
          <div class="sub" id="batSt" style="margin-top:4px">--</div>
        </div>
      </div>
      <div class="ms"><span>Power draw</span><b id="batP">--</b></div>
      <div class="ms"><span>Voltage</span><b id="batV">--</b></div>
      <div class="ms"><span>Capacity</span><b id="batE">--</b></div>
    </div>
  </div>
  <div class="sec">System</div>
  <div class="g g2">
    <div class="c">
      <div class="lbl"><div class="lbl-dot" style="background:var(--teal)"></div>SYSTEM METRICS</div>
      <div class="uptime-parts" id="uptimeParts"></div>
      <div class="ms"><span>Load avg</span><b id="sLoad">--</b></div>
      <div class="ms"><span>Memory</span><b id="sMem">--</b></div>
      <div class="bar-track"><div class="bar-fill" id="memBar" style="width:0%;background:linear-gradient(90deg,var(--teal),var(--cyan))"></div></div>
      <div class="ms"><span>Board temp</span><b id="boardT">--</b></div>
    </div>
    <div class="c" id="fanProfileCard">
      <div class="lbl"><div class="lbl-dot" style="background:var(--blue)"></div>FAN PROFILE</div>
      <div class="mode-grid">
        <button class="mbtn silent" id="m2" onclick="setMode(2)"><span class="mbtn-icon">🤫</span>Silent<span class="mbtn-sub">LOW NOISE</span></button>
        <button class="mbtn" id="m0" onclick="setMode(0)"><span class="mbtn-icon">⚖️</span>Normal<span class="mbtn-sub">BALANCED</span></button>
        <button class="mbtn boost" id="m1" onclick="setMode(1)"><span class="mbtn-icon">🔥</span>Boost<span class="mbtn-sub">MAX PERF</span></button>
      </div>
      <div style="margin-top:12px;padding-top:10px;border-top:1px solid var(--bdr)">
        <div class="ms"><span>Active profile</span><b id="fMode" style="color:var(--blue)">--</b></div>
        <div class="ms"><span>Last updated</span><b id="fTime">--</b></div>
      </div>
    </div>
  </div>
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
  <div class="ftr">
    <div>Model&nbsp;<b id="fModel">--</b></div>
    <div>API&nbsp;<b>:9099</b></div>
    <div>Poll&nbsp;<b>3s</b></div>
    <div>Updated&nbsp;<b id="fTime2">--</b></div>
    <div>Uptime&nbsp;<b id="fUptime">--</b></div>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
const API=window.location.origin;
const CIRC=2*Math.PI*30;
const H={cpuR:[],gpuR:[],cpuT:[],nvmeT:[]};
const MAX=100;
let chartMode='all',lastStatus=null;

function tc(t){if(!t)return'var(--tx3)';if(t>85)return'var(--red)';if(t>70)return'var(--amber)';return'var(--green)'}
function tcN(t){if(!t)return'var(--tx3)';if(t>70)return'var(--red)';if(t>55)return'var(--amber)';return'var(--violet)'}
function setEl(id,v){const e=document.getElementById(id);if(e)e.textContent=v}
function setColor(id,c){const e=document.getElementById(id);if(e)e.style.color=c}
function setWidth(id,p){const e=document.getElementById(id);if(e)e.style.width=Math.max(0,Math.min(100,p))+'%'}
function setArc(id,pct){const el=document.getElementById(id);if(!el)return;const f=Math.max(0,Math.min(1,pct/100))*CIRC;el.setAttribute('stroke-dasharray',f.toFixed(1)+' '+CIRC)}
function fmtUptime(s){if(!s)return{d:0,h:0,m:0};return{d:Math.floor(s/86400),h:Math.floor(s%86400/3600),m:Math.floor(s%3600/60)}}
function toggleTheme(){const h=document.documentElement,c=h.getAttribute('data-theme');h.setAttribute('data-theme',c==='dark'?'light':'dark');localStorage.setItem('theme',h.getAttribute('data-theme'));drawChart()}
(function(){const t=localStorage.getItem('theme');if(t)document.documentElement.setAttribute('data-theme',t)})();
function setChart(m){chartMode=m;['btnRPM','btnTemp','btnAll'].forEach(id=>{const b=document.getElementById(id);b.style.borderColor='';b.style.color=''});const k={rpm:'btnRPM',temp:'btnTemp',all:'btnAll'}[m];document.getElementById(k).style.borderColor='var(--blue)';document.getElementById(k).style.color='var(--blue)';drawChart()}
function drawChart(){const cv=document.getElementById('chart'),ctx=cv.getContext('2d');const dpr=window.devicePixelRatio||1,rect=cv.getBoundingClientRect();cv.width=rect.width*dpr;cv.height=140*dpr;ctx.scale(dpr,dpr);const W=rect.width,HH=140,P={t:10,b:22,l:4,r:4};ctx.clearRect(0,0,W,HH);if(H.cpuR.length<2)return;const n=H.cpuR.length,cw=W-P.l-P.r,ch=HH-P.t-P.b,x=i=>P.l+(i/(n-1))*cw;ctx.strokeStyle='rgba(30,42,60,.8)';ctx.lineWidth=.5;for(let i=0;i<=4;i++){const y=P.t+(ch/4)*i;ctx.beginPath();ctx.moveTo(P.l,y);ctx.lineTo(W-P.r,y);ctx.stroke()}const series=[];if(chartMode==='rpm'||chartMode==='all'){const maxR=Math.max(500,...H.cpuR,...H.gpuR),yR=v=>P.t+ch-(v/maxR)*ch;series.push({data:H.cpuR,color:'#3d8ef8',y:yR,label:'CPU fan',unit:'RPM'});series.push({data:H.gpuR,color:'#00c8d8',y:yR,label:'GPU fan',unit:'RPM'})}if(chartMode==='temp'||chartMode==='all'){const minT=Math.min(25,...H.cpuT),maxT=Math.max(60,...H.cpuT),yT=v=>P.t+ch-((v-minT+2)/(maxT-minT+4))*ch;series.push({data:H.cpuT,color:'#ffc030',y:yT,label:'CPU temp',unit:'°C',dash:[3,3]});if(H.nvmeT.some(v=>v>0))series.push({data:H.nvmeT,color:'#a87fff',y:yT,label:'NVMe',unit:'°C',dash:[2,4]})}series.forEach(s=>{ctx.beginPath();ctx.strokeStyle=s.color;ctx.lineWidth=1.5;ctx.lineJoin='round';ctx.lineCap='round';if(s.dash)ctx.setLineDash(s.dash);else ctx.setLineDash([]);s.data.forEach((v,i)=>i?ctx.lineTo(x(i),s.y(v)):ctx.moveTo(x(i),s.y(v)));ctx.stroke();ctx.setLineDash([])})}
function renderFans(fans){const grid=document.getElementById('fanGrid'),colors=['--blue','--cyan','--teal','--violet'];if(grid.children.length!==fans.length){grid.innerHTML='';grid.style.gridTemplateColumns=fans.length===1?'1fr':fans.length===2?'1fr 1fr':'repeat(3,1fr)';fans.forEach((f,i)=>{const col=colors[i%colors.length],card=document.createElement('div');card.className='c';card.innerHTML=`<div class="c-accent" style="background:linear-gradient(90deg,var(${col}),transparent)"></div><div class="lbl"><div class="lbl-dot" style="background:var(${col})"></div>${f.name.toUpperCase()} FAN<span class="lbl-tag" id="fanDuty${i}">--</span></div><div class="big" style="color:var(${col})" id="fanRpm${i}">--<span class="unit">RPM</span></div><div class="tbar"><div class="tbar-f" id="fanBar${i}" style="width:0%;background:linear-gradient(90deg,var(${col}),var(--cyan))"></div><div class="tbar-w"></div><div class="tbar-c"></div></div><div class="ms"><span>Duty cycle</span><b id="fanDutyPct${i}">--</b></div><div class="ms"><span>Source</span><b id="fanSrc${i}" style="color:var(${col})">--</b></div>`;grid.appendChild(card)})}fans.forEach((f,i)=>{const pct=Math.min(100,(f.rpm||0)/6500*100);document.getElementById('fanRpm'+i).innerHTML=`${f.rpm||0}<span class="unit">RPM</span>`;setWidth('fanBar'+i,pct);setEl('fanDuty'+i,(f.duty??'--')+'/8');setEl('fanDutyPct'+i,f.duty!=null?Math.round(f.duty/8*100)+'%':'--');setEl('fanSrc'+i,(f.source||'hwmon').toUpperCase())})}
function renderData(d){document.getElementById('dot').className='pulse ok';setEl('stxt','LIVE');setEl('modelLabel',(d.model||'PROXMOX HOST')+' · PVE HARDWARE MONITOR');setEl('fModel',d.model||'--');const now=new Date().toLocaleTimeString();setEl('fTime',now);setEl('fTime2',now);if(d.fans)renderFans(d.fans);const cpuT=d.cpu_temp||0;document.getElementById('cpuPkg').innerHTML=`${cpuT}<span class="unit">°C</span>`;document.getElementById('cpuPkg').style.color=tc(cpuT);setEl('cpuPkgSub',cpuT>80?'⚠ HIGH':cpuT>65?'WARM':'NORMAL');setEl('cpuGaugeVal',cpuT);setArc('cpuArc',cpuT);if(d.core_temps&&d.core_temps.length){document.getElementById('coreGrid').innerHTML=d.core_temps.map(c=>`<div class="chip"><div class="chip-val" style="color:${tc(c.temp)}">${c.temp}°</div><div class="chip-name">${c.label}</div><div class="chip-bar"><div class="chip-bar-f" style="width:${Math.min(100,c.temp)}%;background:${tc(c.temp)}"></div></div></div>`).join('')}setEl('ecT',d.ec_temp!=null?d.ec_temp+'°C':'--');setEl('pchT',d.pch_temp!=null?d.pch_temp+'°C':'--');setEl('boardT',d.board_temp!=null?d.board_temp+'°C':'--');setColor('ecT',tc(d.ec_temp));setColor('pchT',tc(d.pch_temp));setColor('boardT',tc(d.board_temp));if(d.nvme&&d.nvme.length){document.getElementById('nvmeGrid').innerHTML=d.nvme.map(n=>`<div class="chip"><div class="chip-val" style="color:${tcN(n.temp)}">${n.temp}°</div><div class="chip-name">${n.label}</div><div class="chip-bar"><div class="chip-bar-f" style="width:${Math.min(100,(n.temp/80)*100)}%;background:${tcN(n.temp)}"></div></div></div>`).join('')}const b=d.battery;if(b&&b.capacity!=null){document.getElementById('batCard').style.display='';const bp=b.capacity||0;document.getElementById('batPct').innerHTML=`${bp}<span class="unit">%</span>`;document.getElementById('batPct').style.color=bp<20?'var(--red)':bp<45?'var(--amber)':'var(--green)';setEl('batStatus',b.status||'--');setEl('batPctGauge',bp);setArc('batArc',bp);document.getElementById('batG1').setAttribute('stop-color',bp<20?'#ff3d5c':bp<45?'#ffc030':'#00df8c');setEl('batP',b.power!=null?b.power+' W':'--');setEl('batV',b.voltage!=null?b.voltage+' V':'--');setEl('batE',b.energy_now!=null?`${b.energy_now} / ${b.energy_full} Wh`:'--')}const s=d.system;if(s){const ut=fmtUptime(s.uptime_s);document.getElementById('uptimeParts').innerHTML=[{val:ut.d,lbl:'DAYS'},{val:ut.h,lbl:'HRS'},{val:ut.m,lbl:'MIN'}].map(p=>`<div class="ipart"><div class="ipart-val">${String(p.val).padStart(2,'0')}</div><div class="ipart-lbl">${p.lbl}</div></div>`).join('');setEl('sLoad',s.load?s.load.map(v=>v.toFixed(2)).join(' / '):'--');setEl('fUptime',`${ut.d}d ${ut.h}h ${ut.m}m`);if(s.mem&&s.mem.total){const ug=(s.mem.used/1024).toFixed(1),tg=(s.mem.total/1024).toFixed(1),pct=s.mem.pct||0;setEl('sMem',`${ug} / ${tg} GB (${pct}%)`);setWidth('memBar',pct)}}if(d.has_boost){document.getElementById('fanProfileCard').style.display='';const ml={normal:'Normal',boost:'Boost',silent:'Silent'};setEl('fMode',ml[d.mode]||d.mode||'--');setColor('fMode',d.mode==='boost'?'var(--red)':d.mode==='silent'?'var(--green)':'var(--blue)');['m0','m1','m2'].forEach(id=>document.getElementById(id).classList.toggle('on',d.mode_raw===parseInt(id[1])))}else{document.getElementById('fanProfileCard').style.display='none'}H.cpuR.push((d.fans[0]||{}).rpm||0);H.gpuR.push((d.fans[1]||{}).rpm||0);H.cpuT.push(d.cpu_temp||0);H.nvmeT.push(d.nvme&&d.nvme[0]?d.nvme[0].temp:0);if(H.cpuR.length>MAX){H.cpuR.shift();H.gpuR.shift();H.cpuT.shift();H.nvmeT.shift()}drawChart()}
function renderAlerts(d){const alerts=[];(d.alerts||[]).forEach(a=>alerts.push(a.message));if(d.cpu_temp>90)alerts.push('CPU '+d.cpu_temp+'°C — critical');if(d.nvme&&d.nvme.some(n=>n.temp>70))alerts.push('NVMe temp critical');const ab=document.getElementById('alertBar');if(alerts.length){ab.classList.add('show');setEl('alertMsg',alerts.join('  ·  '))}else{ab.classList.remove('show')}}
async function poll(){try{const r=await fetch(API+'/api/status',{signal:AbortSignal.timeout(4000)});const d=await r.json();if(!d.ok)throw 0;lastStatus=d;renderData(d);renderAlerts(d)}catch(e){document.getElementById('dot').className='pulse';setEl('stxt','OFFLINE')}}
async function setMode(m){try{const r=await fetch(API+'/api/mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({mode:m})});const d=await r.json();if(d.ok)toast('ok','✓ '+d.msg);else toast('err','✗ '+(d.error||'Failed'));setTimeout(poll,500)}catch(e){toast('err','✗ Connection failed')}}
function exportJSON(){if(!lastStatus){toast('err','No data');return}const b=new Blob([JSON.stringify(lastStatus,null,2)],{type:'application/json'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='hwmonitor-export.json';a.click();toast('ok','✓ Exported')}
function exportCSV(){if(!lastStatus){toast('err','No data');return}let csv='timestamp,metric,value\n';csv+=`${new Date().toISOString()},cpu_temp,${lastStatus.cpu_temp||''}\n`;(lastStatus.fans||[]).forEach(f=>csv+=`${new Date().toISOString()},${f.name}_rpm,${f.rpm}\n`);const b=new Blob([csv],{type:'text/csv'});const a=document.createElement('a');a.href=URL.createObjectURL(b);a.download='hwmonitor-export.csv';a.click();toast('ok','✓ Exported')}
function toast(t,m){const e=document.getElementById('toast');e.textContent=m;e.className='toast '+t+' show';setTimeout(()=>e.className='toast',3000)}
window.addEventListener('resize',drawChart);setChart('all');poll();setInterval(poll,3000);
</script>
</body>
</html>
HTMLEOF

  msg_ok "Dashboard deployed to ${INSTALL_DIR}/${DASHBOARD_FILE}"
}

# ── Build IPMI SDR Cache ─────────────────────────────────────────────
build_sdr_cache() {
  if [[ "$HAS_IPMI" != "true" ]]; then
    return
  fi

  msg_info "Building IPMI SDR cache..."
  if timeout 60 ipmitool -I "$IPMI_INTERFACE" sdr dump "${INSTALL_DIR}/sdr.cache" 2>/dev/null; then
    chmod 600 "${INSTALL_DIR}/sdr.cache"
    msg_ok "IPMI SDR cache built"
  else
    msg_warn "Could not build SDR cache (this is normal on first run)"
  fi
}

# ── Create Systemd Service ───────────────────────────────────────────
create_service() {
  msg_info "Creating systemd service..."

  cat > "/etc/systemd/system/${SERVICE_NAME}.service" << EOF
[Unit]
Description=PVE Hardware Monitor API Server
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/${SERVER_FILE}
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}"
  msg_ok "Systemd service created"
}

# ── Start Service ───────────────────────────────────────────────────
start_service() {
  msg_info "Starting service..."

  systemctl restart "${SERVICE_NAME}"

  sleep 2

  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    msg_ok "Service started successfully"
  else
    msg_error "Service failed to start. Check logs with:"
    msg_info "  journalctl -u ${SERVICE_NAME} -n 50"
  fi
}

# ── Main ─────────────────────────────────────────────────────────────
main() {
  preflight
  detect_hardware
  install_deps
  generate_config
  generate_server
  deploy_dashboard
  build_sdr_cache
  create_service
  start_service

  header
  echo -e " ${GN}${BD}╔═══════════════════════════════════════════════════════╗${CL}"
  echo -e " ${GN}${BD}║          Installation Complete!                        ║${CL}"
  echo -e " ${GN}${BD}╚═══════════════════════════════════════════════════════╝${CL}"
  echo ""
  echo -e "  ${BL}Dashboard:${CL}  http://${HOST_IP}:${API_PORT}/dashboard.html"
  echo -e "  ${BL}API Status:${CL} http://${HOST_IP}:${API_PORT}/api/status"
  echo -e "  ${BL}API Token:${CL}  ${API_TOKEN:0:8}..."
  echo ""
  echo -e "  ${DM}Token saved in:${CL} ${INSTALL_DIR}/${CONFIG_FILE}"
  echo -e "  ${DM}Service logs:${CL}  journalctl -u ${SERVICE_NAME} -f"
  echo ""
}

main
