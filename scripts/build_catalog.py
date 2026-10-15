#!/usr/bin/env python3
"""Convert the official SMTR GTFS into No Ponto's compact, offline catalog.

Python standard library only. stop_times is streamed into a temporary SQLite
index, so unordered source rows work without retaining the 85 MB CSV in RAM.
No third-party application data or code is used. Source: SMTR, CC BY 4.0.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import csv
import datetime as dt
import hashlib
import io
import itertools
import json
import math
import pathlib
import re
import sqlite3
import statistics
import sys
import tempfile
import time
import urllib.request
import zipfile

SOURCE_URL = "https://dados.mobilidade.rio/gtfs/schedule"
EARTH_RADIUS = 6_371_000.0
MAX_DOWNLOAD_BYTES = 100 * 1024 * 1024


def distance(a, b):
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, math.radians(b[1] - a[1])
    h = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return EARTH_RADIUS * 2 * math.asin(min(1, math.sqrt(h)))


def quantize(value):
    """Nearest integer, ties away from zero (matching common polyline encoders)."""
    return int(math.copysign(math.floor(abs(value) * 100000 + 0.5), value))


def encode_polyline(points):
    result, previous = [], (0, 0)
    for point in points:
        current = tuple(quantize(v) for v in point)
        for value, old in zip(current, previous):
            delta = value - old
            encoded = ~(delta << 1) if delta < 0 else delta << 1
            while encoded >= 0x20:
                result.append(chr((0x20 | (encoded & 0x1f)) + 63))
                encoded >>= 5
            result.append(chr(encoded + 63))
        previous = current
    return "".join(result)


def decode_polyline(value):
    result, index, point = [], 0, [0, 0]
    while index < len(value):
        for axis in (0, 1):
            shift, number = 0, 0
            while True:
                byte = ord(value[index]) - 63
                index += 1
                number |= (byte & 0x1f) << shift
                shift += 5
                if byte < 0x20:
                    break
            point[axis] += ~(number >> 1) if number & 1 else number >> 1
        result.append((point[0] / 100000, point[1] / 100000))
    return result


def number(value):
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def clock_seconds(value):
    try:
        hours, minutes, seconds = map(int, value.split(":"))
        if hours < 0 or not 0 <= minutes < 60 or not 0 <= seconds < 60:
            return None
        return float(hours * 3600 + minutes * 60 + seconds)
    except (ValueError, AttributeError):
        return None


def csv_rows(archive, name):
    with archive.open(name) as binary:
        with io.TextIOWrapper(binary, encoding="utf-8-sig", newline="") as stream:
            yield from csv.DictReader(stream)


def interpolate(progress, cumulative, points):
    index = min(max(1, bisect.bisect_left(cumulative, progress)), len(points) - 1)
    span = cumulative[index] - cumulative[index - 1]
    fraction = min(1, max(0, (progress - cumulative[index - 1]) / span)) if span else 0
    return tuple(points[index - 1][axis] + fraction * (points[index][axis] - points[index - 1][axis]) for axis in (0, 1))


def projection(point, points, cumulative, minimum=0.0, with_ambiguity=False):
    """Nearest projection after minimum; ties select earliest loop occurrence."""
    best, candidates = None, []
    cos_lat = math.cos(math.radians(point[0]))
    lat_scale, lon_scale = math.pi * EARTH_RADIUS / 180, math.pi * EARTH_RADIUS / 180 * cos_lat
    for index, (a, b) in enumerate(zip(points, points[1:])):
        if cumulative[index + 1] + 0.001 < minimum:
            continue
        ax, ay = (a[1] - point[1]) * lon_scale, (a[0] - point[0]) * lat_scale
        bx, by = (b[1] - a[1]) * lon_scale, (b[0] - a[0]) * lat_scale
        square = bx * bx + by * by
        fraction = max(0.0, min(1.0, -(ax * bx + ay * by) / square)) if square else 0.0
        span = cumulative[index + 1] - cumulative[index]
        if span > 0:
            fraction = max(fraction, min(1.0, (minimum - cumulative[index]) / span))
        error = math.hypot(ax + fraction * bx, ay + fraction * by)
        progress = cumulative[index] + fraction * span
        if with_ambiguity:
            candidates.append((progress, error))
        if best is None or error < best[1] - 0.001:
            best = (progress, error)
    best = best or (minimum, float("inf"))
    if with_ambiguity:
        ambiguous = any(abs(progress - best[0]) > 150 and error <= best[1] + 10 for progress, error in candidates)
        return (*best, ambiguous)
    return best


def shape_info(rows):
    rows.sort(key=lambda row: row[0])
    if len({row[0] for row in rows}) != len(rows):
        raise ValueError("Duplicate shape sequence")
    original = [(row[1], row[2]) for row in rows]
    # Distances must agree with the precision-5 geometry decoded by the app.
    points = [(quantize(lat) / 100000, quantize(lon) / 100000) for lat, lon in original]
    cumulative = [0.0]
    for a, b in zip(points, points[1:]):
        cumulative.append(cumulative[-1] + distance(a, b))
    source_distances = [row[3] for row in rows]
    valid_source = all(v is not None and v >= 0 for v in source_distances)
    valid_source = valid_source and all(a <= b for a, b in zip(source_distances, source_distances[1:]))
    if valid_source and cumulative[-1] > 0:
        length = source_distances[-1] - source_distances[0]
        valid_source = 0.9 <= length / cumulative[-1] <= 1.1
    return {"points": points, "distances": cumulative, "sourceDistances": source_distances if valid_source else None,
            "polyline": encode_polyline(points)}


def stop_distances(visits, shape, stops):
    points, cumulative, source = shape["points"], shape["distances"], shape["sourceDistances"]
    raw = [visit[4] for visit in visits]
    valid_source = source is not None and all(value is not None and value >= 0 for value in raw)
    valid_source = valid_source and all(a <= b for a, b in zip(raw, raw[1:]))
    valid_source = valid_source and raw[-1] <= source[-1] + 20 and raw[0] >= source[0] - 20
    projected, errors, ambiguous = [], [], [False] * len(visits)
    if valid_source:
        for visit, value in zip(visits, raw):
            index = min(max(1, bisect.bisect_left(source, value)), len(source) - 1)
            span = source[index] - source[index - 1]
            fraction = min(1, max(0, (value - source[index - 1]) / span)) if span else 0
            progress = cumulative[index - 1] + fraction * (cumulative[index] - cumulative[index - 1])
            stop = stops[visit[1]]
            error = distance((stop["latitude"], stop["longitude"]), interpolate(progress, cumulative, points))
            projected.append(progress)
            errors.append(error)
        # An inconsistent provided distance can select the wrong loop passage.
        valid_source = max(errors, default=0) <= 150
    if not valid_source:
        projected, errors, ambiguous = [], [], []
        minimum = 0.0
        for visit in visits:
            stop = stops[visit[1]]
            progress, error, uncertain = projection((stop["latitude"], stop["longitude"]), points, cumulative, minimum, with_ambiguity=True)
            projected.append(progress)
            errors.append(error)
            ambiguous.append(uncertain)
            minimum = progress
    return [round(value, 2) for value in projected], errors, "gtfs-calibrated" if valid_source else "monotonic-projection", ambiguous


def download(destination):
    started = time.monotonic()
    request = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "NoPonto-CatalogBuilder/1.0 (personal transit app)", "Accept": "application/zip"})
    with urllib.request.urlopen(request, timeout=60) as response, destination.open("wb") as output:
        total = 0
        while chunk := response.read(1024 * 1024):
            if time.monotonic() - started > 180:
                raise TimeoutError("Official schedule download exceeded 180 seconds")
            total += len(chunk)
            if total > MAX_DOWNLOAD_BYTES:
                raise ValueError("Official schedule exceeds the 100 MiB safety limit")
            output.write(chunk)
        return response.headers.get("Last-Modified", "")


def build(input_path, output_path, source_modified=""):
    input_path, output_path = pathlib.Path(input_path), pathlib.Path(output_path)
    source_hash = hashlib.sha256(input_path.read_bytes()).hexdigest()
    audit = {"sourceURL": SOURCE_URL, "attribution": "Dados: Secretaria Municipal de Transportes do Rio de Janeiro (SMTR), CC BY 4.0.",
             "licenseURL": "https://creativecommons.org/licenses/by/4.0/", "sourceSHA256": source_hash,
             "distanceMethod": "Haversine R=6371000m on encoded precision-5 geometry; validated GTFS distances interpolate into that domain; otherwise monotonic projection.",
             "warnings": [], "patternsNeedingReview": [], "counts": {}, "projectionMethods": {}}
    with zipfile.ZipFile(input_path) as archive, tempfile.TemporaryDirectory(prefix="no-ponto-catalog-") as temp:
        if not source_modified:
            source_modified = max(dt.date(*entry.date_time[:3]) for entry in archive.infolist()).isoformat()
            audit["sourceModifiedBasis"] = "Latest content date in ZIP directory; not the date of download."
        else:
            audit["sourceModifiedBasis"] = "HTTP Last-Modified"
        agencies = {row["agency_id"]: row["agency_name"] for row in csv_rows(archive, "agency.txt")}
        routes = []
        for row in csv_rows(archive, "routes.txt"):
            agency = agencies.get(row["agency_id"], row["agency_id"])
            routes.append({"id": row["route_id"], "shortName": row["route_short_name"], "longName": row["route_long_name"],
                           "agency": agency, "mode": "brt" if row["agency_id"] == "20001" or "mobi-rio" in agency.casefold() else "bus",
                           "color": row.get("route_color", "").upper() if re.fullmatch(r"[0-9a-fA-F]{6}", row.get("route_color", "")) else "167DAD", "patternIDs": []})
        routes.sort(key=lambda row: (row["mode"], tuple((int(part) if part.isdigit() else part) for part in re.split(r"(\d+)", row["shortName"])), row["id"]))
        route_map = {route["id"]: route for route in routes}
        if len(route_map) != len(routes):
            raise ValueError("Duplicate route IDs")
        stops = {}
        for row in csv_rows(archive, "stops.txt"):
            latitude, longitude = float(row["stop_lat"]), float(row["stop_lon"])
            if not (math.isfinite(latitude) and math.isfinite(longitude) and -90 <= latitude <= 90 and -180 <= longitude <= 180):
                raise ValueError("Invalid stop coordinates: " + row["stop_id"])
            if row["stop_id"] in stops:
                raise ValueError("Duplicate stop ID: " + row["stop_id"])
            stops[row["stop_id"]] = {"id": row["stop_id"], "name": row["stop_name"], "latitude": latitude, "longitude": longitude}
        trips = {}
        for row in csv_rows(archive, "trips.txt"):
            if row["trip_id"] in trips:
                raise ValueError("Duplicate trip ID")
            trips[row["trip_id"]] = row
            if row["route_id"] not in route_map:
                raise ValueError("Trip refers to unknown route")
        shape_rows = collections.defaultdict(list)
        for row in csv_rows(archive, "shapes.txt"):
            lat, lon = float(row["shape_pt_lat"]), float(row["shape_pt_lon"])
            if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                raise ValueError("Invalid shape point")
            shape_rows[row["shape_id"]].append((int(row["shape_pt_sequence"]), lat, lon, number(row.get("shape_dist_traveled"))))
        shapes = {identity: shape_info(rows) for identity, rows in shape_rows.items() if len(rows) >= 2}
        del shape_rows
        print(f"Catalog: {len(routes)} routes, {len(stops)} stops, {len(trips)} trips, {len(shapes)} shapes; indexing stop_times", file=sys.stderr, flush=True)
        db = sqlite3.connect(pathlib.Path(temp) / "times.sqlite")
        db.execute("PRAGMA journal_mode=OFF")
        db.execute("PRAGMA synchronous=OFF")
        db.execute("CREATE TABLE times (trip TEXT, sequence INTEGER, stop TEXT, arrival REAL, departure REAL, distance REAL)")
        row_count = 0
        def stop_rows():
            nonlocal row_count
            for row in csv_rows(archive, "stop_times.txt"):
                row_count += 1
                if row["trip_id"] not in trips or row["stop_id"] not in stops:
                    raise ValueError("stop_times refers to unknown trip or stop")
                yield (row["trip_id"], int(row["stop_sequence"]), row["stop_id"], clock_seconds(row["arrival_time"]), clock_seconds(row["departure_time"]), number(row.get("shape_dist_traveled")))
        db.executemany("INSERT INTO times VALUES (?,?,?,?,?,?)", stop_rows())
        db.execute("CREATE INDEX times_trip_sequence ON times(trip,sequence)")
        print(f"Catalog: indexed {row_count} stop_time rows; constructing patterns", file=sys.stderr, flush=True)
        patterns, trip_patterns, signatures, timing = {}, {}, {}, {}
        methods = collections.Counter()
        cursor = db.execute("SELECT trip,sequence,stop,arrival,departure,distance FROM times ORDER BY trip,sequence")
        for trip_id, rows in itertools.groupby(cursor, key=lambda row: row[0]):
            visits = [row[1:] for row in rows]
            if len({visit[0] for visit in visits}) != len(visits):
                raise ValueError("Duplicate stop_sequence in trip " + trip_id)
            trip = trips[trip_id]
            shape_id = trip["shape_id"]
            if shape_id not in shapes:
                audit["warnings"].append("No usable shape for trip " + trip_id)
                continue
            direction = int(trip.get("direction_id") or -1)
            signature = (trip["route_id"], direction, shape_id, trip["trip_headsign"], tuple((visit[0], visit[1]) for visit in visits))
            if signature not in signatures:
                identity = "p-" + hashlib.sha256(json.dumps(signature, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).hexdigest()[:20]
                signatures[signature] = identity
                distances, errors, method, ambiguous = stop_distances(visits, shapes[shape_id], stops)
                methods[method] += 1
                patterns[identity] = {"id": identity, "routeID": trip["route_id"], "direction": direction, "headsign": trip["trip_headsign"],
                                      "shapeID": shape_id, "polyline": shapes[shape_id]["polyline"], "stops": [{"stopID": visit[1], "sequence": visit[0], "distance": progress, "scheduledOffset": None, "distanceReliable": error <= 100 and not uncertain} for visit, progress, error, uncertain in zip(visits, distances, errors, ambiguous)], "tripCount": 0}
                timing[identity] = [[] for _ in visits]
                route_map[trip["route_id"]]["patternIDs"].append(identity)
                if max(errors, default=0) > 100 or any(ambiguous):
                    audit["patternsNeedingReview"].append({"patternID": identity, "routeID": trip["route_id"], "shapeID": shape_id,
                        "method": method, "maxStopDistanceFromShapeMeters": round(max(errors), 1),
                        "stopSequences": [visit[0] for visit, error, uncertain in zip(visits, errors, ambiguous) if error > 100 or uncertain],
                        "ambiguousStopSequences": [visit[0] for visit, uncertain in zip(visits, ambiguous) if uncertain]})
            identity = signatures[signature]
            patterns[identity]["tripCount"] += 1
            trip_patterns[trip_id] = identity
            origin = visits[0][2] if visits[0][2] is not None else visits[0][3]
            if origin is not None:
                previous = origin
                for index, visit in enumerate(visits):
                    value = visit[2] if visit[2] is not None else visit[3]
                    if value is not None and value >= previous and value - origin <= 6 * 3600:
                        timing[identity][index].append(value - origin)
                        previous = value
        db.close()
        print(f"Catalog: {len(patterns)} distinct patterns, {len(trip_patterns)} mapped trips; writing JSON", file=sys.stderr, flush=True)
        for identity, samples in timing.items():
            previous = 0.0
            for visit, values in zip(patterns[identity]["stops"], samples):
                if values:
                    previous = max(previous, round(statistics.median(values), 1))
                    visit["scheduledOffset"] = previous
        for route in routes:
            route["patternIDs"].sort(key=lambda identity: (patterns[identity]["direction"], -patterns[identity]["tripCount"], patterns[identity]["headsign"], identity))
        feed = next(csv_rows(archive, "feed_info.txt"), {})
        parse_date = lambda value: dt.datetime.strptime(value, "%Y%m%d").date().isoformat() if value else ""
        catalog = {"schemaVersion": 1, "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"), "sourceModified": source_modified,
                   "sourceURL": SOURCE_URL, "validFrom": parse_date(feed.get("feed_start_date")), "validUntil": parse_date(feed.get("feed_end_date")),
                   "routes": routes, "stops": sorted(stops.values(), key=lambda row: row["id"]), "patterns": sorted(patterns.values(), key=lambda row: row["id"]), "tripPatterns": dict(sorted(trip_patterns.items()))}
        audit["projectionMethods"] = dict(methods)
        audit["counts"] = {"routes": len(routes), "busRoutes": sum(row["mode"] == "bus" for row in routes), "brtRoutes": sum(row["mode"] == "brt" for row in routes),
                           "stops": len(stops), "shapes": len(shapes), "trips": len(trips), "mappedTrips": len(trip_patterns), "patterns": len(patterns), "stopTimeRows": row_count,
                           "stopVisits": sum(len(row["stops"]) for row in patterns.values()), "patternsWithRepeatedStops": sum(len({visit["stopID"] for visit in row["stops"]}) < len(row["stops"]) for row in patterns.values()),
                           "routesWithoutPatterns": sum(not row["patternIDs"] for row in routes), "patternsNeedingReview": len(audit["patternsNeedingReview"]),
                           "unreliableStopVisits": sum(not visit["distanceReliable"] for row in patterns.values() for visit in row["stops"])}
        audit["unmappedTripIDs"] = sorted(set(trips) - set(trip_patterns))
        audit["routeSamples"] = [{"id": row["id"], "shortName": row["shortName"], "mode": row["mode"], "patternCount": len(row["patternIDs"])} for row in routes if row["shortName"] in ("369", "397", "SR397", "10")]
        output_path.parent.mkdir(parents=True, exist_ok=True)
        data = json.dumps(catalog, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")
        output_path.write_bytes(data)
        audit.update({"generatedAt": catalog["generatedAt"], "sourceModified": source_modified, "catalogBytes": len(data), "catalogSHA256": hashlib.sha256(data).hexdigest()})
        output_path.with_name("catalog-audit.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        return audit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=pathlib.Path, help="Existing official GTFS ZIP; omit to download the official feed")
    parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[1] / "NoPonto/Resources/catalog.json")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="no-ponto-source-") as temp:
        modified = ""
        source = args.input
        if source is None:
            source = pathlib.Path(temp) / "official-schedule.zip"
            modified = download(source)
        audit = build(source, args.output, modified)
        print(json.dumps({"output": str(args.output), "bytes": audit["catalogBytes"], "counts": audit["counts"], "projectionMethods": audit["projectionMethods"]}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
