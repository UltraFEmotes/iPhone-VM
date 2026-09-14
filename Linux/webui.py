#!/usr/bin/env python3
"""iphone-vm web UI: manage and run Inferno iPhone VMs from a browser, for headless/hosting use.

Started by `iphone-vm web <port>`. Serves a single-page UI plus a small REST API that drives the same
backend scripts (install, versions, new, setup, start, stop, press, trust, snapshot, delete). The phone
screen is exposed over VNC through websockify + noVNC; the serial console streams over Server-Sent Events.

Standard library only, except websockify/noVNC (Debian: apt install novnc websockify) for the screen.
"""
import json, os, re, shlex, shutil, socket, subprocess, threading, time, html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BACKEND = os.environ["IPHONE_VM_BACKEND"]
MANIFEST = os.environ["IPHONE_VM_MANIFEST"]
DATA = os.environ["INFERNO_DATA"]
VMS = os.path.join(DATA, "VMs")
TOKEN = os.environ.get("INFERNO_WEB_TOKEN", "")
VNC_WEB_BASE = int(os.environ.get("INFERNO_VNC_WEB_BASE", "6080"))  # per-VM noVNC ports: base, base+1, ...
NOVNC_DIR = next((d for d in ("/usr/share/novnc", "/usr/share/webapps/novnc") if os.path.isdir(d)), None)
STATE_FILES = ["root", "firmware", "syscfg", "ctrl_bits", "nvram", "effaceable", "panic_log", "sep_nvram", "sep_ssc"]


def load_json(path):
    with open(path) as fh:
        return json.load(fh)


def vm_dirs():
    if not os.path.isdir(VMS):
        return []
    out = []
    for d in sorted(os.listdir(VMS)):
        p = os.path.join(VMS, d)
        if os.path.isfile(os.path.join(p, "vm.json")):
            out.append(p)
    return out


def find_vm(vid):
    hits = [p for p in vm_dirs() if os.path.basename(p).lower().startswith(vid.lower())]
    return hits[0] if len(hits) == 1 else None


def running_pid(vm):
    if not vm:
        return None
    try:
        out = subprocess.run(["pgrep", "-f", f"file={vm}/root,format=raw"], capture_output=True, text=True)
        if not out.stdout.strip():
            out = subprocess.run(["pgrep", "-f", f"file={vm}/root.qcow2"], capture_output=True, text=True)
        return int(out.stdout.split()[0]) if out.stdout.strip() else None
    except Exception:
        return None


def safe_snapshot_path(root, name):
    """Keep snapshot operations inside the VM's snapshots directory."""
    if not isinstance(name, str) or not name or name in (".", "..") or "/" in name or "\\" in name or ".." in name:
        raise ValueError("invalid snapshot name")
    root = os.path.abspath(root)
    path = os.path.abspath(os.path.join(root, name))
    if os.path.dirname(path) != root:
        raise ValueError("invalid snapshot name")
    return path


def vm_index(vm):
    return [os.path.basename(p) for p in vm_dirs()].index(os.path.basename(vm))


# ---- one running VM's live state: serial buffer, VNC/websockify, setup log ----

class Session:
    def __init__(self, vm):
        self.vm = vm
        self.serial = bytearray()
        self.serial_sock = None
        self.setup_log = []
        self.setup_running = False
        self.lock = threading.Lock()
        self.novnc = None
        self.qemu = None

    def note(self, text):
        with self.lock:
            self.serial.extend(("\n[" + text + "]\n").encode())

    def append_serial(self, data):
        with self.lock:
            self.serial.extend(data)
            if len(self.serial) > 400_000:
                del self.serial[:200_000]

    def serial_text(self):
        with self.lock:
            return self.serial.decode("utf-8", "replace")


SESSIONS = {}
SESS_LOCK = threading.Lock()


def session(vm):
    with SESS_LOCK:
        s = SESSIONS.get(vm)
        if not s:
            s = SESSIONS[vm] = Session(vm)
        return s


def run_backend(args, on_line=None):
    """Run a backend script, streaming stdout+stderr lines. Returns (exit_code, full_output)."""
    proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    lines = []
    for line in proc.stdout:
        line = line.rstrip("\n")
        lines.append(line)
        if on_line:
            on_line(line)
    proc.wait()
    return proc.returncode, "\n".join(lines)


def start_vm(vm):
    entry = os.path.join(vm, "entry.json")
    meta = load_json(os.path.join(vm, "vm.json"))
    jb = "1" if meta.get("jailbroken") else "0"
    qmp = str(meta.get("qmpPort", 0))
    idx = vm_index(vm)
    vnc_disp = 40 + idx            # QEMU VNC display N -> TCP 5900+N
    serial_port = 7500 + idx
    sess = session(vm)
    sess.note("starting companion VM for USB internet")
    companion_code, _ = run_backend([os.path.join(BACKEND, "companion.sh"), "start"],
                                    sess.append_serial and (lambda l: sess.note(l)))
    if companion_code != 0:
        sess.note("companion failed; booting without USB internet")

    env = dict(os.environ, INFERNO_DISPLAY=f"vnc=127.0.0.1:{vnc_disp}", INFERNO_SERIAL=f"tcp:127.0.0.1:{serial_port}")
    sess.note(f"booting {meta.get('name')}")
    sess.qemu = subprocess.Popen([os.path.join(BACKEND, "start_vm.sh"), vm, entry, jb, qmp],
                                 env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    threading.Thread(target=_pump_serial, args=(sess, serial_port), daemon=True).start()
    if NOVNC_DIR:
        web_port = VNC_WEB_BASE + idx
        _kill_port(web_port)
        sess.novnc = subprocess.Popen(["websockify", "--web", NOVNC_DIR, str(web_port), f"127.0.0.1:{5900 + vnc_disp}"],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return {"vncWebPort": VNC_WEB_BASE + idx if NOVNC_DIR else None}


def _pump_serial(sess, port):
    for _ in range(60):
        try:
            sock = socket.create_connection(("127.0.0.1", port), timeout=2)
            break
        except OSError:
            time.sleep(1)
    else:
        sess.note("serial console did not connect")
        return
    sess.serial_sock = sock
    try:
        while True:
            data = sock.recv(8192)
            if not data:
                break
            sess.append_serial(data)
    except OSError:
        pass
    finally:
        sess.note("VM stopped")
        sess.serial_sock = None


def _kill_port(port):
    subprocess.run(["pkill", "-f", f"websockify --web {NOVNC_DIR} {port} "], capture_output=True)


def qmp(port, command):
    with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as s:
        s.recv(4096)
        s.sendall(b'{"execute":"qmp_capabilities"}\n' + json.dumps(command).encode() + b"\n")
        time.sleep(0.3)


def companion_ssh(remote_cmd):
    key = os.path.join(DATA, "companion_key")
    ssh = ["ssh", "-i", key, "-p", "32222", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
           "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=8", "inferno@localhost", remote_cmd]
    return subprocess.run(ssh, capture_output=True, text=True).stdout


# -------------------- HTTP --------------------

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _auth_ok(self):
        if not TOKEN:
            return True
        q = parse_qs(urlparse(self.path).query)
        return self.headers.get("X-Token") == TOKEN or q.get("token", [""])[0] == TOKEN

    def _send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def _body_json(self):
        n = int(self.headers.get("Content-Length", 0))
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):
        route = urlparse(self.path).path
        if route in ("/", "/index.html"):
            return self._send(200, PAGE, "text/html; charset=utf-8")
        if not self._auth_ok():
            return self._send(401, {"error": "bad or missing token"})
        if route == "/api/state":
            return self._send(200, self._state())
        if route == "/api/versions":
            return self._send(200, load_json(MANIFEST)["entries"])
        m = re.match(r"/api/vms/([^/]+)/serial$", route)
        if m:
            return self._serial_stream(m.group(1))
        m = re.match(r"/api/vms/([^/]+)/setup-log$", route)
        if m:
            vm = find_vm(m.group(1))
            return self._send(200, {"log": "\n".join(session(vm).setup_log)} if vm else {"log": ""})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._auth_ok():
            return self._send(401, {"error": "bad or missing token"})
        route = urlparse(self.path).path
        try:
            if route == "/api/vms":
                return self._new_vm(self._body_json())
            if route == "/api/install":
                threading.Thread(target=run_backend, args=([os.path.join(BACKEND, "install.sh")],), daemon=True).start()
                return self._send(202, {"started": True})
            m = re.match(r"/api/vms/([^/]+)/(setup|start|stop|trust|press|snapshot|delete)$", route)
            if m:
                return self._vm_action(m.group(1), m.group(2), self._body_json())
        except Exception as exc:
            return self._send(500, {"error": str(exc)})
        return self._send(404, {"error": "not found"})

    def do_PUT(self):
        if not self._auth_ok():
            return self._send(401, {"error": "bad or missing token"})
        m = re.match(r"/api/vms/([^/]+)/serial$", urlparse(self.path).path)
        if m:
            vm = find_vm(m.group(1))
            sess = session(vm) if vm else None
            if sess and sess.serial_sock:
                sess.serial_sock.sendall(self._body_json().get("data", "").encode())
                return self._send(200, {"ok": True})
            return self._send(409, {"error": "VM not running"})
        m = re.match(r"/api/vms/([^/]+)/settings$", urlparse(self.path).path)
        if m:
            return self._settings(m.group(1), self._body_json())
        return self._send(404, {"error": "not found"})

    # ---- helpers ----

    def _state(self):
        vms = []
        for p in vm_dirs():
            meta = load_json(os.path.join(p, "vm.json"))
            entry = load_json(os.path.join(p, "entry.json"))
            idx = vm_index(p)
            vms.append({
                "id": os.path.basename(p)[:8], "name": meta.get("name"), "ios": entry.get("ios"),
                "device": entry.get("deviceName"), "jailbroken": meta.get("jailbroken", False),
                "graphicsMode": meta.get("graphicsMode", "default"),
                "performanceMode": meta.get("performanceMode", "balanced"),
                "audioMode": meta.get("audioMode", "stable"),
                "state": "running" if running_pid(p) else meta.get("state", "new"),
                "vncWebPort": (VNC_WEB_BASE + idx) if (NOVNC_DIR and running_pid(p)) else None,
            })
        return {"vms": vms, "installed": os.path.exists(os.path.join(DATA, "Inferno", "build", "qemu-system-aarch64")),
                "novnc": bool(NOVNC_DIR)}

    def _new_vm(self, body):
        eid, name, jb = body.get("version"), body.get("name", ""), bool(body.get("jailbreak"))
        entry = next((e for e in load_json(MANIFEST)["entries"] if e["id"] == eid), None)
        if not entry:
            return self._send(400, {"error": "unknown version"})
        if jb and not entry.get("jailbreak", {}).get("bootstrap"):
            return self._send(400, {"error": f"iOS {entry['ios']} can't be jailbroken"})
        import uuid
        vid = str(uuid.uuid4()).upper()
        used = [load_json(os.path.join(p, "vm.json")).get("qmpPort", 0) for p in vm_dirs()]
        port = next(p for p in range(4450, 4550) if p not in used)
        folder = os.path.join(VMS, vid)
        os.makedirs(folder)
        json.dump(entry, open(os.path.join(folder, "entry.json"), "w"), indent=2)
        json.dump({"id": vid, "name": name or f"{entry['deviceName']} (iOS {entry['ios']})" + (" JB" if jb else ""),
                   "entryID": eid, "jailbroken": jb, "qmpPort": port, "state": "new",
                   "graphicsMode": "default", "performanceMode": "balanced", "audioMode": "stable"},
                  open(os.path.join(folder, "vm.json"), "w"), indent=2)
        return self._send(200, {"id": vid[:8]})

    def _settings(self, vid, body):
        vm = find_vm(vid)
        if not vm:
            return self._send(404, {"error": "no such VM"})
        allowed = {
            "graphicsMode": {"default", "smooth", "fast-half"},
            "performanceMode": {"balanced", "fast", "low-memory"},
            "audioMode": {"stable", "aop", "disabled"},
        }
        if not isinstance(body, dict) or not body or any(
                k not in allowed or not isinstance(body[k], str) or body[k] not in allowed[k] for k in body):
            return self._send(400, {"error": "invalid VM settings"})
        meta = load_json(os.path.join(vm, "vm.json"))
        meta.update(body)
        with open(os.path.join(vm, "vm.json"), "w") as fh:
            json.dump(meta, fh, indent=2)
        return self._send(200, {"ok": True})

    def _vm_action(self, vid, action, body):
        vm = find_vm(vid)
        if not vm:
            return self._send(404, {"error": "no such VM"})
        meta = load_json(os.path.join(vm, "vm.json"))
        if action == "setup":
            return self._setup(vm, meta)
        if action == "start":
            if running_pid(vm):
                return self._send(409, {"error": "already running"})
            if meta.get("state") != "ready":
                return self._send(409, {"error": "finish setup first"})
            return self._send(200, start_vm(vm))
        if action == "stop":
            if running_pid(vm):
                qmp(meta["qmpPort"], {"execute": "quit"})
            return self._send(200, {"ok": True})
        if action == "trust":
            out = companion_ssh("sudo systemctl start usbmuxd; sleep 3; idevicepair pair 2>&1; idevicepair validate 2>&1")
            session(vm).note("trust: " + out.strip())
            return self._send(200, {"output": out})
        if action == "press":
            keys = {"power": "f5", "home": "f6", "volup": "f4", "voldown": "f3", "ringer": "f2"}
            code = keys.get(body.get("button"))
            if not code or not running_pid(vm):
                return self._send(400, {"error": "bad button or VM not running"})
            qmp(meta["qmpPort"], {"execute": "send-key",
                                  "arguments": {"keys": [{"type": "qcode", "data": code}], "hold-time": 120}})
            return self._send(200, {"ok": True})
        if action == "snapshot":
            return self._snapshot(vm, body)
        if action == "delete":
            if running_pid(vm):
                return self._send(409, {"error": "stop it first"})
            shutil.rmtree(vm)
            return self._send(200, {"ok": True})
        return self._send(400, {"error": "unknown action"})

    def _setup(self, vm, meta):
        sess = session(vm)
        if sess.setup_running:
            return self._send(409, {"error": "setup already running"})
        sess.setup_running = True
        sess.setup_log = []

        def work():
            jb = "1" if meta.get("jailbroken") else "0"
            code, out = run_backend([os.path.join(BACKEND, "setup_vm.sh"), vm, os.path.join(vm, "entry.json"), jb],
                                    lambda l: sess.setup_log.append(l))
            m = load_json(os.path.join(vm, "vm.json"))
            m["state"] = "ready" if out.rstrip().endswith("DONE") else "failed"
            json.dump(m, open(os.path.join(vm, "vm.json"), "w"), indent=2)
            sess.setup_running = False

        threading.Thread(target=work, daemon=True).start()
        return self._send(202, {"started": True})

    def _snapshot(self, vm, body):
        act, name = body.get("action", "list"), body.get("name", "")
        snaps = os.path.join(vm, "snapshots")
        if act == "list":
            return self._send(200, {"snapshots": sorted(os.listdir(snaps)) if os.path.isdir(snaps) else []})
        if act not in ("save", "restore", "delete"):
            return self._send(400, {"error": "snapshot actions: save, restore, delete, list"})
        if not name:
            return self._send(400, {"error": "name required"})
        if act in ("save", "restore") and running_pid(vm):
            return self._send(409, {"error": "stop the VM first"})
        try:
            dest = safe_snapshot_path(snaps, name)
        except ValueError as exc:
            return self._send(400, {"error": str(exc)})
        if act == "save":
            if not os.path.exists(os.path.join(vm, "root")):
                return self._send(400, {"error": "run setup first"})
            os.makedirs(dest, exist_ok=True)
            for f in STATE_FILES:
                src = os.path.join(vm, f)
                if os.path.exists(src):
                    subprocess.run(["cp", "--reflink=auto", "--sparse=always", src, dest])
        elif act == "restore":
            if not os.path.exists(os.path.join(dest, "root")):
                return self._send(400, {"error": "no such snapshot"})
            for f in STATE_FILES:
                src = os.path.join(dest, f)
                if os.path.exists(src):
                    subprocess.run(["cp", "--reflink=auto", "--sparse=always", src, os.path.join(vm, f)])
        elif act == "delete":
            if os.path.isdir(dest):
                shutil.rmtree(dest)
        return self._send(200, {"ok": True})

    def _serial_stream(self, vid):
        vm = find_vm(vid)
        if not vm:
            return self._send(404, {"error": "no such VM"})
        sess = session(vm)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        sent = 0
        try:
            while True:
                text = sess.serial_text()
                if len(text) > sent:
                    chunk = text[sent:]
                    sent = len(text)
                    payload = json.dumps(chunk)
                    self.wfile.write(f"data: {payload}\n\n".encode())
                    self.wfile.flush()
                time.sleep(0.5)
        except (BrokenPipeError, ConnectionResetError):
            pass


PAGE = r"""<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>iphone-vm</title><style>
:root{color-scheme:dark}body{margin:0;font:14px system-ui,sans-serif;background:#0b0b0d;color:#e6e6e6}
header{padding:10px 16px;background:#16161a;border-bottom:1px solid #26262c;display:flex;gap:12px;align-items:center}
header b{font-size:16px}.warn{color:#e0a030;font-size:12px}
main{display:flex;gap:0;height:calc(100vh - 46px)}
#list{width:280px;background:#111114;border-right:1px solid #26262c;overflow:auto;flex:none}
.vm{padding:10px 14px;border-bottom:1px solid #1e1e24;cursor:pointer}.vm:hover{background:#17171c}.vm.sel{background:#1d2130}
.vm .n{font-weight:600}.vm .s{font-size:12px;color:#9a9aa5}
#detail{flex:1;display:flex;flex-direction:column;overflow:auto;padding:16px}
button{background:#2a2a34;color:#e6e6e6;border:1px solid #3a3a46;border-radius:6px;padding:6px 12px;cursor:pointer;font-size:13px}
button:hover{background:#33333f}button:disabled{opacity:.4;cursor:default}
.row{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0;align-items:center}
select,input{background:#1a1a1f;color:#e6e6e6;border:1px solid #3a3a46;border-radius:6px;padding:6px}
pre{background:#000;border:1px solid #26262c;border-radius:6px;padding:10px;overflow:auto;flex:1;min-height:180px;white-space:pre-wrap;font:12px ui-monospace,monospace}
iframe{width:100%;height:520px;border:1px solid #26262c;border-radius:6px;background:#000}
.tabs{display:flex;gap:4px;margin-bottom:8px}.tabs button.on{background:#3a4668}
h2{margin:4px 0 2px}small{color:#9a9aa5}
</style></head><body>
<header><b>iphone-vm</b><span class="warn">experimental — the phone is software-emulated, so it's slow</span>
<span style="flex:1"></span><button onclick="newVM()">+ New VM</button><button onclick="install()">Set Up Inferno</button></header>
<main><div id="list"></div><div id="detail"><small>Select or create a VM.</small></div></main>
<script>
const $=s=>document.querySelector(s), api=(m,p,b)=>fetch(p+(location.search),{method:m,headers:{'Content-Type':'application/json'},body:b&&JSON.stringify(b)}).then(r=>r.json());
let sel=null, es=null, versions=[];
async function refresh(){const st=await api('GET','/api/state');const l=$('#list');l.innerHTML='';
 st.vms.forEach(v=>{const d=document.createElement('div');d.className='vm'+(v.id===sel?' sel':'');
  d.innerHTML=`<div class="n">${v.name}</div><div class="s">${v.device} · iOS ${v.ios} · ${v.state}</div>`;
  d.onclick=()=>{sel=v.id;show(v);refresh()};l.appendChild(d)});
 if(!st.installed)$('#detail').innerHTML='<h2>First, set up Inferno</h2><small>Builds the emulator and companion VM (20–60 min). Click “Set Up Inferno”.</small>';
 window._st=st;}
function show(v){const running=v.state==='running';
 $('#detail').innerHTML=`<h2>${v.name}</h2><small>${v.device} · iOS ${v.ios}${v.jailbroken?' · jailbroken':''}</small>
 <div class="tabs"><button class="on" onclick="tab(this,'sc')">Screen</button><button onclick="tab(this,'co')">Console</button>
  <button onclick="tab(this,'se')">Setup</button></div>
 <div class="row">${v.state==='ready'||running?`<button onclick="act('${v.id}','${running?'stop':'start'}')">${running?'Stop':'Start'}</button>`:`<button onclick="act('${v.id}','setup')">Set Up</button>`}
  ${running?"<button onclick=\"press('"+v.id+"','power')\">Power</button><button onclick=\"press('"+v.id+"','home')\">Home</button><button onclick=\"press('"+v.id+"','volup')\">Vol+</button><button onclick=\"press('"+v.id+"','voldown')\">Vol−</button><button onclick=\"act('"+v.id+"','trust')\">Trust (internet)</button>":""}
  <button onclick="delVM('${v.id}')">Delete</button></div>
 <div class="row"><label>Graphics <select id="gfx"><option value="default">Default Framebuffer</option><option value="smooth">Smooth Full-Res</option><option value="fast-half">Fast Half-Res</option></select></label>
  <label>Performance <select id="perf"><option value="balanced">Balanced</option><option value="fast">Fast TCG</option><option value="low-memory">Low Memory</option></select></label>
  <label>Audio <select id="audio"><option value="stable">Stable</option><option value="aop">AOP (Experimental)</option><option value="disabled">Disabled</option></select></label>
  <button onclick="saveSettings('${v.id}')">Apply on next start</button></div>
 <div id="sc" class="pane">${v.vncWebPort?`<iframe src="//${location.hostname}:${v.vncWebPort}/vnc.html?autoconnect=1&resize=scale"></iframe>`:'<small>Start the VM to see the screen (noVNC required on the server).</small>'}</div>
 <div id="co" class="pane" style="display:none"><pre id="serial">connecting…</pre><div class="row"><input id="cin" placeholder="type a command, Enter to send" style="flex:1" onkeydown="if(event.key==='Enter')sendCmd('${v.id}')"><button onclick="sendCmd('${v.id}')">Send</button></div></div>
 <div id="se" class="pane" style="display:none"><pre id="slog">no setup log yet</pre></div>`;
 $('#gfx').value=v.graphicsMode||'default';$('#perf').value=v.performanceMode||'balanced';$('#audio').value=v.audioMode||'stable';
 openSerial(v.id);}
function tab(b,id){document.querySelectorAll('.tabs button').forEach(x=>x.className='');b.className='on';
 document.querySelectorAll('.pane').forEach(p=>p.style.display='none');$('#'+id).style.display='';
 if(id==='se')api('GET',`/api/vms/${sel}/setup-log`).then(r=>{$('#slog').textContent=r.log||'no setup log yet';});}
function openSerial(id){if(es)es.close();es=new EventSource(`/api/vms/${id}/serial`+location.search);let buf='';
 es.onmessage=e=>{buf+=JSON.parse(e.data);if(buf.length>400000)buf=buf.slice(-200000);const p=$('#serial');if(p){p.textContent=buf;p.scrollTop=p.scrollHeight;}};}
function sendCmd(id){const i=$('#cin');api('PUT',`/api/vms/${id}/serial`,{data:i.value+"\n"});i.value='';}
async function act(id,a){await api('POST',`/api/vms/${id}/${a}`,{});setTimeout(refresh,600);
 if(a==='setup'){const t=setInterval(()=>api('GET',`/api/vms/${id}/setup-log`).then(r=>{const p=$('#slog');if(p){p.textContent=r.log;p.scrollTop=p.scrollHeight;}}),1500);setTimeout(()=>clearInterval(t),3600000);}}
async function saveSettings(id){const r=await api('PUT',`/api/vms/${id}/settings`,{graphicsMode:$('#gfx').value,performanceMode:$('#perf').value,audioMode:$('#audio').value});if(r.error)alert(r.error);else{alert('Saved. Restart the VM to apply the profile.');refresh();}}
function press(id,b){api('POST',`/api/vms/${id}/press`,{button:b});}
async function delVM(id){if(confirm('Delete this VM and its disks?')){await api('POST',`/api/vms/${id}/delete`,{});sel=null;$('#detail').innerHTML='';refresh();}}
async function newVM(){if(!versions.length)versions=await api('GET','/api/versions');
 const exp=confirm('Show experimental versions too? (Cancel = tested only)');
 const opts=versions.filter(v=>exp||v.status==='tested');
 const list=opts.map((v,i)=>`${i}: ${v.deviceName} iOS ${v.ios} (${v.status})`).join('\n');
 const pick=prompt('Pick a version:\n'+list);if(pick===null)return;const v=opts[+pick];if(!v)return;
 const jb=v.jailbreak&&v.jailbreak.bootstrap?confirm('Jailbroken?'):false;
 const r=await api('POST','/api/vms',{version:v.id,jailbreak:jb});if(r.error)alert(r.error);else{sel=r.id;refresh();}}
function install(){if(confirm('Build Inferno and the companion VM now? This takes 20–60 minutes.'))api('POST','/api/install',{});}
refresh();setInterval(refresh,4000);
</script></body></html>"""


def main():
    import sys
    host = os.environ.get("INFERNO_WEB_HOST", "127.0.0.1")
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = ThreadingHTTPServer((host, port), Handler)
    where = host if host != "0.0.0.0" else socket.gethostbyname(socket.gethostname())
    print(f"iphone-vm web UI: http://{where}:{port}/" + (f"?token={TOKEN}" if TOKEN else ""))
    if host == "0.0.0.0" and not TOKEN:
        print("WARNING: bound to all interfaces with no token — anyone on your network can control the VMs.")
    if not NOVNC_DIR:
        print("note: noVNC not found (apt install novnc websockify) — the phone screen won't show in the browser.")
    srv.serve_forever()


if __name__ == "__main__":
    main()
