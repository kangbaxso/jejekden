#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  ZEPH worker (RandomX / CPU) -> kryptex pool
#  usage:
#    WALLET='ZEPHYR...' bash zeph.sh                        (langsung)
#    WALLET='ZEPHYR...' POOL='stratum+tcp://host:port' bash zeph.sh
#    WALLET='ZEPHYR...' ALGO='rx/0'           bash zeph.sh
#    WALLET='ZEPHYR...' TUNNEL='socks5://u:p@host:1080' bash zeph.sh
#  TUNNEL opsional: relay lewat proxy (SOCKS5/HTTP) + TLS asli ke pool.
#  ALGO default rx/0 (RandomX). POOL default kryptex zeph (TLS 7048).
# ============================================================

DEFAULT_WALLET="ZEPHYR2jZrZXenfKejCcCmEkRzUYwXjgWfJF4yzdCznKQ8yQ3g3PsWUbZjzfzHbeTPMgXVmEuDKQUB9rPkgtVwyWRh9knU4EpfJ57"
WALLET="${WALLET:-${DEFAULT_WALLET}}"
WORKER="$(hostname -s 2>/dev/null || echo node1)"
POOL="${POOL:-stratum+tcp://zeph.kryptex.network:7047}"
ALGO="${ALGO:-rx/0}"
BASE="${HOME}/.zeph"
TUNNEL="${TUNNEL:-}"
LOCAL_PORT=18048
XMR_API="https://api.github.com/repos/xmrig/xmrig/releases/latest"

step(){ echo; echo "==> $*"; }
die(){ echo "!! $*" >&2; exit 1; }

[[ "${WALLET}" == ZEPHYR* ]] || die "wallet harus diawali ZEPHYR... (WALLET='ZEPHYR…')"
[[ "${WALLET}" != "${DEFAULT_WALLET}" ]] || die "isi WALLET dulu — contoh: WALLET='ZEPHYR...' bash zeph.sh"
[[ "${WALLET}" != *localhost* ]] || die "wallet tidak valid"

for c in curl tar; do command -v "$c" >/dev/null || die "butuh: $c"; done

step "lokasi kerja: ${BASE}"
mkdir -p "${BASE}" && cd "${BASE}"

if [ ! -x ./xmrig ]; then
  step "cek rilis xmrig terbaru"
  REL="$(curl -fsSL "${XMR_API}")"
  URL="$(echo "${REL}" | grep -o '"browser_download_url": *"[^"]*linux-static-x64.tar.gz"' | head -1 | cut -d'"' -f4)"
  [ -n "${URL}" ] || die "arsip linux-static-x64 tidak ditemukan"
  step "unduh xmrig"
  curl -fL --retry 3 -o pkg.tgz "${URL}"
  step "ekstrak"
  tar xzf pkg.tgz
  rm -f pkg.tgz
  # cari binary xmrig; pakai `file` cuma kalau ada (validasi ELF ekstra)
  if command -v file >/dev/null 2>&1; then
    BIN="$(find . -maxdepth 3 -type f -name 'xmrig' -exec file {} + 2>/dev/null | grep -i 'ELF' | cut -d: -f1 | head -1)"
  else
    BIN="$(find . -maxdepth 3 -type f -name 'xmrig' | head -1)"
  fi
  [[ -n "${BIN}" ]] || die "binary xmrig tidak ditemukan"
  [ "${BIN}" = "./xmrig" ] || mv -f "${BIN}" ./xmrig
  chmod +x ./xmrig
fi

step "versi xmrig"
./xmrig --version 2>&1 | head -2 || true

RUN="${POOL}"
if [ -n "${TUNNEL}" ]; then
  step "proxy aktif: ${TUNNEL}"
  cat > ./relay.py <<'PYEOF'
#!/usr/bin/env python3
"""TCP -> (SOCKS5/HTTP) -> TLS relay. TUNNEL env, target dari argv."""
import os, sys, socket, ssl, threading, select, struct, base64

def parse_proxy(s):
    if not s:
        return None
    scheme, rest = s.split("://", 1)
    user = pw = None
    if "@" in rest:
        cred, rest = rest.rsplit("@", 1)
        if ":" in cred:
            user, _, pw = cred.partition(":")
        else:
            user = cred
    host, port = rest.rsplit(":", 1) if ":" in rest else (rest, "1080")
    return {"kind": "socks5" if "sock" in scheme else "http",
            "host": host, "port": int(port), "user": user, "pw": pw}

def socks5(p, target, tport):
    s = socket.create_connection((p["host"], p["port"]), timeout=15)
    if p["user"]:
        s.sendall(b"\x05\x02\x02\x00")
        m = s.recv(2)
        if m == b"\x05\x02":
            u, pw = p["user"].encode(), (p["pw"] or "").encode()
            s.sendall(bytes([1, len(u)]) + u + bytes([len(pw)]) + pw)
            if s.recv(2) != b"\x01\x00":
                raise RuntimeError("socks auth gagal")
        elif m != b"\x05\x00":
            raise RuntimeError("socks handshake gagal")
    else:
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise RuntimeError("socks handshake gagal")
    ip = socket.gethostbyname(target)
    s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(ip) + struct.pack(">H", tport))
    r = s.recv(10)
    if not r or r[1] != 0:
        raise RuntimeError("socks connect ditolak")
    return s

def hconnect(p, target, tport):
    s = socket.create_connection((p["host"], p["port"]), timeout=15)
    au = ""
    if p["user"]:
        au = "\r\nProxy-Authorization: Basic " + base64.b64encode(
            ("%s:%s" % (p["user"], p["pw"] or "")).encode()).decode()
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d%s\r\n\r\n"
               % (target, tport, target, tport, au)).encode())
    b = b""
    while b"\r\n\r\n" not in b:
        b += s.recv(1)
    if not b.startswith(b"HTTP/1.1 200") and not b.startswith(b"HTTP/1.0 200"):
        raise RuntimeError("http CONNECT gagal")
    return s

def pump(a, b):
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 2.0)
            if not r:
                continue
            for f in r:
                d = f.recv(65536)
                if not d:
                    return
                (b if f is a else a).sendall(d)
    except Exception:
        pass

def handle(c, target, tport, tun):
    raw = None
    try:
        if tun and tun["kind"] == "socks5":
            raw = socks5(tun, target, tport)
        elif tun:
            raw = hconnect(tun, target, tport)
        else:
            raw = socket.create_connection((target, tport), timeout=15)
        tls = ssl.create_default_context().wrap_socket(raw, server_hostname=target)
        threading.Thread(target=pump, args=(c, tls), daemon=True).start()
        pump(tls, c)
    except Exception as e:
        sys.stderr.write("relay: %s\n" % e)
    finally:
        try:
            c.close()
        except Exception:
            pass

def main():
    ln, tg, tp = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    tun = parse_proxy(os.environ.get("TUNNEL", ""))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", ln))
    srv.listen(64)
    sys.stderr.write("relay up: 127.0.0.1:%d -> %s (proxy=%s)\n" % (ln, tg,
        "direct" if not tun else ("%s://%s:%d" % (tun["kind"], tun["host"], tun["port"]))))
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, tg, tp, tun), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
  python3 -m py_compile ./relay.py || die "relay.py compile gagal"
  OLD="$(ss -ltnp 2>/dev/null | grep ":${LOCAL_PORT}" | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)"
  [ -z "${OLD}" ] || kill "${OLD}" 2>/dev/null || true
  sleep 0.3
  TUNNEL="${TUNNEL}" nohup python3 ./relay.py "${LOCAL_PORT}" zeph.kryptex.network 7048 > ./relay.log 2>&1 &
  sleep 1
  head -1 ./relay.log || true
  RUN="127.0.0.1:${LOCAL_PORT}"
fi

step "start"
echo "  wallet : ${WALLET:0:18}..."
echo "  worker : ${WORKER}"
echo "  pool   : ${RUN}   algo=${ALGO}"
exec ./xmrig -o "${RUN}" -u "${WALLET}" -p x --algo "${ALGO}"