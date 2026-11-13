#!/usr/bin/env python3
"""Pruebas del gestor web de nexo-tools (/ui) en un Chromium sin pantalla.

Uso:   python3 tests/ui_tests.py [--shots CARPETA]

Levanta un nexo-tools de verdad (con su propio HOME, en 127.0.0.1, con escritura), abre su dirección
«https://…/ui#t=…» en Chromium (Playwright) y lo maneja como lo haría una persona: entrar con el
acceso del fragmento, mirar carpetas, filtrar por extensión, ver imágenes y textos, comprobar que un HTML
con <script> se ve como TEXTO y no se ejecuta, crear carpeta, subir, renombrar, borrar (a la papelera) y salir.
Al terminar lo para y borra todo. Con --shots guarda capturas de pantalla (escritorio y móvil) en esa carpeta.

Necesita: python3, bash, openssl y Playwright con su Chromium (pip install playwright; playwright install chromium).
No forma parte de tests/run_tests.sh porque no todo el mundo tiene un navegador. Sale con:
  0  todo bien
  1  algo falló
  77 no se pudo correr (falta Playwright o Chromium): no cuenta como fallo
Esto prueba la página con un Chromium de escritorio; no se ha probado en los navegadores de Android.
"""
import argparse
import base64
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.environ.get("NEXO_TOOLS_BIN") or os.path.join(ROOT, "termux", "bin", "nexo-tools")   # (NEXO_TOOLS_BIN: probar otra copia)
PNG_1X1 = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def free_port(kind=socket.SOCK_STREAM):
    s = socket.socket(socket.AF_INET, kind)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def main():
    ap = argparse.ArgumentParser(description="Pruebas del gestor web de nexo-tools en un Chromium sin pantalla")
    ap.add_argument("--shots", help="carpeta donde guardar capturas de pantalla (opcional)")
    args = ap.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except Exception as e:  # sin Playwright no hay nada que probar aquí
        print("No puedo correr estas pruebas: falta Playwright (%s). pip install playwright; playwright install chromium" % e)
        return 77
    for need in ("bash", "openssl"):
        if not shutil.which(need):
            print("No puedo correr estas pruebas: falta %s" % need)
            return 77

    tmp = tempfile.mkdtemp(prefix="nexo-ui.")
    home = os.path.join(tmp, "a")
    shots = args.shots or os.path.join(tmp, "shots")
    os.makedirs(shots, exist_ok=True)
    docs = os.path.join(home, "share", "docs")
    os.makedirs(docs)
    os.makedirs(os.path.join(home, "share", "sub"))
    for name, data in (
        ("data.xyz123", b"z"), ("noext", b"n"), ("archive.tar.gz", b"g"), ("real.png", PNG_1X1),
        ("note.txt", b"hola desde el telefono\n"),
        ("evil.html", b"<script>alert('pwned');document.title='pwned'</script><h1>x</h1>\n"),
    ):
        with open(os.path.join(docs, name), "wb") as f:
            f.write(data)

    port = free_port()
    env = {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": home, "TMPDIR": tmp,
        "NEXO_TOOLS_IP": "127.0.0.1", "NEXO_TOOLS_DISCOVER_PORT": str(free_port(socket.SOCK_DGRAM)),
        "NEXO_TOOLS_BEACON_TO": "127.0.0.1", "NEXO_TOOLS_DEVICE": "Telefono-A",
    }

    def tools(*a, timeout=60):
        return subprocess.run(["bash", TOOLS] + list(a), env=env, stdin=subprocess.DEVNULL, capture_output=True,
                              text=True, timeout=timeout)

    res = []
    errors, dialogs, nextp = [], [], ["x"]

    def check(name, cond, extra=""):
        res.append(bool(cond))
        print(("  ok    " if cond else "  FALLA ") + name, flush=True)
        if not cond and extra:
            print("        %s" % (extra,), flush=True)

    def waitfor(cond, timeout=8.0):          # (la CSP de la página impide wait_for_function: se sondea desde aquí)
        end = time.time() + timeout
        while time.time() < end:
            try:
                if cond():
                    return True
            except Exception:
                pass
            time.sleep(0.1)
        raise TimeoutError("la condición no se cumplió a tiempo")

    started = False
    code = 1
    try:
        print("== nexo-tools: gestor web (/ui) en un Chromium sin pantalla")
        r = tools("server", home, str(port), "--rw")
        if r.returncode != 0:
            print("  FALLA no arrancó nexo-tools server --rw\n        %s%s" % (r.stdout, r.stderr))
            return 1
        started = True
        r = tools("web", "--rw")
        m = re.search(r"https://\S*/ui#t=[0-9a-f]+", ANSI.sub("", r.stdout + r.stderr))
        if r.returncode != 0 or not m:
            print("  FALLA nexo-tools web --rw no dio una dirección\n        %s%s" % (r.stdout, r.stderr))
            return 1
        url = m.group(0)

        with sync_playwright() as p:
            try:
                b = p.chromium.launch(args=["--no-sandbox"] if hasattr(os, "geteuid") and os.geteuid() == 0 else [])
            except Exception as e:
                print("No puedo correr estas pruebas: Chromium no arranca (%s). playwright install chromium" % str(e).splitlines()[0])
                return 77
            ctx = b.new_context(ignore_https_errors=True, viewport={"width": 1100, "height": 800}, accept_downloads=True)
            page = ctx.new_page()
            page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
            page.on("pageerror", lambda e: errors.append("pageerror: %s" % e))

            def on_dialog(d):
                dialogs.append((d.type, d.message))
                d.accept(nextp[0]) if d.type == "prompt" else d.accept()
            page.on("dialog", on_dialog)

            page.goto(url)
            page.wait_for_selector("#app:not([hidden])", timeout=10000)
            check("entra con el token del fragmento (#t=)", True)
            check("el fragmento se borra de la barra de direcciones", "#t=" not in page.url, page.url)
            check("muestra el nombre del dispositivo", "Telefono-A" in page.inner_text("#dev"), page.inner_text("#dev"))
            check("muestra el permiso (lectura y escritura)", "lectura y escritura" in page.inner_text("#role"))
            check("con el permiso de escritura se ven los botones de subir y carpeta", page.is_visible("#rwbar"))
            check("el formulario de entrada desaparece al entrar", not page.is_visible("#login"))
            check("«Salir» se ve con la sesión abierta", page.is_visible("#logout"))
            names = lambda: [x.inner_text() for x in page.query_selector_all("#list li button.name")]
            check("la raíz lista «share»", "share" in names(), names())
            page.click("#list li button.name:text-is('share')")
            waitfor(lambda: "docs" in page.inner_text("#list"))
            page.click("#list li button.name:text-is('docs')")
            waitfor(lambda: "data.xyz123" in page.inner_text("#list"))
            check("dentro de docs se ven todos los archivos (extensión rara incluida)",
                  "data.xyz123" in names() and "noext" in names(), names())
            check("las migas de pan muestran la ruta", "docs" in page.inner_text("#crumbs"), page.inner_text("#crumbs"))
            chips = page.inner_text("#types")
            check("hay botones de tipo con el recuento (.xyz123 · 1)", ".xyz123 · 1" in chips, chips)
            page.fill("#filter", ".png")
            check("filtrar por extensión (.png) deja solo los .png", names() == ["real.png"], names())
            page.screenshot(path=os.path.join(shots, "desktop-filtrado.png"))
            page.click("#list li button.name:text-is('real.png')")
            waitfor(lambda: page.evaluate("() => { const i = document.querySelector('#vbody img'); return !!i && i.complete && i.naturalWidth > 0; }"))
            check("una imagen se ve dentro de la página (sin descargarla)", page.is_visible("#viewer"))
            page.screenshot(path=os.path.join(shots, "desktop-visor.png"))
            page.click("#vclose")
            page.fill("#filter", "note")
            page.click("#list li button.name:text-is('note.txt')")
            page.wait_for_selector("#vbody pre", timeout=8000)
            check("un texto se muestra en el visor", "hola desde el telefono" in page.inner_text("#vbody pre"), page.inner_text("#vbody pre"))
            page.click("#vclose")
            title0 = page.title()
            page.fill("#filter", "evil")
            page.click("#list li button.name:text-is('evil.html')")
            page.wait_for_selector("#vbody pre", timeout=8000)
            time.sleep(0.5)
            check("un HTML con script se ve como TEXTO", "<script>" in page.inner_text("#vbody pre"), page.inner_text("#vbody pre"))
            check("…y el script NO se ejecutó (título intacto, sin diálogos)",
                  page.title() == title0 and not [d for d in dialogs if d[0] == "alert"], (page.title(), dialogs))
            page.click("#vclose")
            page.fill("#filter", "")
            nextp[0] = "carpeta-ui"
            page.click("#mkdir")
            waitfor(lambda: "carpeta-ui" in page.inner_text("#list"))
            check("«Carpeta nueva» crea la carpeta", os.path.isdir(os.path.join(docs, "carpeta-ui")))
            up = os.path.join(tmp, "upload.bin")
            with open(up, "wb") as f:
                f.write(os.urandom(5000))
            page.set_input_files("#upload", up)
            waitfor(lambda: "Subida terminada" in page.inner_text("#status"))
            dest = os.path.join(docs, "upload.bin")
            check("subir un archivo desde el navegador", os.path.exists(dest) and os.path.getsize(dest) == 5000)
            row = page.query_selector("#list li:has(button.name:text-is('upload.bin'))")
            nextp[0] = "renombrado.bin"
            row.query_selector("button:text-is('Renombrar')").click()
            waitfor(lambda: "renombrado.bin" in page.inner_text("#list"))
            check("renombrar desde el navegador",
                  os.path.exists(os.path.join(docs, "renombrado.bin")) and not os.path.exists(dest))
            row = page.query_selector("#list li:has(button.name:text-is('renombrado.bin'))")
            row.query_selector("button:text-is('Borrar')").click()
            waitfor(lambda: "renombrado.bin" not in page.inner_text("#list"))
            trash = [f for d, _, fs in os.walk(os.path.join(home, ".nexo-trash")) for f in fs]
            check("borrar manda el archivo a la papelera, no lo destruye",
                  "renombrado.bin" in trash and not os.path.exists(os.path.join(docs, "renombrado.bin")), trash)
            check("pidió confirmación antes de borrar", any(d[0] == "confirm" for d in dialogs))
            page.set_viewport_size({"width": 390, "height": 800})
            time.sleep(0.2)
            mv = page.evaluate("""() => ({
                cut: [...document.querySelectorAll('#list li button.name')].filter(b => b.scrollWidth > b.clientWidth + 1).map(b => b.textContent),
                over: document.documentElement.scrollWidth - window.innerWidth })""")
            check("en pantalla de móvil (390 px) los nombres de archivo se leen enteros", not mv["cut"], mv["cut"])
            check("…y la página no se desplaza hacia los lados", mv["over"] <= 0, mv["over"])
            page.screenshot(path=os.path.join(shots, "movil.png"))
            page.set_viewport_size({"width": 1100, "height": 800})
            page.click("#logout")
            check("Salir devuelve al formulario de entrada", page.is_visible("#login") and not page.is_visible("#app"))
            check("…y «Salir» desaparece hasta volver a entrar", not page.is_visible("#logout"))
            page.fill("#token", "0000")
            page.click("#login button[type=submit]")
            waitfor(lambda: len(page.inner_text("#loginerr")) > 0)
            check("un token malo se rechaza con un mensaje", "incorrecto" in page.inner_text("#loginerr").lower(),
                  page.inner_text("#loginerr"))
            page.screenshot(path=os.path.join(shots, "login.png"))
            r2 = tools("web")                                   # sin --rw: el acceso del navegador es de solo lectura
            m2 = re.search(r"https://\S*/ui#t=[0-9a-f]+", ANSI.sub("", r2.stdout + r2.stderr))
            if not m2:
                check("nexo-tools web (sin --rw) da una dirección", False, r2.stdout + r2.stderr)
            else:
                ro = ctx.new_page()
                ro.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)
                ro.on("pageerror", lambda e: errors.append("pageerror: %s" % e))
                ro.on("dialog", on_dialog)
                ro.goto(m2.group(0))
                ro.wait_for_selector("#app:not([hidden])", timeout=10000)
                check("con el acceso de solo lectura la página lo dice", "solo lectura" in ro.inner_text("#role"), ro.inner_text("#role"))
                check("…y no muestra los botones de subir ni de carpeta nueva", not ro.is_visible("#rwbar") and not ro.is_visible("#mkdir"))
                ro.click("#list li button.name:text-is('share')")
                waitfor(lambda: "docs" in ro.inner_text("#list"))
                ro.click("#list li button.name:text-is('docs')")
                waitfor(lambda: "data.xyz123" in ro.inner_text("#list"))
                acts = [x.inner_text() for x in ro.query_selector_all("#list li .acts button")]
                check("…ni «Renombrar» ni «Borrar» en ningún archivo", "Renombrar" not in acts and "Borrar" not in acts, acts)
                check("…pero sí «Descargar»", "Descargar" in acts, acts)
                ro.close()
            bad = [e for e in errors if "401" not in e and "Unauthorized" not in e]
            check("ningún error de JavaScript en la consola", not bad, bad)
            b.close()
        print("\nResultado: %d bien, %d con fallos" % (sum(res), len(res) - sum(res)))
        code = 0 if res and all(res) else 1
    except Exception as e:
        print("  FALLA la prueba se interrumpió: %s: %s" % (type(e).__name__, str(e).splitlines()[0] if str(e) else ""))
        if res:
            print("\nResultado: %d bien, %d con fallos" % (sum(res), len(res) - sum(res) + 1))
        code = 1
    finally:
        if started:
            try:
                tools("stop", timeout=30)
            except Exception:
                pass
        shutil.rmtree(tmp, ignore_errors=True)
    return code


if __name__ == "__main__":
    sys.exit(main())
