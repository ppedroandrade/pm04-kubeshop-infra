"""Painel de administração do KubeShop.

Segurança:
- Login próprio (sem janela do navegador): senha verificada contra hash PBKDF2-SHA256
  (310 mil iterações), comparação em tempo constante.
- Sessão por cookie aleatório (256 bits) HttpOnly + Secure + SameSite=Strict, válido
  só em /admin, expira com 10 min sem uso ou 1 h no total, e termina ao sair ou ao
  voltar para a loja.
- Bloqueio de força bruta: 5 erros em 15 min por IP bloqueiam o login por 15 min.
- Ações só por POST com cabeçalho próprio e origem conferida (anti-CSRF).
- O contêiner não acessa o Docker: cada ação é um SSH com chave restrita que só
  executa o comando forçado `kubeshop-ops` nas VMs. Tudo vai para o log de auditoria.
"""
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs

HOSTS = {"app": os.environ["APP_HOST"], "db": os.environ["DB_HOST"]}
SSH_USER = os.environ.get("SSH_USER", "azureops")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
PUBLIC_HOST = os.environ.get("PUBLIC_HOST", "")
KEY = "/run/secrets/admin_ssh_key"
HASH_FILE = os.environ.get("HASH_FILE", "/run/secrets/admin_password_hash")
HERE = Path(__file__).parent
PANEL = (HERE / "index.html").read_bytes()
LOGIN = (HERE / "login.html").read_text(encoding="utf-8")

IDLE_TIMEOUT = 10 * 60
MAX_AGE = 60 * 60
MAX_FAILS, FAIL_WINDOW, LOCK_TIME = 5, 15 * 60, 15 * 60
COOKIE = "kubeshop_admin"

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

sessions = {}      # token -> {"user", "created", "seen"}
failures = {}      # ip -> [timestamps]
locked = {}        # ip -> unlock time
lock = threading.Lock()


def now():
    return time.time()


def audit(msg):
    print(f"[audit] {datetime.now(timezone.utc):%Y-%m-%dT%H:%M:%SZ} {msg}", flush=True)


def check_password(user, password):
    """Formato do hash: pbkdf2_sha256$<iteracoes>$<sal_b64>$<hash_b64>."""
    try:
        algo, rounds, salt, digest = Path(HASH_FILE).read_text().strip().split("$")
        calc = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.b64decode(salt), int(rounds))
        ok_pass = hmac.compare_digest(calc, base64.b64decode(digest))
    except Exception:
        ok_pass = False
    return hmac.compare_digest(user.encode(), ADMIN_USER.encode()) and ok_pass and algo == "pbkdf2_sha256"


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

    # ---------- utilitários ----------
    def ip(self):
        return (self.headers.get("X-Forwarded-For", "") or self.client_address[0]).split(",")[0].strip()

    def headers_common(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Content-Security-Policy",
                         "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
                         "form-action 'self'; frame-ancestors 'none'; base-uri 'none'")

    def send(self, code, body, ctype="application/json", cookie=None):
        data = body if isinstance(body, bytes) else (
            body.encode() if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode())
        self.send_response(code)
        self.send_header("Content-Type", f"{ctype}; charset=utf-8")
        if cookie is not None:
            self.send_header("Set-Cookie", cookie)
        self.headers_common()
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, to, cookie=None):
        self.send_response(303)
        self.send_header("Location", to)
        if cookie is not None:
            self.send_header("Set-Cookie", cookie)
        self.headers_common()
        self.end_headers()

    @staticmethod
    def make_cookie(token, clear=False):
        base = f"{COOKIE}={'' if clear else token}; Path=/admin; HttpOnly; Secure; SameSite=Strict"
        return base + ("; Max-Age=0" if clear else f"; Max-Age={MAX_AGE}")

    def session(self):
        raw = self.headers.get("Cookie", "")
        m = re.search(rf"(?:^|;\s*){COOKIE}=([A-Za-z0-9_\-]+)", raw)
        if not m:
            return None, None
        token = m.group(1)
        with lock:
            s = sessions.get(token)
            if not s:
                return None, None
            t = now()
            if t - s["seen"] > IDLE_TIMEOUT or t - s["created"] > MAX_AGE:
                sessions.pop(token, None)
                return None, None
            s["seen"] = t
            return token, s

    def login_page(self, error="", code=200):
        html = LOGIN.replace("{{ERROR}}", f'<div class="error">{error}</div>' if error else "")
        self.send(code, html, "text/html")

    def same_origin(self):
        origin = self.headers.get("Origin")
        return origin is None or not PUBLIC_HOST or origin == f"https://{PUBLIC_HOST}"

    # ---------- rotas ----------
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/admin/healthz":
            return self.send(200, {"ok": True})
        if path == "/admin/login":
            token, _ = self.session()
            return self.redirect("/admin/") if token else self.login_page()
        if path == "/admin/logout" or path == "/admin/sair":
            token, s = self.session()
            if token:
                with lock:
                    sessions.pop(token, None)
                audit(f"logout user={s['user']} ip={self.ip()}")
            dest = "/" if "loja" in self.path else "/admin/login"
            return self.redirect(dest, self.make_cookie("", clear=True))
        if path in ("/admin", "/admin/"):
            token, _ = self.session()
            return self.send(200, PANEL, "text/html") if token else self.redirect("/admin/login")
        self.send(404, {"error": "não encontrado"})

    def do_POST(self):
        path = self.path.split("?")[0]
        length = min(int(self.headers.get("Content-Length", 0) or 0), 64 * 1024)
        body = self.rfile.read(length) if length else b""
        if not self.same_origin():
            return self.send(403, {"error": "origem não permitida"})

        if path == "/admin/login":
            ip = self.ip()
            t = now()
            with lock:
                if locked.get(ip, 0) > t:
                    mins = int((locked[ip] - t) // 60) + 1
                    audit(f"login bloqueado ip={ip}")
                    return self.login_page(f"Muitas tentativas. Tente novamente em {mins} min.", 429)
            form = parse_qs(body.decode(errors="ignore"))
            user = (form.get("usuario") or [""])[0]
            password = (form.get("senha") or [""])[0]
            if check_password(user, password):
                token = secrets.token_urlsafe(32)
                with lock:
                    sessions[token] = {"user": user, "created": t, "seen": t}
                    failures.pop(ip, None)
                audit(f"login ok user={user} ip={ip}")
                return self.redirect("/admin/", self.make_cookie(token))
            with lock:
                hits = [x for x in failures.get(ip, []) if t - x < FAIL_WINDOW] + [t]
                failures[ip] = hits
                if len(hits) >= MAX_FAILS:
                    locked[ip] = t + LOCK_TIME
                    failures.pop(ip, None)
            audit(f"login falhou user={user[:40]!r} ip={ip} tentativas={len(hits)}")
            time.sleep(1)  # atrasa tentativas automáticas
            left = max(MAX_FAILS - len(hits), 0)
            msg = "Usuário ou senha inválidos." + (f" Restam {left} tentativa(s)." if left else " Login bloqueado por 15 min.")
            return self.login_page(msg, 401)

        if path == "/admin/api/run":
            token, s = self.session()
            if not token:
                return self.send(401, {"error": "Sessão expirada. Entre novamente.", "login": True})
            if self.headers.get("X-KubeShop-Admin") != "1":
                return self.send(403, {"error": "requisição recusada"})
            try:
                req = json.loads(body or b"{}")
                target, cmd, arg = req.get("target", ""), req.get("cmd", ""), (req.get("arg") or "").strip()
            except Exception:
                return self.send(400, {"error": "JSON inválido"})
            rule = ALLOWED.get((target, cmd), "missing")
            if rule == "missing" or (rule is None and arg) or (rule and not re.match(rule, arg)):
                return self.send(400, {"error": f"ação não permitida: {target} {cmd} {arg}"})
            if cmd == "restore" and req.get("confirm") != "RESTAURAR":
                return self.send(400, {"error": "Para restaurar digite RESTAURAR no campo de confirmação."})
            started = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            audit(f"acao user={s['user']} ip={self.ip()} {target}:{cmd} {arg}")
            try:
                code, out = run(target, cmd, arg)
            except subprocess.TimeoutExpired:
                code, out = 124, "Tempo esgotado (300 s)."
            return self.send(200, {"ok": code == 0, "code": code, "output": out, "at": started, "user": s["user"]})

        self.send(404, {"error": "não encontrado"})

    def log_message(self, fmt, *args):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
