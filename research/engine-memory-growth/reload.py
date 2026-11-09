"""Reloads a research engine's page through the research-only `research-reload` endpoint
(research-reload.patch; the daemon must be built with it).

usage: python3 -I reload.py <engine dir> <port>
"""
import json, os, sys, urllib.request

d, port = sys.argv[1], sys.argv[2]
with open(os.path.join(d, "daemon-secret")) as f:
    secret = f.read().strip()
req = urllib.request.Request(f"http://localhost:{port}/cli/research-reload", data=b"{}", method="POST",
                             headers={"X-AM-Secret": secret, "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=30) as r:
    for line in r:
        line = line.strip()
        if line:
            print(json.loads(line))
