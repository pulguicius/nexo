#!/usr/bin/env python3
"""Cliente HTTPS mínimo para probar el servidor de nexo-tools desde las pruebas (no forma parte del producto).

  tools_probe.py --port P [--host H] [--token T] [--pin HUELLA] [--json CUERPO | --file ARCHIVO] [--header K:V]...
                 [--show-headers] [--out ARCHIVO] METODO RUTA

Imprime el código HTTP en la primera línea; con --show-headers, las cabeceras que importan (una por línea, «H nombre: valor»);
y después el cuerpo (o lo guarda con --out). Salida 3 si la huella del certificado no coincide con --pin.
"""
import argparse
import hashlib
import http.client
import os
import ssl
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--token", default="")
    ap.add_argument("--pin", default="")
    ap.add_argument("--json", dest="jbody")
    ap.add_argument("--file")
    ap.add_argument("--header", action="append", default=[])
    ap.add_argument("--show-headers", action="store_true")
    ap.add_argument("--out")
    ap.add_argument("method")
    ap.add_argument("path")
    a = ap.parse_args()
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    conn = http.client.HTTPSConnection(a.host, a.port, context=ctx, timeout=30)
    conn.connect()
    if a.pin:
        got = hashlib.sha256(conn.sock.getpeercert(binary_form=True)).hexdigest()
        if got != a.pin.lower():
            print("PIN-MISMATCH", got)
            return 3
    headers = {}
    if a.token:
        headers["Authorization"] = "Bearer " + a.token
    for h in a.header:
        k, _, v = h.partition(":")
        headers[k.strip()] = v.strip()
    body = None
    if a.jbody is not None:
        body = a.jbody.encode("utf-8")
        headers["Content-Type"] = "application/json"
    elif a.file:
        headers["Content-Length"] = str(os.path.getsize(a.file))
        body = open(a.file, "rb")
    conn.request(a.method, a.path, body=body, headers=headers)
    r = conn.getresponse()
    data = r.read()
    print(r.status)
    if a.show_headers:
        for k in ("Content-Type", "Content-Disposition", "Content-Security-Policy", "Location", "Content-Range", "Retry-After", "X-Nexo-SHA256"):
            v = r.getheader(k)
            if v is not None:
                print("H %s: %s" % (k, v))
    if a.out:
        with open(a.out, "wb") as f:
            f.write(data)
    else:
        sys.stdout.write(data.decode("utf-8", "replace"))
        if data and not data.endswith(b"\n"):
            sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
