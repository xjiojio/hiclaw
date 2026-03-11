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
from urllib.parse import urlparse, parse_qs
from datetime import datetime

# ============================================================
# Configuration
# ============================================================
WATCH_PORT = int(os.environ.get("HICLAW_WATCH_PORT", "19090"))
WATCH_USER = os.environ.get("HICLAW_WATCH_USER", "admin")
WATCH_PASSWORD = os.environ.get("HICLAW_WATCH_PASSWORD", "")
WATCH_INTERVAL = int(os.environ.get("HICLAW_WATCH_INTERVAL_SECONDS", "10"))
STATE_FILE = "/data/manager-watch/state.json"

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
    "last_updated": 0
}
STATE_LOCK = threading.Lock()

# ============================================================
# Core Logic: Service Discovery & Status (Mock for Skeleton)
# ============================================================

def get_service_status():
    """
    Returns a dict of all services and their current status.
    Status schema: {
        "name": str,
        "kind": "supervisor" | "worker",
        "status": "UP" | "DOWN" | "DEGRADED",
        "details": str,
        "last_check": timestamp
    }
    """
    # Placeholder: Real implementation will be added in Milestone 2
    return {
        "minio": {"name": "minio", "kind": "supervisor", "status": "UP", "details": "pid 123, uptime 5m"},
        "tuwunel": {"name": "tuwunel", "kind": "supervisor", "status": "UP", "details": "pid 124, uptime 5m"},
    }

def perform_restart(kind, name):
    """
    Executes restart action.
    """
    logger.info(f"Action: Restarting {kind} {name}")
    # Placeholder: Real implementation will be added in Milestone 3
    if kind == "supervisor":
        return True, "Mock restart supervisor success"
    elif kind == "worker":
        return True, "Mock restart worker success"
    return False, f"Unknown kind {kind}"

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
                body {{ font-family: sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }}
                h1 {{ border-bottom: 2px solid #eee; padding-bottom: 0.5rem; }}
                .status-UP {{ color: green; font-weight: bold; }}
                .status-DOWN {{ color: red; font-weight: bold; }}
                table {{ width: 100%; border-collapse: collapse; margin-top: 1rem; }}
                th, td {{ text-align: left; padding: 0.75rem; border-bottom: 1px solid #eee; }}
                button {{ cursor: pointer; padding: 0.25rem 0.5rem; }}
            </style>
        </head>
        <body>
            <h1>HiClaw Manager Watch</h1>
            <p>Last updated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}</p>
            
            <div id="status-container">Loading...</div>

            <script>
                function loadStatus() {{
                    fetch('/api/status')
                        .then(r => r.json())
                        .then(data => {{
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
                    }})
                    .catch(err => alert('Error: ' + err));
                }}

                loadStatus();
                setInterval(loadStatus, 5000);
            </script>
        </body>
        </html>
        """
        self.wfile.write(html.encode("utf-8"))

    def handle_api_status(self):
        self.send_response(200)
        self.send_header("Content-type", "application/json")
        self.end_headers()
        
        status = get_service_status()
        self.wfile.write(json.dumps(status).encode("utf-8"))

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

def probe_loop():
    """Background thread to probe services periodically."""
    logger.info("Starting probe loop...")
    while True:
        # Placeholder: Real probing logic in Milestone 2
        # status = probe_all_services()
        # update_global_state(status)
        time.sleep(WATCH_INTERVAL)

def main():
    # Ensure data directory
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    
    # Start background probe thread
    t = threading.Thread(target=probe_loop, daemon=True)
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
