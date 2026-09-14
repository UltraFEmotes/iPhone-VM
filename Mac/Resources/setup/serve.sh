#!/bin/bash
# Serves this folder to the iPhone VM at http://192.168.178.1:8088 (started over ssh by InfernoMac).
set -e
cd "$(dirname "$0")"

healthy() {
    curl -fsS -m 2 http://127.0.0.1:8088/api/health >/dev/null 2>&1
}

if ! healthy; then
    pkill -f 'broker.py|http.server 8088' >/dev/null 2>&1 || true
    setsid nohup python3 broker.py >/tmp/carrier-broker.log 2>&1 < /dev/null &
    sleep 2
fi

if healthy; then
    echo "HTTP 200"
else
    echo "HTTP 000"
fi
