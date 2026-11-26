"""Teste E2E da loja publicada (ACE-04/ACE-05).

Abre a loja num navegador real (Chromium headless, fora do Azure), adiciona um
produto, confirma um pedido fictício, recarrega a página e confere o pedido em
"Meus pedidos". Opcionalmente confere se um pedido anterior (VERIFY_ORDER)
continua existindo (persistência após reinício/alteração de infraestrutura).

Variáveis: STORE_URL, VERIFY_ORDER (ex.: a1b2c3), OUT_DIR, CREATE_ORDER (true/false)
"""
import json
import os
import re
import sys
import urllib.request

from playwright.sync_api import expect, sync_playwright

url = os.environ["STORE_URL"].rstrip("/") + "/"
out = os.environ.get("OUT_DIR", "e2e-evidencias")
verify = os.environ.get("VERIFY_ORDER", "").strip().lstrip("#")
create = os.environ.get("CREATE_ORDER", "true").lower() == "true"
os.makedirs(out, exist_ok=True)
summary = []


def shot(page, name):
    path = f"{out}/{name}.png"
    page.screenshot(path=path, full_page=False)
    print(f"evidência: {path}")


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1366, "height": 900}, locale="pt-BR")

    # 1 · Acesso à loja e catálogo
    page.goto(url, wait_until="networkidle")
    expect(page.get_by_text("Loja disponível")).to_be_visible(timeout=30000)
    expect(page.get_by_role("button", name="Adicionar Headphone Orbit")).to_be_visible()
    shot(page, "01-loja-catalogo")
    summary.append(f"Loja aberta em {url} e catálogo carregado")

    created = None
    if create:
        # 2 · Sacola e confirmação do pedido fictício
        page.get_by_role("button", name="Adicionar Headphone Orbit").click()
        page.get_by_role("button", name=re.compile("Confirmar pedido fictício")).click()
        status = page.get_by_role("status").filter(has_text="confirmado e salvo")
        expect(status).to_be_visible(timeout=20000)
        created = re.search(r"#([0-9a-f]{6})", status.inner_text()).group(1)
        status.scroll_into_view_if_needed()
        page.mouse.wheel(0, -200)
        shot(page, "02-pedido-confirmado")
        summary.append(f"Pedido fictício #{created} criado (POST /api/orders = 201)")

    # 3 · Recarregar o navegador e consultar o histórico
    page.reload(wait_until="networkidle")
    page.get_by_role("button", name="Meus pedidos").click()
    expect(page.get_by_role("heading", name="Meus pedidos")).to_be_visible()
    for order in [o for o in (created, verify) if o]:
        found = page.get_by_text(f"Pedido #{order}")
        expect(found).to_be_visible(timeout=20000)
        found.scroll_into_view_if_needed()
        summary.append(f"Pedido #{order} encontrado em 'Meus pedidos' após recarregar")
    shot(page, "03-meus-pedidos-apos-recarregar")
    browser.close()

with urllib.request.urlopen(url + "api/orders", timeout=20) as r:
    total = len(json.load(r)["orders"])
with urllib.request.urlopen(url + "api/health/ready", timeout=20) as r:
    ready = r.read().decode()
summary.append(f"GET /api/orders: {total} pedido(s) no MongoDB · /api/health/ready: {ready}")

print("\n".join(summary))
with open(os.environ.get("GITHUB_STEP_SUMMARY", os.devnull), "a") as f:
    f.write("### Teste E2E no navegador\n" + "\n".join(f"- {s}" for s in summary) + "\n")
if created and os.environ.get("GITHUB_OUTPUT"):
    with open(os.environ["GITHUB_OUTPUT"], "a") as f:
        f.write(f"order={created}\n")
sys.exit(0)
