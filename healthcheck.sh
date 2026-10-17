#!/usr/bin/env bash
# Healthy when the Orca server answers HTTP on its port (it serves the web client at /).
exec curl -fsS -o /dev/null --max-time 4 "http://127.0.0.1:${ORCA_PORT:-6768}/"
