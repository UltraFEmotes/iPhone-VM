#!/bin/bash
# Serves this folder to the iPhone VM at http://192.168.178.1:8088 (started over ssh by InfernoMac).
cd "$(dirname "$0")"
if ! ss -ltn | grep -q ':8088 '; then
    setsid nohup python3 -m http.server 8088 --bind 0.0.0.0 >/tmp/carrier-http.log 2>&1 < /dev/null &
    sleep 2
fi
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://127.0.0.1:8088/carrier-sqlite3
