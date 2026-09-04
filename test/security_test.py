#!/usr/bin/env python3
"""Security tests for bin/margin-palette.

margin-palette is handed an MPRIS album-art URL. MPRIS metadata is published
by whatever is playing, and a browser tab is an MPRIS player, so that URL is
attacker-controlled in practice. These tests hold the two properties that
follow from that:

  1. it never opens a connection to a non-public address, directly or via a
     redirect, and
  2. bytes it did fetch never reach an ImageMagick delegate, and cannot make
     the decoder allocate without bound.

usage: python3 test/security_test.py [path/to/bin/margin-palette]
"""

import http.server
import importlib.machinery
import importlib.util
import json
import os
import struct
import subprocess
import sys
import threading
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PAL = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, os.pardir, "bin", "margin-palette")
PAL = os.path.abspath(PAL)
SHIM = os.path.join(HERE, "_shim.py")
TMP = os.path.join(HERE, ".fixtures")

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print(("  PASS  " if ok else "  FAIL  ") + name + ("   " + str(detail) if detail else ""))


# --------------------------------------------------------------- fixtures --
def png(path, w, h, depth, colortype, raw):
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    ihdr = struct.pack(">IIBBBBB", w, h, depth, colortype, 0, 0, 0)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def fixtures():
    os.makedirs(TMP, exist_ok=True)
    normal = os.path.join(TMP, "normal.png")
    rows = b""
    for y in range(64):
        rows += b"\x00" + bytes(v for x in range(64) for v in (x * 4, y * 4, 200))
    png(normal, 64, 64, 8, 2, rows)

    # 625 megapixels that cost ~74 KB on the wire: the download cap says
    # nothing about what the bytes decompress to.
    bomb = os.path.join(TMP, "bomb.png")
    side = 25000
    png(bomb, side, side, 1, 0, (b"\x00" + b"\x00" * (side // 8)) * side)

    mvg = os.path.join(TMP, "evil.mvg")
    with open(mvg, "w") as f:
        f.write('push graphic-context\nviewbox 0 0 1 1\n'
                'image over 0,0 1,1 "label:@/etc/passwd"\npop graphic-context\n')
    return normal, bomb, mvg


# ------------------------------------------------------------ the harness --
class Handler(http.server.BaseHTTPRequestHandler):
    hits = []
    art = b""
    port = 0

    def log_message(self, *a):
        pass

    def _redirect(self, to):
        self.send_response(302)
        self.send_header("Location", to)
        self.end_headers()

    def do_GET(self):
        Handler.hits.append(self.path)
        if self.path == "/redir-internal":
            return self._redirect("http://127.0.0.1:%d/secret" % Handler.port)
        if self.path == "/redir-ftp":
            return self._redirect("ftp://example.com/art.png")
        if self.path == "/redir-file":
            return self._redirect("file:///etc/passwd")
        if self.path == "/loop":
            return self._redirect("http://allowed.test:%d/loop" % Handler.port)
        self.send_response(200)
        self.send_header("Content-Type", "image/png")
        self.send_header("Content-Length", str(len(Handler.art)))
        self.end_headers()
        self.wfile.write(Handler.art)


def colors_of(proc):
    try:
        return json.loads(proc.stdout)["colors"]
    except Exception:
        return "UNPARSEABLE: " + proc.stdout.strip() + proc.stderr.strip()[-300:]


def run(arg):
    return colors_of(subprocess.run([sys.executable, PAL, arg],
                                    capture_output=True, text=True, timeout=120))


def run_shimmed(path):
    url = "http://allowed.test:%d%s" % (Handler.port, path)
    return colors_of(subprocess.run(
        [sys.executable, SHIM, PAL, "allowed.test", str(Handler.port), url],
        capture_output=True, text=True, timeout=120))


def load_module():
    loader = importlib.machinery.SourceFileLoader("margin_palette", PAL)
    spec = importlib.util.spec_from_loader("margin_palette", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


def main():
    normal, bomb, mvg = fixtures()
    mp = load_module()
    Handler.art = open(normal, "rb").read()
    srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    Handler.port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    print("\n== the feature still works ==")
    c = run(normal)
    check("local path -> palette", isinstance(c, list) and len(c) > 0, c)
    c = run("file://" + normal)
    check("file:// url -> palette", isinstance(c, list) and len(c) > 0, c)
    Handler.hits.clear()
    c = run_shimmed("/art.png")
    check("http fetch -> palette (control)", isinstance(c, list) and len(c) > 0, c)

    print("\n== it will not reach a non-public address ==")
    Handler.hits.clear()
    c = run("http://127.0.0.1:%d/secret" % Handler.port)
    check("loopback -> empty palette", c == [], c)
    check("loopback never contacted", Handler.hits == [], Handler.hits)
    for url in ["http://localhost:%d/secret" % Handler.port,
                "http://169.254.169.254/latest/meta-data/",
                "http://10.0.0.1/a.png", "http://192.168.1.1/a.png",
                "http://100.64.0.1/a.png", "http://[::1]/a.png",
                "http://0.0.0.0/a.png", "http://[::ffff:127.0.0.1]/a.png"]:
        check("refused " + url, run(url) == [])

    print("\n== nor via a redirect ==")
    Handler.hits.clear()
    check("redirect -> loopback refused", run_shimmed("/redir-internal") == [])
    check("redirect target never fetched", "/secret" not in Handler.hits, Handler.hits)
    check("redirect -> ftp:// refused", run_shimmed("/redir-ftp") == [])
    check("redirect -> file:// refused", run_shimmed("/redir-file") == [])
    Handler.hits.clear()
    check("redirect loop refused", run_shimmed("/loop") == [])
    check("redirect loop bounded (<=5 hops)", len(Handler.hits) <= 5, Handler.hits)

    print("\n== the decoder is pinned and bounded ==")
    t0 = time.time()
    c = run(bomb)
    dt = time.time() - t0
    check("625MP bomb -> empty palette", c == [], c)
    check("bomb refused promptly", dt < 10, "%.2fs" % dt)
    check("non-image sniffs as no coder", mp.coder_for("/etc/passwd") is None)
    check("MVG script sniffs as no coder", mp.coder_for(mvg) is None)
    check("MVG never decoded", run(mvg) == [])
    check("png sniffs as PNG", mp.coder_for(normal) == "PNG")
    check("bomb still sniffs as PNG (limits did the work, not the sniffer)",
          mp.coder_for(bomb) == "PNG")

    print("\n== is_public ==")
    for addr, want in [("8.8.8.8", True), ("1.1.1.1", True), ("2606:4700::1111", True),
                       ("127.0.0.1", False), ("10.1.2.3", False), ("172.16.0.1", False),
                       ("192.168.0.5", False), ("169.254.169.254", False),
                       ("100.64.0.1", False), ("::1", False), ("fd00::1", False),
                       ("fe80::1", False), ("0.0.0.0", False), ("224.0.0.1", False),
                       ("::ffff:10.0.0.1", False), ("64:ff9b::7f00:1", False),
                       ("not-an-address", False)]:
        check("is_public(%s) is %s" % (addr, want), mp.is_public(addr) is want)

    failed = RESULTS.count(False)
    print("\n%d/%d passed" % (RESULTS.count(True), len(RESULTS)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
