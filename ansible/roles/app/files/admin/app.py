"""Painel de administração do KubeShop.

Atrás do Caddy (HTTPS + basic auth). Não tem acesso ao Docker nem shell nas VMs:
cada ação vira um SSH com chave própria que só executa o comando forçado
`kubeshop-ops` (lista fechada de rotinas). Tudo é registrado no log do contêiner.
"""
import json
import os
import re
import subprocess
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOSTS = {"app": os.environ["APP_HOST"], "db": os.environ["DB_HOST"]}
SSH_USER = os.environ.get("SSH_USER", "azureops")
KEY = "/run/secrets/admin_ssh_key"
INDEX = Path(__file__).with_name("index.html").read_bytes()

ALLOWED = {
    ("app", "health"): None,
    ("app", "logs"): r"^(frontend|api|caddy)$",
    ("app", "restart"): r"^(frontend|api)$",
    ("db", "health"): None,
    ("db", "logs"): r"^mongodb$",
    ("db", "restart"): r"^mongodb$",
    ("db", "backup"): None,
    ("db", "list-backups"): None,
    ("db", "restore"): r"^(latest|kubeshop-[a-z]+-[0-9]{8}T[0-9]{6}Z\.archive\.gz)$",
}


def run(target, cmd, arg):
    remote = f"{cmd} {arg}".strip()
    proc = subprocess.run(
        ["ssh", "-i", KEY, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
         "-o", "StrictHostKeyChecking=accept-new", "-o", "UserKnownHostsFile=/tmp/known_hosts",
         f"{SSH_USER}@{HOSTS[target]}", remote],
        capture_output=True, text=True, timeout=300,
    )
    return proc.returncode, (proc.stdout + proc.stderr).strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "kubeshop-admin"

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Security-Policy", "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/admin", "/admin/"):
            return self._send(200, INDEX, "text/html")
        if self.path == "/admin/healthz":
            return self._send(200, {"ok": True})
        self._send(404, {"error": "não encontrado"})

    def do_POST(self):
        if self.path != "/admin/api/run" or self.headers.get("X-KubeShop-Admin") != "1":
            return self._send(403, {"error": "requisição recusada"})
        try:
            req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)) or 0))
            target, cmd, arg = req.get("target", ""), req.get("cmd", ""), (req.get("arg") or "").strip()
        except Exception:
            return self._send(400, {"error": "JSON inválido"})
        rule = ALLOWED.get((target, cmd), "missing")
        if rule == "missing" or (rule is None and arg) or (rule and not re.match(rule, arg)):
            return self._send(400, {"error": f"ação não permitida: {target} {cmd} {arg}"})
        if cmd == "restore" and req.get("confirm") != "RESTAURAR":
            return self._send(400, {"error": "Para restaurar digite RESTAURAR no campo de confirmação."})
        user = self.headers.get("X-Admin-User", "admin")
        started = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        print(f"[audit] {started} user={user} ip={self.headers.get('X-Forwarded-For', '-')} action={target}:{cmd} {arg}", flush=True)
        try:
            code, out = run(target, cmd, arg)
        except subprocess.TimeoutExpired:
            code, out = 124, "Tempo esgotado (300 s)."
        self._send(200, {"ok": code == 0, "code": code, "output": out, "at": started})

    def log_message(self, fmt, *args):  # acessos já ficam no log do Caddy
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
