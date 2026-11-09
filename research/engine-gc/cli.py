"""Calls a research daemon's CLI endpoint, e.g. a queue at volume 0 for the playing trial:

usage: python3 -I cli.py <engine dir> <port> <endpoint> '<json body>'
  cli.py $T/mem-stock 47941 queue '{"songs":["1561837008"],"repeat":"one","volume":0}'
  cli.py $T/mem-stock 47941 control '{"action":"stop"}'
"""
import json, os, sys, urllib.request

d, port, endpoint, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(os.path.join(d, "daemon-secret")) as f:
    secret = f.read().strip()
req = urllib.request.Request(f"http://localhost:{port}/cli/{endpoint}", data=body.encode(), method="POST",
                             headers={"X-AM-Secret": secret, "Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=60) as r:
    for line in r:
        line = line.strip()
        if line:
            try:
                print(json.loads(line))
            except ValueError:
                print(line.decode())
