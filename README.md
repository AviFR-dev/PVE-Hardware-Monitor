# 🌀 PVE Hardware Monitor

Real-time hardware monitoring dashboard for Proxmox VE hosts. Displays fan RPM, CPU/NVMe/PCH temperatures, battery status, and system metrics through a sleek web interface.

![Dashboard Preview](docs/preview.png)

## Features

- **Fan Monitoring** — Real RPM from EC registers (ASUS laptops) or hwmon sensors
- **Temperature Monitoring** — CPU package & per-core, NVMe, PCH chipset, EC, board
- **Battery Status** — Charge %, power draw, voltage, energy capacity
- **System Metrics** — Uptime, load average, memory usage
- **Fan Profile Control** — Silent / Normal / Boost (ASUS laptops with `fan_boost_mode`)
- **Live History Chart** — 5-minute rolling graph of RPM and temperatures
- **Auto-Detection** — Automatically finds and configures all available sensors
- **Zero Dependencies** — Pure Python API, no frameworks needed

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
| IPMI sensors | 🔜 (planned) |

**Tested on:** ASUS GL503VM, Proxmox VE 8.x / 9.x

## Quick Install

SSH into your Proxmox host as root and run:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/YOUR_USERNAME/pve-hardware-monitor/main/install.sh)"
```

Or with curl:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/pve-hardware-monitor/main/install.sh)"
```

The installer will:
1. Detect your hardware (CPU, fans, EC, battery, sensors)
2. Install `lm-sensors` if missing
3. Generate a customized API server with your sensor paths
4. Deploy the web dashboard
5. Create and start a systemd service
6. Print the dashboard URL

## Access

After installation, open your browser and go to:

```
http://YOUR_PROXMOX_IP:9099/
```

## Uninstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/YOUR_USERNAME/pve-hardware-monitor/main/install.sh)" -- --uninstall
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
  "model": "GL503VM",
  "cpu_temp": 55.0,
  "core_temps": [{"label": "Core 0", "temp": 53.0}, ...],
  "ec_temp": 54,
  "pch_temp": 46.5,
  "nvme": [{"label": "Composite", "temp": 38.9}, ...],
  "fans": [{"name": "CPU", "rpm": 2800, "raw": 770, "duty": 8, "source": "ec"}, ...],
  "battery": {"status": "Full", "capacity": 100, ...},
  "system": {"uptime_s": 16000, "load": [1.5, 1.2, 1.0], "mem": {"total": 16000, "used": 4000, "pct": 25.0}},
  "mode": "normal",
  "has_boost": true
}
```

### `POST /api/mode`

Set fan profile (ASUS laptops only):

```bash
# Silent mode
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 2}'

# Normal mode
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 0}'

# Boost mode
curl -X POST http://localhost:9099/api/mode -H 'Content-Type: application/json' -d '{"mode": 1}'
```

## Configuration

The installer generates config at `/opt/pve-hwmonitor/api.py` with auto-detected sensor paths. To customize:

```bash
nano /opt/pve-hwmonitor/api.py
systemctl restart pve-hwmonitor
```

**Change port:**
Edit `PORT = 9099` in `api.py` and update the systemd service.

## How It Works

The monitor reads sensor data from multiple sources:

1. **hwmon** (`/sys/class/hwmon/`) — Standard Linux hardware monitoring (CPU temp, NVMe, PCH, fan RPM)
2. **EC registers** (`/sys/kernel/debug/ec/ec0/io`) — Embedded Controller for laptop-specific sensors (real fan RPM, board temp)
3. **sysfs** (`/sys/class/power_supply/`) — Battery information
4. **procfs** (`/proc/`) — System uptime, load, memory

For ASUS laptops, fan RPM is read directly from EC registers 0x66/0x68 using the formula from the ACPI DSDT: `RPM = 2,156,250 / raw_value`.

## Contributing

1. Fork the repository
2. Test the installer on your hardware
3. Submit a PR with your system info added to the supported hardware table

**Adding support for new hardware:**
- Run `sensors` and share the output
- Check `/sys/class/hwmon/hwmon*/name` for available sensors
- If using a laptop, check if EC is accessible at `/sys/kernel/debug/ec/ec0/io`

## License

MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- [ASUS Fan Control](https://github.com/dominiksalvet/asus-fan-control) — ACPI fan control research
- [NBFC Linux](https://github.com/nbfc-linux/nbfc-linux) — Notebook fan control
- [Meliox PVE-mods](https://github.com/Meliox/PVE-mods) — Proxmox sensor display mod
- [Proxmox VE Community Scripts](https://github.com/community-scripts/ProxmoxVE) — Installer style inspiration
