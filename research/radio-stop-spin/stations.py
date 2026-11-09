"""Lists Apple Music's live radio stations (US storefront) with the developer token in $AM_CONFIG_DIR."""
import json, os, sys, urllib.request

cfg = os.environ["AM_CONFIG_DIR"]
tok = open(os.path.join(cfg, "developer-token.jwt")).read().strip()


def get(path):
    req = urllib.request.Request("https://api.music.apple.com" + path,
                                 headers={"Authorization": "Bearer " + tok, "Origin": "http://localhost:47823"})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


path = sys.argv[1] if len(sys.argv) > 1 else "/v1/catalog/us/stations?filter[featured]=apple-music-live-radio"
for s in get(path).get("data", []):
    a = s["attributes"]
    print(s["id"], "|", a.get("name"), "| isLive", a.get("isLive"), "| kind", a.get("playParams", {}).get("kind"),
          "| format", a.get("playParams", {}).get("format"), "| stationProviderName", a.get("stationProviderName"))
