#!/usr/bin/env python3
"""
System Monitor API for ASUS GL503VM on Proxmox
- Real fan RPM from EC registers 0x66-0x69
- CPU temp from coretemp + EC 0x58
- NVMe temps from hwmon
- Battery info from EC + sysfs
- System info (uptime, load, memory)
"""
import http.server, json, struct, os, glob, time

PORT = 9099
EC_PATH = '/sys/kernel/debug/ec/ec0/io'
BOOST_PATH = '/sys/devices/platform/asus-nb-wmi/fan_boost_mode'

def read_ec(offset, count=1):
    try:
        with open(EC_PATH, 'rb') as f:
            f.seek(offset); return f.read(count)
    except: return None

def read_file(path):
    try:
        with open(path) as f: return f.read().strip()
    except: return None

def write_file(path, value):
    try:
        with open(path, 'w') as f: f.write(str(value)); return True
    except Exception as e: return str(e)

def find_hwmon(name):
    for i in range(20):
        n = read_file(f'/sys/class/hwmon/hwmon{i}/name')
        if n == name: return f'/sys/class/hwmon/hwmon{i}'
    return None

def get_coretemp():
    hw = find_hwmon('coretemp')
    if not hw: return None, []
    pkg = read_file(f'{hw}/temp1_input')
    pkg_temp = int(pkg) / 1000.0 if pkg else None
    cores = []
    for i in range(2, 10):
        t = read_file(f'{hw}/temp{i}_input')
        if t: cores.append(round(int(t) / 1000.0, 1))
    return pkg_temp, cores

def get_nvme_temps():
    hw = find_hwmon('nvme')
    if not hw: return []
    temps = []
    for i in range(1, 5):
        t = read_file(f'{hw}/temp{i}_input')
        lbl = read_file(f'{hw}/temp{i}_label')
        if t:
            temps.append({
                'label': lbl or f'Sensor {i}',
                'temp': round(int(t) / 1000.0, 1)
            })
    return temps

def get_pch_temp():
    hw = find_hwmon('pch_skylake')
    if not hw: return None
    t = read_file(f'{hw}/temp1_input')
    return round(int(t) / 1000.0, 1) if t else None

def get_battery():
    bat_path = '/sys/class/power_supply/BAT1'
    if not os.path.exists(bat_path): bat_path = '/sys/class/power_supply/BAT0'
    if not os.path.exists(bat_path): return None
    status = read_file(f'{bat_path}/status')
    capacity = read_file(f'{bat_path}/capacity')
    energy_now = read_file(f'{bat_path}/energy_now')
    energy_full = read_file(f'{bat_path}/energy_full')
    power_now = read_file(f'{bat_path}/power_now')
    voltage = read_file(f'{bat_path}/voltage_now')
    return {
        'status': status or 'Unknown',
        'capacity': int(capacity) if capacity else None,
        'energy_now': round(int(energy_now)/1e6, 2) if energy_now else None,
        'energy_full': round(int(energy_full)/1e6, 2) if energy_full else None,
        'power': round(int(power_now)/1e6, 2) if power_now else None,
        'voltage': round(int(voltage)/1e6, 2) if voltage else None,
    }

def get_system_info():
    uptime_s = None
    try:
        with open('/proc/uptime') as f:
            uptime_s = float(f.read().split()[0])
    except: pass
    load = None
    try:
        with open('/proc/loadavg') as f:
            parts = f.read().split()
            load = [float(parts[0]), float(parts[1]), float(parts[2])]
    except: pass
    mem = {}
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'): mem['total'] = int(line.split()[1]) // 1024
                elif line.startswith('MemAvailable:'): mem['available'] = int(line.split()[1]) // 1024
    except: pass
    if 'total' in mem and 'available' in mem:
        mem['used'] = mem['total'] - mem['available']
        mem['pct'] = round(mem['used'] / mem['total'] * 100, 1)
    return {'uptime_s': uptime_s, 'load': load, 'mem': mem}

def get_status():
    ec_temp_b = read_ec(0x58)
    ec_temp = struct.unpack('B', ec_temp_b)[0] if ec_temp_b else None
    board_temp_b = read_ec(0xC5)
    board_temp = struct.unpack('B', board_temp_b)[0] if board_temp_b else None

    pkg_temp, core_temps = get_coretemp()
    nvme = get_nvme_temps()
    pch = get_pch_temp()
    battery = get_battery()
    sysinfo = get_system_info()

    cr = read_ec(0x66, 2); gr = read_ec(0x68, 2)
    cpu_raw = struct.unpack('<H', cr)[0] if cr else 0
    gpu_raw = struct.unpack('<H', gr)[0] if gr else 0
    # DSDT formula: 0x0020E6DA / raw / 100
    cpu_rpm = round(2156250 / cpu_raw) if cpu_raw > 0 else 0
    gpu_rpm = round(2156250 / gpu_raw) if gpu_raw > 0 else 0

    cd = read_ec(0x97); gd = read_ec(0x98)
    cpu_duty = struct.unpack('B', cd)[0] if cd else 0
    gpu_duty = struct.unpack('B', gd)[0] if gd else 0

    bs = read_file(BOOST_PATH)
    bv = int(bs) if bs and bs.isdigit() else 0

    return {
        'ok': True,
        'cpu_temp': round(pkg_temp, 1) if pkg_temp else ec_temp,
        'core_temps': core_temps,
        'ec_temp': ec_temp,
        'board_temp': board_temp,
        'pch_temp': pch,
        'nvme': nvme,
        'battery': battery,
        'system': sysinfo,
        'fans': [
            {'name': 'CPU', 'rpm': cpu_rpm, 'raw': cpu_raw, 'duty': cpu_duty},
            {'name': 'GPU', 'rpm': gpu_rpm, 'raw': gpu_raw, 'duty': gpu_duty},
        ],
        'mode': {0:'normal',1:'boost',2:'silent'}.get(bv,'unknown'),
        'mode_raw': bv,
    }

class H(http.server.BaseHTTPRequestHandler):
    def _c(self):
        self.send_header('Access-Control-Allow-Origin','*')
        self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS')
        self.send_header('Access-Control-Allow-Headers','Content-Type')
    def do_OPTIONS(self): self.send_response(200);self._c();self.end_headers()
    def _j(self,code,data):
        self.send_response(code);self.send_header('Content-Type','application/json')
        self._c();self.end_headers();self.wfile.write(json.dumps(data).encode())
    def do_GET(self):
        if self.path=='/api/status':
            try: self._j(200,get_status())
            except Exception as e: self._j(500,{'ok':False,'error':str(e)})
        else: self._j(404,{'ok':False,'error':'not found'})
    def do_POST(self):
        if self.path=='/api/mode':
            try:
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                mode=int(body.get('mode',0))
                if mode not in(0,1,2): self._j(400,{'ok':False,'error':'mode 0/1/2'});return
                names={0:'Normal',1:'Boost',2:'Silent'}
                res=write_file(BOOST_PATH,str(mode))
                if res is True: self._j(200,{'ok':True,'msg':f'Fan profile: {names[mode]}'})
                else: self._j(500,{'ok':False,'error':str(res)})
            except Exception as e: self._j(500,{'ok':False,'error':str(e)})
        else: self._j(404,{'ok':False,'error':'not found'})
    def log_message(self,*a): pass

print(f"GL503VM System Monitor API on port {PORT}")
http.server.HTTPServer(('0.0.0.0',PORT),H).serve_forever()
