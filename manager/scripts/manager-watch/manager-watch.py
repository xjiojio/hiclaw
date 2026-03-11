#!/usr/bin/env python3
# manager-watch.py
#
# A lightweight watchdog and ops dashboard for HiClaw Manager.
# - Monitors: Higress, Tuwunel, Element, MinIO, Manager, Workers
# - Actions: Restart services (supervisorctl) and workers (container-api)
# - Alerts: Matrix messaging
# - Security: Basic Auth (default), designed to run behind Higress

import os
import sys
import json
import time
import base64
import logging
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler
import urllib.request
import urllib.error
from urllib.parse import urlparse, parse_qs
from datetime import datetime

# ============================================================
# Configuration
# ============================================================
WATCH_PORT = int(os.environ.get("HICLAW_WATCH_PORT", "19090"))
WATCH_USER = os.environ.get("HICLAW_WATCH_USER", "admin")
WATCH_PASSWORD = os.environ.get("HICLAW_WATCH_PASSWORD", "")
WATCH_INTERVAL = int(os.environ.get("HICLAW_WATCH_INTERVAL_SECONDS", "10"))
WATCH_FAIL_THRESHOLD = int(os.environ.get("HICLAW_WATCH_FAIL_THRESHOLD", "3"))
WATCH_RESTART_COOLDOWN = int(os.environ.get("HICLAW_WATCH_RESTART_COOLDOWN_SECONDS", "60"))
STATE_FILE = "/data/manager-watch/state.json"
AUDIT_FILE = "/data/manager-watch/audit.log"
CONTAINER_SOCKET = os.environ.get("HICLAW_CONTAINER_SOCKET", "/var/run/docker.sock")
WORKER_PREFIX = "hiclaw-worker-"

# Fallback password from HICLAW_ADMIN_PASSWORD if not set
if not WATCH_PASSWORD:
    WATCH_PASSWORD = os.environ.get("HICLAW_ADMIN_PASSWORD", "admin")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("manager-watch")

# Global state
SERVICE_STATE = {
    "services": {},
    "last_updated": 0,
    "matrix_room_id": None,
    "matrix_token": None
}
STATE_LOCK = threading.Lock()
RESTART_TRACKER = {}

def log_audit(action, target, status, details=""):
    try:
        entry = {
            "timestamp": datetime.now().isoformat(),
            "action": action,
            "target": target,
            "status": status,
            "details": details
        }
        with open(AUDIT_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except Exception as e:
        logger.error(f"Audit log error: {e}")

# ============================================================
# Matrix Client
# ============================================================

class MatrixClient:
    def __init__(self):
        self.base_url = "http://127.0.0.1:6167" # Tuwunel local port
        self.token = None
        self.room_id = None
        self.user_id = None

    def _request(self, method, path, body=None):
        url = f"{self.base_url}{path}"
        headers = {"Content-Type": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
            
        try:
            data = json.dumps(body).encode("utf-8") if body else None
            req = urllib.request.Request(url, data=data, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=5) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            logger.error(f"Matrix API error {method} {path}: {e.code} {e.reason}")
            # Try to read error body
            try:
                err_body = e.read().decode('utf-8')
                logger.error(f"Body: {err_body}")
            except:
                pass
            return None
        except Exception as e:
            logger.error(f"Matrix connection error: {e}")
            return None

    def login(self):
        # Try to login with admin credentials
        admin_user = os.environ.get("HICLAW_ADMIN_USER", "admin")
        admin_pass = os.environ.get("HICLAW_ADMIN_PASSWORD", "admin")
        
        body = {
            "type": "m.login.password",
            "identifier": {"type": "m.id.user", "user": admin_user},
            "password": admin_pass
        }
        
        resp = self._request("POST", "/_matrix/client/v3/login", body)
        if resp and "access_token" in resp:
            self.token = resp["access_token"]
            self.user_id = resp["user_id"]
            logger.info(f"Matrix login successful as {self.user_id}")
            return True
        return False
    
    def ensure_login(self):
        if self.token:
            return True
        return self.login()

    def join_or_create_room(self, room_name="manager-watch"):
        if not self.ensure_login():
            return None
            
        # 1. List joined rooms to see if we are already in it
        # This is hard because we don't know the ID.
        # But we can try to resolve alias if we set one, or just create/join.
        # Conduwuit might not support full directory search.
        # Simplest: Try to create with alias. If exists (409), join it.
        
        # Local alias: #manager-watch:server_name
        # We need server_name. 
        # But simpler: just create a private room with name "manager-watch" if we don't have the ID stored.
        # Milestone 4 says: "search joined rooms... if not found create".
        
        # Let's try to list joined rooms
        joined = self._request("GET", "/_matrix/client/v3/joined_rooms")
        # We can't get names easily without querying each room state.
        
        # Alternative: persist room_id in state file.
        if SERVICE_STATE.get("matrix_room_id"):
            self.room_id = SERVICE_STATE["matrix_room_id"]
            return self.room_id

        # Create room
        body = {
            "name": room_name,
            "visibility": "private",
            "preset": "private_chat",
            "topic": "HiClaw Manager Watch Alerts"
        }
        
        resp = self._request("POST", "/_matrix/client/v3/createRoom", body)
        if resp and "room_id" in resp:
            self.room_id = resp["room_id"]
            logger.info(f"Created Matrix room: {self.room_id}")
            return self.room_id
            
        return None

    def send_alert(self, message):
        # Try to login/setup room if needed (lazy init)
        if not self.token:
            if self.login():
                 if not self.room_id:
                     self.join_or_create_room()
        
        if not self.token or not self.room_id:
            return False
            
        txn_id = int(time.time() * 1000)
        body = {
            "msgtype": "m.text",
            "body": message,
            "format": "org.matrix.custom.html",
            "formatted_body": message.replace("\n", "<br>")
        }
        
        path = f"/_matrix/client/v3/rooms/{self.room_id}/send/m.room.message/{txn_id}"
        self._request("PUT", path, body)
        return True

# ============================================================
# Core Logic: Service Discovery & Status
# ============================================================

def docker_api(method, path, body=None):
    """
    Execute Docker API call via curl over unix socket.
    """
    cmd = ["curl", "-s", "--unix-socket", CONTAINER_SOCKET, "-X", method]
    if body:
        cmd.extend(["-H", "Content-Type: application/json", "-d", json.dumps(body)])
    cmd.append(f"http://localhost{path}")
    
    try:
        # 5 second timeout for docker operations
        result = subprocess.check_output(cmd, timeout=5, encoding="utf-8")
        if not result:
            return None
        return json.loads(result)
    except Exception as e:
        logger.error(f"Docker API error ({method} {path}): {e}")
        return None

def get_supervisor_status():
    """
    Parse 'supervisorctl status' output.
    """
    status_map = {}
    try:
        output = subprocess.check_output(["supervisorctl", "status"], encoding="utf-8")
        for line in output.splitlines():
            parts = line.split()
            if len(parts) >= 2:
                name = parts[0]
                state = parts[1]
                # Map supervisor states to our UP/DOWN
                if state == "RUNNING":
                    status_map[name] = {"status": "UP", "details": line}
                else:
                    status_map[name] = {"status": "DOWN", "details": line}
    except Exception as e:
        logger.error(f"Supervisor status error: {e}")
    return status_map

def get_http_status():
    """
    Check key HTTP endpoints.
    """
    targets = {
        "tuwunel-api": "http://127.0.0.1:6167/_matrix/client/versions",
        "minio-api": "http://127.0.0.1:9000/minio/health/ready",
        "element-web": "http://127.0.0.1:8088/"
    }
    
    results = {}
    for name, url in targets.items():
        try:
            # 2 second timeout for HTTP checks
            with urllib.request.urlopen(url, timeout=2) as response:
                if response.status >= 200 and response.status < 400:
                    results[name] = {"status": "UP", "details": f"HTTP {response.status}"}
                else:
                    results[name] = {"status": "DOWN", "details": f"HTTP {response.status}"}
        except Exception as e:
            results[name] = {"status": "DOWN", "details": str(e)}
    return results

def get_worker_status():
    """
    List worker containers via Docker API.
    """
    workers = {}
    if not os.path.exists(CONTAINER_SOCKET):
        return workers

    try:
        # List all containers filtering by name
        # URL encoded filter: {"name": ["hiclaw-worker-"]}
        path = f"/containers/json?all=true&filters=%7B%22name%22%3A%5B%22{WORKER_PREFIX}%22%5D%7D"
        containers = docker_api("GET", path)
        
        if containers:
            for c in containers:
                # Name is like /hiclaw-worker-alice -> alice
                raw_name = c["Names"][0]
                name = raw_name.lstrip("/")
                short_name = name.replace(WORKER_PREFIX, "")
                
                state = c["State"] # running, exited, created
                status = "UP" if state == "running" else "DOWN"
                
                workers[f"worker:{short_name}"] = {
                    "name": name, 
                    "kind": "worker", 
                    "status": status, 
                    "details": f"{state} ({c['Status']})"
                }
    except Exception as e:
        logger.error(f"Worker status error: {e}")
    return workers

def get_service_status():
    """
    Returns a dict of all services and their current status.
    """
    services = {}
    
    # 1. Supervisor
    sup_status = get_supervisor_status()
    for name, info in sup_status.items():
        services[name] = {
            "name": name,
            "kind": "supervisor",
            "status": info["status"],
            "details": info["details"],
            "last_check": time.time()
        }

    # 2. HTTP
    http_res = get_http_status()
    for name, info in http_res.items():
        services[name] = {
            "name": name,
            "kind": "http",
            "status": info["status"],
            "details": info["details"],
            "last_check": time.time()
        }
            
    # 3. Workers
    worker_res = get_worker_status()
    services.update(worker_res)
    
    return services

def perform_restart(kind, name):
    """
    Executes restart action.
    """
    logger.info(f"Action: Restarting {kind} {name}")
    
    # Cooldown check
    now = time.time()
    last_restart = RESTART_TRACKER.get(name, 0)
    if now - last_restart < WATCH_RESTART_COOLDOWN:
        msg = f"Restart cooldown active for {name} ({int(WATCH_RESTART_COOLDOWN - (now - last_restart))}s remaining)"
        log_audit("restart", name, "blocked", msg)
        return False, msg

    success = False
    msg = ""

    if kind == "supervisor":
        try:
            # Use supervisorctl to restart
            # Validate name to prevent injection (simple alphanumeric check)
            if not name.replace("-", "").isalnum():
                 msg = "Invalid service name"
                 log_audit("restart", name, "failed", msg)
                 return False, msg
                 
            subprocess.check_call(["supervisorctl", "restart", name])
            success = True
            msg = f"Restarted supervisor service {name}"
        except subprocess.CalledProcessError as e:
            msg = f"Failed to restart {name}: {e}"
            success = False
            
    elif kind == "worker":
        # Check if it's a valid worker name (matches prefix logic)
        # We need the full container name
        container_name = name if name.startswith(WORKER_PREFIX) else f"{WORKER_PREFIX}{name}"
        
        # Stop then Start
        try:
            # Stop
            docker_api("POST", f"/containers/{container_name}/stop?t=5")
            # Start
            docker_api("POST", f"/containers/{container_name}/start")
            success = True
            msg = f"Restarted worker container {container_name}"
        except Exception as e:
             msg = f"Failed to restart worker {container_name}: {e}"
             success = False
             
    else:
        msg = f"Unknown kind {kind}"
        success = False

    if success:
        RESTART_TRACKER[name] = now
        log_audit("restart", name, "success", msg)
    else:
        log_audit("restart", name, "failed", msg)
    
    return success, msg

# ============================================================
# HTTP Handler
# ============================================================

class WatchHandler(BaseHTTPRequestHandler):
    def do_AUTH_HEAD(self):
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="HiClaw Manager Watch"')
        self.send_header("Content-type", "text/html")
        self.end_headers()

    def check_auth(self):
        auth_header = self.headers.get("Authorization")
        if not auth_header:
            self.do_AUTH_HEAD()
            self.wfile.write(b"Authentication required")
            return False
        
        try:
            auth_type, encoded = auth_header.split(None, 1)
            if auth_type.lower() != "basic":
                raise ValueError("Not Basic auth")
            decoded = base64.b64decode(encoded).decode("utf-8")
            username, password = decoded.split(":", 1)
            
            if username == WATCH_USER and password == WATCH_PASSWORD:
                return True
        except Exception:
            pass
            
        self.do_AUTH_HEAD()
        self.wfile.write(b"Authentication failed")
        return False

    def do_GET(self):
        if not self.check_auth():
            return

        parsed = urlparse(self.path)
        
        if parsed.path == "/":
            self.handle_index()
        elif parsed.path == "/api/status":
            self.handle_api_status()
        elif parsed.path == "/api/audit":
            self.handle_api_audit()
        else:
            self.send_error(404, "Not Found")

    def do_POST(self):
        if not self.check_auth():
            return

        parsed = urlparse(self.path)
        
        if parsed.path == "/api/restart":
            self.handle_api_restart()
        else:
            self.send_error(404, "Not Found")

    def handle_index(self):
        self.send_response(200)
        self.send_header("Content-type", "text/html; charset=utf-8")
        self.end_headers()
        
        # Simple HTML Dashboard
        html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>HiClaw Manager Watch</title>
            <style>
                body {{ font-family: sans-serif; max-width: 900px; margin: 2rem auto; padding: 0 1rem; }}
                h1 {{ border-bottom: 2px solid #eee; padding-bottom: 0.5rem; }}
                h2 {{ margin-top: 2rem; border-bottom: 1px solid #eee; padding-bottom: 0.25rem; font-size: 1.2rem; }}
                .status-UP {{ color: green; font-weight: bold; }}
                .status-DOWN {{ color: red; font-weight: bold; }}
                table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
                th, td {{ text-align: left; padding: 0.75rem; border-bottom: 1px solid #eee; }}
                button {{ cursor: pointer; padding: 0.25rem 0.5rem; }}
                #audit-container {{ max-height: 300px; overflow-y: auto; background: #f9f9f9; padding: 0.5rem; border: 1px solid #ddd; }}
                .audit-entry {{ padding: 0.25rem 0; border-bottom: 1px solid #eee; font-size: 0.9rem; }}
                .audit-time {{ color: #666; margin-right: 0.5rem; font-family: monospace; }}
                .audit-success {{ color: green; }}
                .audit-failed {{ color: red; }}
                .audit-blocked {{ color: orange; }}
            </style>
        </head>
        <body>
            <h1>HiClaw Manager Watch</h1>
            <p>Last updated: <span id="last-updated">...</span></p>
            
            <div id="status-container">Loading...</div>

            <h2>Audit Log (Last 50 actions)</h2>
            <div id="audit-container">Loading audit log...</div>

            <script>
                function loadStatus() {{
                    fetch('/api/status')
                        .then(r => r.json())
                        .then(data => {{
                            document.getElementById('last-updated').innerText = new Date().toLocaleString();
                            let html = '<table><thead><tr><th>Service</th><th>Type</th><th>Status</th><th>Details</th><th>Action</th></tr></thead><tbody>';
                            
                            // Sort services by name
                            const sortedKeys = Object.keys(data).sort();
                            
                            for (const key of sortedKeys) {{
                                const s = data[key];
                                html += `<tr>
                                    <td>${{s.name}}</td>
                                    <td>${{s.kind}}</td>
                                    <td class="status-${{s.status}}">${{s.status}}</td>
                                    <td>${{s.details}}</td>
                                    <td><button onclick="restartService('${{s.kind}}', '${{s.name}}')">Restart</button></td>
                                </tr>`;
                            }}
                            html += '</tbody></table>';
                            document.getElementById('status-container').innerHTML = html;
                        }});
                }}

                function loadAudit() {{
                    fetch('/api/audit')
                        .then(r => r.json())
                        .then(data => {{
                            let html = '';
                            if (data.length === 0) {{
                                html = '<div class="audit-entry">No audit logs found.</div>';
                            }} else {{
                                for (const entry of data) {{
                                    // entry: {timestamp, action, target, status, details}
                                    const statusClass = 'audit-' + entry.status;
                                    html += `<div class="audit-entry">
                                        <span class="audit-time">${{entry.timestamp.replace('T', ' ').split('.')[0]}}</span>
                                        <strong class="${{statusClass}}">${{entry.action.toUpperCase()}}</strong> 
                                        ${{entry.target}} - ${{entry.details}}
                                    </div>`;
                                }}
                            }}
                            document.getElementById('audit-container').innerHTML = html;
                        }});
                }}

                function restartService(kind, name) {{
                    if (!confirm(`Are you sure you want to restart ${{name}}?`)) return;
                    
                    fetch('/api/restart', {{
                        method: 'POST',
                        headers: {{ 'Content-Type': 'application/json' }},
                        body: JSON.stringify({{ kind, name }})
                    }})
                    .then(r => r.json())
                    .then(res => {{
                        alert(res.message);
                        loadStatus();
                        loadAudit();
                    }})
                    .catch(err => alert('Error: ' + err));
                }}

                loadStatus();
                loadAudit();
                setInterval(loadStatus, 5000);
                setInterval(loadAudit, 15000);
            </script>
        </body>
        </html>
        """
        self.wfile.write(html.encode("utf-8"))

    def handle_api_status(self):
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        
        with STATE_LOCK:
            # Return cached state if available, else fetch fresh
            if not SERVICE_STATE["services"]:
                status = get_service_status()
            else:
                status = SERVICE_STATE["services"]
                
        self.wfile.write(json.dumps(status).encode("utf-8"))
    
    def handle_api_audit(self):
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        
        logs = []
        if os.path.exists(AUDIT_FILE):
            try:
                # Read last 50 lines efficiently? Simple readlines for now
                with open(AUDIT_FILE, "r") as f:
                    lines = f.readlines()
                    # Parse JSON lines in reverse order
                    for line in reversed(lines[-50:]):
                        try:
                            logs.append(json.loads(line))
                        except:
                            pass
            except Exception:
                pass
        
        self.wfile.write(json.dumps(logs).encode("utf-8"))

    def handle_api_restart(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8")
        
        try:
            data = json.loads(body)
            kind = data.get("kind")
            name = data.get("name")
            
            if not kind or not name:
                raise ValueError("Missing kind or name")
                
            success, msg = perform_restart(kind, name)
            
            # Force immediate update after action
            if success:
                new_status = get_service_status()
                with STATE_LOCK:
                    SERVICE_STATE["services"] = new_status
                    SERVICE_STATE["last_updated"] = time.time()
            
            self.send_response(200 if success else 500)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": success, "message": msg}).encode("utf-8"))
            
        except Exception as e:
            self.send_response(400)
            self.send_header("Content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": False, "message": str(e)}).encode("utf-8"))

# ============================================================
# Main Loop
# ============================================================

def probe_loop(matrix_client):
    """Background thread to probe services periodically."""
    logger.info("Starting probe loop...")
    
    previous_services = {}
    service_failures = {} # name -> count

    with STATE_LOCK:
        if SERVICE_STATE.get("services"):
             previous_services = SERVICE_STATE["services"].copy()

    while True:
        try:
            current_services = get_service_status()
            
            # Apply threshold logic and compare
            for name, curr in current_services.items():
                # Update failure count
                if curr["status"] != "UP":
                    service_failures[name] = service_failures.get(name, 0) + 1
                else:
                    service_failures[name] = 0
                
                prev = previous_services.get(name)
                
                # If currently DOWN but below threshold, mask as UP (unless it was already DOWN)
                if curr["status"] != "UP":
                    if service_failures[name] < WATCH_FAIL_THRESHOLD:
                        # Only mask if it was previously UP (or unknown/new)
                        # If it was already DOWN, keep it DOWN.
                        if not prev or prev["status"] == "UP":
                            logger.info(f"Masking failure for {name} ({service_failures[name]}/{WATCH_FAIL_THRESHOLD})")
                            curr["status"] = "UP"
                            curr["details"] += f" (Transient failure {service_failures[name]})"
                
                # Alert: UP -> DOWN
                if prev and prev["status"] == "UP" and curr["status"] != "UP":
                    msg = f"🚨 <b>[manager-watch] {name} DOWN</b><br>Reason: {curr['details']}<br>Time: {datetime.now().strftime('%H:%M:%S')}"
                    matrix_client.send_alert(msg)
                    logger.info(f"Alert sent for {name}")
                
                # Recovery: DOWN -> UP
                if prev and prev["status"] != "UP" and curr["status"] == "UP":
                    msg = f"✅ <b>[manager-watch] {name} RECOVERED</b><br>Time: {datetime.now().strftime('%H:%M:%S')}"
                    matrix_client.send_alert(msg)
                    logger.info(f"Recovery sent for {name}")

            previous_services = current_services
            
            with STATE_LOCK:
                SERVICE_STATE["services"] = current_services
                SERVICE_STATE["last_updated"] = time.time()
                
            # Persist state
            with open(STATE_FILE, "w") as f:
                # Avoid persisting sensitive token if possible, but we need room_id
                json.dump(SERVICE_STATE, f)
                
        except Exception as e:
            logger.error(f"Probe loop error: {e}")
            
        time.sleep(WATCH_INTERVAL)

def main():
    # Ensure data directory
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    
    # Load state from file if exists
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r") as f:
                saved_state = json.load(f)
                SERVICE_STATE.update(saved_state)
        except Exception as e:
            logger.warning(f"Failed to load state file: {e}")

    # Init Matrix
    matrix_client = MatrixClient()
    # Try to use stored token if available? No, safer to login again to get fresh token
    # unless we want to persist session.
    # Requirements say: "Start time use Manager account login... pull room_id from file"
    
    try:
        if matrix_client.login():
            room_id = matrix_client.join_or_create_room()
            if room_id:
                with STATE_LOCK:
                    SERVICE_STATE["matrix_room_id"] = room_id
    except Exception as e:
        logger.error(f"Matrix initialization failed: {e}")
    
    # Start background probe thread
    t = threading.Thread(target=probe_loop, args=(matrix_client,), daemon=True)
    t.start()
    
    # Start HTTP server
    server_address = ("0.0.0.0", WATCH_PORT)
    httpd = HTTPServer(server_address, WatchHandler)
    logger.info(f"Manager Watch listening on port {WATCH_PORT}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    logger.info("Stopping Manager Watch")

if __name__ == "__main__":
    main()
