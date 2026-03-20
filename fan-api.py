#!/usr/bin/env python3
"""
System Monitor API for ASUS GL503VM on Proxmox
Hardcoded paths based on actual system probing:
  hwmon0=ACAD, hwmon1=acpitz, hwmon2=BAT1, hwmon3=nvme,
  hwmon4=pch_skylake, hwmon5=asus, hwmon6=coretemp, hwmon7=iwlwifi
  Battery: /sys/class/power_supply/BAT1
"""
import http.server, json, struct, os

PORT = 9099
EC_PATH = '/sys/kernel/debug/ec/ec0/io'
BOOST_PATH = '/sys/devices/platform/asus-nb-wmi/fan_boost_mode'
BAT_PATH = '/sys/class/power_supply/BAT1'

# Hardcoded hwmon paths
HW_CORETEMP = '/sys/class/hwmon/hwmon6'
HW_NVME = '/sys/class/hwmon/hwmon3'
HW_PCH = '/sys/class/hwmon/hwmon4'

def read_ec(offset, count=1):
    try:
        with open(EC_PATH, 'rb') as f:
            f.seek(offset); return f.read(count)
    except: return None

def rf(path):
    """Read file, return stripped string or None"""
    try:
        with open(path) as f: return f.read().strip()
    except: return None

def ri(path):
    """Read file as int or None"""
    v = rf(path)
    return int(v) if v and v.lstrip('-').isdigit() else None

def write_file(path, value):
    try:
        with open(path, 'w') as f: f.write(str(value)); return True
    except Exception as e: return str(e)

def get_coretemp():
    pkg = ri(f'{HW_CORETEMP}/temp1_input')
    cores = []
    for i in range(2, 10):
        t = ri(f'{HW_CORETEMP}/temp{i}_input')
        lbl = rf(f'{HW_CORETEMP}/temp{i}_label')
        if t is not None:
            cores.append({'label': lbl or f'Core {i-2}', 'temp': round(t/1000, 1)})
    return round(pkg/1000, 1) if pkg else None, cores

def get_nvme():
    temps = []
    for i in range(1, 5):
        t = ri(f'{HW_NVME}/temp{i}_input')
        lbl = rf(f'{HW_NVME}/temp{i}_label')
        if t is not None:
            temps.append({'label': lbl or f'Sensor {i}', 'temp': round(t/1000, 1)})
    return temps

def get_pch():
    t = ri(f'{HW_PCH}/temp1_input')
    return round(t/1000, 1) if t else None

def get_battery():
    if not os.path.isdir(BAT_PATH): return None
    status = rf(f'{BAT_PATH}/status')
    capacity = ri(f'{BAT_PATH}/capacity')
    # Try energy_now first, fall back to charge_now
    e_now = ri(f'{BAT_PATH}/energy_now')
    e_full = ri(f'{BAT_PATH}/energy_full')
    if e_now is None:
        e_now = ri(f'{BAT_PATH}/charge_now')
        e_full = ri(f'{BAT_PATH}/charge_full')
    power = ri(f'{BAT_PATH}/power_now')
    if power is None:
        power = ri(f'{BAT_PATH}/current_now')
    voltage = ri(f'{BAT_PATH}/voltage_now')
    cycle = ri(f'{BAT_PATH}/cycle_count')
    return {
        'status': status or 'Unknown',
        'capacity': capacity,
        'energy_now': round(e_now/1e6, 2) if e_now else None,
        'energy_full': round(e_full/1e6, 2) if e_full else None,
        'power': round(power/1e6, 2) if power else None,
        'voltage': round(voltage/1e6, 2) if voltage else None,
        'cycles': cycle,
    }

def get_system():
    uptime_s = None
    try:
        with open('/proc/uptime') as f: uptime_s = float(f.read().split()[0])
    except: pass
    load = None
    try:
        with open('/proc/loadavg') as f:
            p = f.read().split(); load = [float(p[0]),float(p[1]),float(p[2])]
    except: pass
    mem = {}
    try:
        with open('/proc/meminfo') as f:
            for line in f:
                if line.startswith('MemTotal:'): mem['total'] = int(line.split()[1])//1024
                elif line.startswith('MemAvailable:'): mem['available'] = int(line.split()[1])//1024
    except: pass
    if 'total' in mem and 'available' in mem:
        mem['used'] = mem['total'] - mem['available']
        mem['pct'] = round(mem['used']/mem['total']*100, 1)
    return {'uptime_s': uptime_s, 'load': load, 'mem': mem}

def get_status():
    ec_temp_b = read_ec(0x58)
    ec_temp = struct.unpack('B', ec_temp_b)[0] if ec_temp_b else None
    board_temp_b = read_ec(0xC5)
    board_temp = struct.unpack('B', board_temp_b)[0] if board_temp_b else None

    pkg_temp, core_temps = get_coretemp()
    nvme = get_nvme()
    pch = get_pch()
    battery = get_battery()
    sysinfo = get_system()

    cr = read_ec(0x66, 2); gr = read_ec(0x68, 2)
    cpu_raw = struct.unpack('<H', cr)[0] if cr else 0
    gpu_raw = struct.unpack('<H', gr)[0] if gr else 0
    cpu_rpm = round(2156250 / cpu_raw) if cpu_raw > 0 else 0
    gpu_rpm = round(2156250 / gpu_raw) if gpu_raw > 0 else 0

    cd = read_ec(0x97); gd = read_ec(0x98)
    cpu_duty = struct.unpack('B', cd)[0] if cd else 0
    gpu_duty = struct.unpack('B', gd)[0] if gd else 0

    bs = rf(BOOST_PATH)
    bv = int(bs) if bs and bs.isdigit() else 0

    return {
        'ok': True,
        'cpu_temp': pkg_temp or ec_temp,
        'core_temps': core_temps,
        'ec_temp': ec_temp,
        'board_temp': board_temp,
        'pch_temp': pch,
        'nvme': nvme,
        'battery': battery,
        'system': sysinfo,
        'fans': [
            {'name':'CPU','rpm':cpu_rpm,'raw':cpu_raw,'duty':cpu_duty},
            {'name':'GPU','rpm':gpu_rpm,'raw':gpu_raw,'duty':gpu_duty},
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
