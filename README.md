# 🌀 PVE Hardware Monitor

Real-time hardware monitoring dashboard for Proxmox VE hosts. Displays fan RPM, CPU/NVMe/PCH temperatures, battery status, IPMI sensors, and system metrics through a sleek web interface.

![Dashboard Preview](https://github.com/AviFR-dev/PVE-Hardware-Monitor/blob/main/preview.png)

> ⚠️ **Early-stage project.** Tested on a limited set of hardware. IPMI support in particular is new and may behave differently across server vendors and firmware versions. Bugs are expected — please open an issue if you run into one.

## Features

- **Fan Monitoring** — Real RPM from EC registers (ASUS laptops), hwmon sensors, or IPMI
- **Temperature Monitoring** — CPU package & per-core, NVMe, PCH chipset, EC, board, and IPMI inlet/exhaust/CPU
- **IPMI Support** — Fan speeds, temperatures, power consumption (now/min/max/avg watts), PSU status, and voltage rails (servers with iDRAC/iLO/IPMI 2.0)
- **Battery Status** — Charge %, power draw, voltage, energy capacity, cycle count
- **System Metrics** — Uptime, load average, memory usage
- **Fan Profile Control** — Silent / Normal / Boost (ASUS laptops with `fan_boost_mode`)
- **Live History Chart** — 5-minute rolling graph of RPM, temperatures, and power draw
- **Auto-Detection** — Automatically finds and configures all available sensors including IPMI
- **Zero Python Dependencies** — Pure stdlib API, no pip installs needed

## Supported Hardware

| Feature | Support |
|---------|---------|
| CPU temps (Intel coretemp) | ✅ |
| CPU temps (AMD k10temp) | ✅ |
| NVMe temperatures | ✅ |
| PCH/Chipset temps | ✅ (Intel Skylake–Raptor Lake) |
| Fan RPM (hwmon) | ✅ (desktop motherboards) |
| Fan RPM (EC registers) | ✅ (ASUS ROG/Strix/VivoBook laptops) |
| Fan profile (ASUS) | ✅ (`fan_boost_mode` / `throttle_thermal_policy`) |
| Battery monitoring | ✅ (laptops) |
| IPMI fan speeds | ✅ (servers) |
| IPMI temperatures | ✅ (servers) |
| IPMI power consumption | ✅ (via `dcmi power reading`) |
| IPMI PSU status | ✅ (servers) |
| IPMI voltage rails | ✅ (servers) |

**Tested on:** ASUS GL503VM · Dell PowerEdge R740 · Proxmox VE 8.x / 9.x

> Hardware testing is limited. If your system is not listed above, the installer will still attempt auto-detection, but results may vary. PRs with reports from additional hardware are very welcome.

## Quick Install

SSH into your Proxmox host as root and run:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/AviFR-dev/PVE-Hardware-Monitor/main/install.sh)"
```

Or with curl:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/AviFR-dev/PVE-Hardware-Monitor/main/install.sh)"
```

The installer will:
1. Detect your hardware (CPU, fans, EC, battery, IPMI, sensors)
2. Install `lm-sensors` and `ipmitool` if needed
3. Generate a customized API server with your sensor paths
4. Build an SDR sensor cache if IPMI is present
5. Deploy the web dashboard
6. Create and start a systemd service
7. Print the dashboard URL

## Access

After installation, open your browser and go to:

```
http://YOUR_PROXMOX_IP:9099/
```

## Uninstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/AviFR-dev/PVE-Hardware-Monitor/main/install.sh)" -- --uninstall
```

Or manually:

```bash
systemctl stop pve-hwmonitor
systemctl disable pve-hwmonitor
rm -rf /opt/pve-hwmonitor /etc/systemd/system/pve-hwmonitor.service
systemctl daemon-reload
```

## Management

```bash
# Check status
systemctl status pve-hwmonitor

# View logs
journalctl -u pve-hwmonitor -f

# Restart after changes
systemctl restart pve-hwmonitor

# Test API
curl -s http://localhost:9099/api/status | python3 -m json.tool
```

## API

### `GET /api/status`

Returns all sensor data as JSON:

```json
{
  "ok": true,
  "model": "PowerEdge R740",
  "cpu_temp": 42.0,
  "core_temps": [{"label": "Core 0", "temp": 41.0}, "..."],
  "ec_temp": null,
  "pch_temp": null,
  "nvme": [{"label": "Composite", "temp": 38.9}, "..."],
  "fans": [{"name": "Fan1A", "rpm": 4080, "status": "ok", "source": "ipmi"}, "..."],
  "battery": null,
  "system": {"uptime_s": 86400, "load": [0.5, 0.4, 0.3], "mem": {"total": 65536, "used": 8192, "pct": 12.5}},
  "ipmi": {
    "fans": [{"name": "Fan1A", "rpm": 4080, "status": "ok"}, "..."],
    "temps": [{"label": "Inlet Temp", "temp": 22.0, "status": "ok"}, "..."],
    "power": {"watts_now": 168.0, "watts_min": 120.0, "watts_max": 210.0, "watts_avg": 155.0},
    "psu": [{"name": "PS1 Status", "status": "Presence Detected"}, "..."],
    "voltages": [{"label": "CPU1 VCORE PG", "value": 1.782, "unit": "Volts", "status": "ok"}, "..."]
  },
  "has_ipmi": true,
  "mode": "n/a",
  "has_boost": false
}
```

### `POST /api/mode`

Set fan profile (ASUS laptops only):

```bash
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 2}'  # Silent
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 0}'  # Normal
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 1}'  # Boost
```

## Configuration

The installer generates config at `/opt/pve-hwmonitor/api.py` with auto-detected sensor paths. To customize:

```bash
nano /opt/pve-hwmonitor/api.py
systemctl restart pve-hwmonitor
```

**Change port:** Edit `PORT = 9099` in `api.py` and restart the service.

## How It Works

The monitor reads sensor data from multiple sources:

1. **hwmon** (`/sys/class/hwmon/`) — Standard Linux hardware monitoring (CPU temp, NVMe, PCH, fan RPM)
2. **EC registers** (`/sys/kernel/debug/ec/ec0/io`) — Embedded Controller for laptop-specific sensors (real fan RPM, board temp)
3. **IPMI** (`ipmitool`) — Out-of-band BMC data for servers: fan speeds, temperatures, power, PSU health, voltages
4. **sysfs** (`/sys/class/power_supply/`) — Battery information
5. **procfs** (`/proc/`) — System uptime, load, memory

For ASUS laptops, fan RPM is read directly from EC registers 0x66/0x68 using the formula from the ACPI DSDT: `RPM = 2,156,250 / raw_value`.

For servers, IPMI calls run in parallel threads with a hard 6-second wall-clock timeout so a slow or unresponsive BMC never hangs the dashboard.

## IPMI Troubleshooting

**Dashboard loads but IPMI data is missing or blank**

Check that the BMC is accessible:
```bash
ipmitool -I open mc info
```

If this hangs, the kernel IPMI driver may not be loaded:
```bash
modprobe ipmi_devintf
modprobe ipmi_si
ipmitool -I open mc info
```

**First poll is slow on Dell servers**

The initial SDR enumeration can take 30+ seconds on iDRAC. Build the sensor cache once to make subsequent polls instant:
```bash
ipmitool -I open sdr dump /opt/pve-hwmonitor/sdr.cache
systemctl restart pve-hwmonitor
```

The API automatically uses this cache file on every startup if it exists.

**IPMI data disappears after a while**

The SDR cache can go stale after firmware updates. Rebuild it:
```bash
rm /opt/pve-hwmonitor/sdr.cache
ipmitool -I open sdr dump /opt/pve-hwmonitor/sdr.cache
systemctl restart pve-hwmonitor
```

**Known limitations**

- IPMI support is tested on a Dell PowerEdge R740 with iDRAC 9. HP iLO, Supermicro, and other vendors should work but have not been tested
- The `open` interface (in-band via kernel driver) is used by default. Out-of-band `lanplus` is not currently supported
- Some Dell servers return `No reading` for certain SDR entries — these are silently skipped

## Contributing

1. Fork the repository
2. Test the installer on your hardware
3. Submit a PR with your system info added to the supported hardware table

**Adding support for new hardware:**
- Run `sensors` and `ipmitool -I open sdr list` and share the output in your PR or issue
- Check `/sys/class/hwmon/hwmon*/name` for available sensors
- If using a laptop, check if EC is accessible at `/sys/kernel/debug/ec/ec0/io`

**Found a bug?** Open an issue with your hardware model, Proxmox version, and the output of:
```bash
journalctl -u pve-hwmonitor -n 50 --no-pager
curl -s http://localhost:9099/api/status | python3 -m json.tool
```

## License

MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [ASUS Fan Control](https://github.com/dominiksalvet/asus-fan-control) — ACPI fan control research
- [NBFC Linux](https://github.com/nbfc-linux/nbfc-linux) — Notebook fan control
- [Meliox PVE-mods](https://github.com/Meliox/PVE-mods) — Proxmox sensor display mod
- [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) — Installer style inspiration
