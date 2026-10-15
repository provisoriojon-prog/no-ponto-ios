"""Small independent availability evidence; no user location or credentials."""
import datetime
import hashlib
import json
import urllib.request

results = []
for source in ("onibus", "brt"):
    url = f"https://dados.mobilidade.rio/gtfs/realtime/{source}/vehicle-positions"
    row = {"source": source, "url": url, "checkedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "NoPonto-validation/1.0"}), timeout=35) as response:
            data = response.read(12_000_001)
            assert 0 < len(data) <= 12_000_000
            row.update(httpStatus=response.status, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), cacheControl=response.headers.get("Cache-Control"))
    except Exception as error:
        row["error"] = str(error)
    results.append(row)
print(json.dumps({"note": "Availability probe only; recorded official fixtures independently test protobuf parsing and geometry.", "sources": results}, indent=2))
