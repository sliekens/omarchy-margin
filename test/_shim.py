"""Run margin-palette with exactly one hostname pretended to be public.

Redirect handling can only be tested if the first hop is allowed to happen.
This shim whitelists that one host and leaves every later hop to the real,
unpatched resolve_public, so what the test observes is the shipped logic.

usage: _shim.py <margin-palette> <allow-host> <allow-port> <url>
"""
import socket
import sys

PAL, ALLOW_HOST, ALLOW_PORT, URL = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

src = open(PAL).read().replace('if __name__ == "__main__":\n    main()\n', '')
mod = {"__name__": "margin_palette_under_test"}
exec(compile(src, PAL, "exec"), mod)

real = mod["resolve_public"]


def fake(host, port):
    if host == ALLOW_HOST:
        return (socket.AF_INET, ("127.0.0.1", ALLOW_PORT))
    return real(host, port)


mod["resolve_public"] = fake      # PinnedHTTPConnection looks it up via globals
sys.argv = [PAL, URL]
mod["main"]()
