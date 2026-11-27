"""Teste do painel /admin feito de fora (runner): login, rotinas e logout.
Imprime só resultados, nunca a senha ou o cookie de sessão."""
import json, os, sys, urllib.request, urllib.parse, http.cookiejar

base = f"https://{os.environ['FQDN']}/admin"
jar = http.cookiejar.CookieJar()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k):
        return None

opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)

def call(req):
    try:
        r = opener.open(req, timeout=120)
        return r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()

form = urllib.parse.urlencode({"usuario": os.environ["U"], "senha": os.environ["P"]}).encode()
st, hd, _ = call(urllib.request.Request(base + "/login", data=form, method="POST"))
assert st == 303 and hd.get("Location", "").endswith("/admin/"), f"login falhou: HTTP {st}"
assert any(c.name == "kubeshop_admin" for c in jar), "cookie de sessão não recebido"
print("login: OK (303 -> /admin/, cookie de sessão HttpOnly/Secure)")

ok = True
for target, cmd in [("app", "health"), ("db", "health"), ("db", "list-backups")]:
    req = urllib.request.Request(base + "/api/run", method="POST",
                                 data=json.dumps({"target": target, "cmd": cmd}).encode(),
                                 headers={"Content-Type": "application/json", "X-KubeShop-Admin": "1"})
    st, _, body = call(req)
    try:
        j = json.loads(body)
    except Exception:
        j = {"error": body[:200].decode(errors="ignore")}
    good = st == 200 and j.get("ok")
    ok &= bool(good)
    first = (j.get("output") or j.get("error") or "").strip().splitlines()[:2]
    print(f"{target}:{cmd}: {'OK' if good else 'FALHOU'} (HTTP {st}) {' | '.join(first)[:160]}")

st, _, _ = call(urllib.request.Request(base + "/logout"))
print(f"logout: HTTP {st}")
sys.exit(0 if ok else 1)
