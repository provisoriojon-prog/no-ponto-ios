#!/usr/bin/env python3
"""Catalog regression and whole-feed invariant checks, standard-library only."""
import argparse
import collections
import csv
import io
import json
import pathlib
import tempfile
import unittest
import zipfile

import build_catalog as builder

CATALOG = pathlib.Path(__file__).resolve().parents[1] / "NoPonto/Resources/catalog.json"
SOURCE = None


class GeometryTests(unittest.TestCase):
    def test_standard_polyline(self):
        points = [(38.5, -120.2), (40.7, -120.95), (43.252, -126.453)]
        encoded = "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
        self.assertEqual(builder.encode_polyline(points), encoded)
        self.assertEqual(builder.decode_polyline(encoded), points)

    def test_clock_after_midnight_and_invalid_values(self):
        self.assertEqual(builder.clock_seconds("25:12:00"), 90720)
        for value in ("", "bad", "12:66:00", "-1:00:00", "12:00:99"):
            self.assertIsNone(builder.clock_seconds(value))

    def test_loop_progress_respects_prior_visits(self):
        points = [(-22.0, -43.0), (-22.0, -42.999), (-21.999, -42.999), (-22.0, -43.0)]
        cumulative = [0]
        for a, b in zip(points, points[1:]):
            cumulative.append(cumulative[-1] + builder.distance(a, b))
        first = builder.projection(points[0], points, cumulative)
        last = builder.projection(points[0], points, cumulative, cumulative[2])
        self.assertAlmostEqual(first[0], 0)
        self.assertAlmostEqual(last[0], cumulative[-1])
        self.assertGreater(last[0], first[0])

    def test_bad_gtfs_distance_falls_back(self):
        shape = builder.shape_info([(0, -22.0, -43.0, 0), (1, -22.0, -42.999, 1)])
        self.assertIsNone(shape["sourceDistances"])
        visits = [(0, "a", 0, 0, 0), (1, "b", 60, 60, 1)]
        stops = {"a": {"latitude": -22.0, "longitude": -43.0}, "b": {"latitude": -22.0, "longitude": -42.999}}
        progress, errors, method, _ = builder.stop_distances(visits, shape, stops)
        self.assertEqual(method, "monotonic-projection")
        self.assertGreater(progress[1], 100)
        self.assertLess(max(errors), 0.1)

    def test_source_distance_calibrates_to_quantized_geometry(self):
        points = [(-22.000006, -43), (-22.000006, -42.999)]
        geometric = builder.distance(points[0], points[1])
        shape = builder.shape_info([(0, *points[0], 0), (1, *points[1], geometric * 1.01)])
        visits = [(0, "a", 0, 0, 0), (1, "b", 60, 60, geometric * 1.01)]
        stops = {"a": {"latitude": points[0][0], "longitude": points[0][1]}, "b": {"latitude": points[1][0], "longitude": points[1][1]}}
        progress, _, method, _ = builder.stop_distances(visits, shape, stops)
        self.assertEqual(method, "gtfs-calibrated")
        self.assertAlmostEqual(progress[-1], shape["distances"][-1], places=2)

    def test_fallback_loop_ambiguity_is_flagged(self):
        points = [(-22.0, -43.0), (-22.0, -42.99), (-21.99, -42.99), (-22.0, -43.0)]
        shape = builder.shape_info([(index, *point, None) for index, point in enumerate(points)])
        visits = [(0, "a", 0, 0, None), (1, "b", 600, 600, None), (2, "a", 1200, 1200, None)]
        stops = {"a": {"latitude": -22.0, "longitude": -43.0}, "b": {"latitude": -21.99, "longitude": -42.99}}
        progress, _, method, ambiguous = builder.stop_distances(visits, shape, stops)
        self.assertEqual(method, "monotonic-projection")
        self.assertTrue(ambiguous[0])
        self.assertGreater(progress[-1], progress[0])


class ConverterTests(unittest.TestCase):
    def test_unordered_rows_loops_variants_and_unused_route(self):
        tables = {
            "agency.txt": [["agency_id", "agency_name"], ["local", "Ônibus de teste"]],
            "routes.txt": [["route_id", "agency_id", "route_short_name", "route_long_name", "route_color"], ["r", "local", "397", "Praça - Estação", "15ABCD"], ["unused", "local", "SR397", "Linha sem viagens", ""]],
            "stops.txt": [["stop_id", "stop_name", "stop_lat", "stop_lon"], ["a", "Início", -22.0, -43.0], ["b", "Meio", -22.0, -42.999], ["c", "Retorno", -21.999, -42.999]],
            "shapes.txt": [["shape_id", "shape_pt_sequence", "shape_pt_lat", "shape_pt_lon", "shape_dist_traveled"], ["loop", 0, -22.0, -43.0, ""], ["loop", 1, -22.0, -42.999, ""], ["loop", 2, -21.999, -42.999, ""], ["loop", 3, -22.0, -43.0, ""]],
            "trips.txt": [["trip_id", "route_id", "direction_id", "shape_id", "trip_headsign"], ["t1", "r", 0, "loop", "Circular"], ["t2", "r", 0, "loop", "Circular"], ["express", "r", 0, "loop", "Circular"]],
            "stop_times.txt": [["trip_id", "stop_sequence", "stop_id", "arrival_time", "departure_time", "shape_dist_traveled"],
                ["t2", 3, "a", "11:06:00", "11:06:00", ""], ["t1", 1, "b", "10:02:00", "10:02:00", ""],
                ["express", 1, "c", "12:03:00", "12:03:00", ""], ["t1", 0, "a", "10:00:00", "10:00:00", ""],
                ["t2", 0, "a", "11:00:00", "11:00:00", ""], ["t1", 2, "c", "10:04:00", "10:04:00", ""],
                ["t2", 1, "b", "11:02:00", "11:02:00", ""], ["express", 0, "a", "12:00:00", "12:00:00", ""],
                ["t1", 3, "a", "10:06:00", "10:06:00", ""], ["express", 2, "a", "12:06:00", "12:06:00", ""],
                ["t2", 2, "c", "11:04:00", "11:04:00", ""]],
            "feed_info.txt": [["feed_start_date", "feed_end_date"], ["20260101", "20261231"]]
        }
        with tempfile.TemporaryDirectory() as temp:
            source, target = pathlib.Path(temp) / "input.zip", pathlib.Path(temp) / "catalog.json"
            with zipfile.ZipFile(source, "w") as archive:
                for name, rows in tables.items():
                    stream = io.StringIO(newline="")
                    csv.writer(stream).writerows(rows)
                    archive.writestr(name, stream.getvalue().encode("utf-8"))
            audit = builder.build(source, target)
            catalog = json.loads(target.read_text(encoding="utf-8"))
        self.assertEqual(audit["counts"]["routes"], 2)
        self.assertEqual(audit["counts"]["routesWithoutPatterns"], 1)
        self.assertEqual(audit["counts"]["patterns"], 2)
        self.assertEqual(audit["counts"]["patternsWithRepeatedStops"], 2)
        self.assertEqual(catalog["tripPatterns"]["t1"], catalog["tripPatterns"]["t2"])
        self.assertNotEqual(catalog["tripPatterns"]["t1"], catalog["tripPatterns"]["express"])
        loop = next(p for p in catalog["patterns"] if p["tripCount"] == 2)
        self.assertEqual([v["stopID"] for v in loop["stops"]], ["a", "b", "c", "a"])
        self.assertEqual([v["scheduledOffset"] for v in loop["stops"]], [0, 120, 240, 360])
        self.assertGreater(loop["stops"][-1]["distance"], loop["stops"][0]["distance"])
        self.assertFalse(loop["stops"][0]["distanceReliable"])


class WholeCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CATALOG.exists():
            raise unittest.SkipTest("Build the catalog first for whole-feed tests")
        cls.catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        cls.routes = {r["id"]: r for r in cls.catalog["routes"]}
        cls.patterns = {p["id"]: p for p in cls.catalog["patterns"]}
        cls.stops = {s["id"]: s for s in cls.catalog["stops"]}
        cls.audit = json.loads(CATALOG.with_name("catalog-audit.json").read_text(encoding="utf-8"))

    def test_schema_and_unique_identifiers(self):
        self.assertEqual(self.catalog["schemaVersion"], 1)
        for collection, indexed in (("routes", self.routes), ("patterns", self.patterns), ("stops", self.stops)):
            self.assertEqual(len(self.catalog[collection]), len(indexed))
        self.assertEqual(self.catalog["sourceURL"], builder.SOURCE_URL)

    def test_complete_official_catalog(self):
        if SOURCE is None:
            self.skipTest("Supply --source for independent input/output coverage comparison")
        with zipfile.ZipFile(SOURCE) as archive:
            source_routes = {r["route_id"] for r in builder.csv_rows(archive, "routes.txt")}
            source_stops = {r["stop_id"] for r in builder.csv_rows(archive, "stops.txt")}
            source_trips = {r["trip_id"]: r for r in builder.csv_rows(archive, "trips.txt")}
        self.assertEqual(source_routes, set(self.routes))
        self.assertEqual(source_stops, set(self.stops))
        self.assertEqual(set(source_trips), set(self.catalog["tripPatterns"]))
        for trip_id, pattern_id in self.catalog["tripPatterns"].items():
            self.assertEqual(source_trips[trip_id]["route_id"], self.patterns[pattern_id]["routeID"])
            self.assertEqual(source_trips[trip_id]["shape_id"], self.patterns[pattern_id]["shapeID"])

    def test_sample_lines_and_accents(self):
        samples = {route["shortName"]: route for route in self.routes.values() if route["shortName"] in ("369", "397", "SR397")}
        self.assertEqual(set(samples), {"369", "397", "SR397"})
        self.assertEqual(len({route["id"] for route in samples.values()}), 3)
        self.assertTrue(all(route["patternIDs"] for route in samples.values()))
        self.assertTrue(any(route["mode"] == "brt" and route["shortName"] == "10" for route in self.routes.values()))
        self.assertTrue(any("Candelária" in route["longName"] for route in samples.values()))
        self.assertFalse(any("\ufffd" in route["longName"] for route in self.routes.values()))

    def test_geometry_monotonic_distances_and_stop_sequences(self):
        loop_patterns = 0
        for pattern in self.patterns.values():
            points = builder.decode_polyline(pattern["polyline"])
            self.assertGreaterEqual(len(points), 2)
            cumulative = [0.0]
            for a, b in zip(points, points[1:]):
                cumulative.append(cumulative[-1] + builder.distance(a, b))
            visits = pattern["stops"]
            self.assertTrue(visits)
            self.assertEqual(sorted({v["sequence"] for v in visits}), [v["sequence"] for v in visits])
            self.assertEqual(sorted(v["distance"] for v in visits), [v["distance"] for v in visits])
            self.assertGreaterEqual(visits[0]["distance"], 0)
            self.assertLessEqual(visits[-1]["distance"], cumulative[-1] + 0.02)
            for visit in visits:
                self.assertIn(visit["stopID"], self.stops)
                self.assertIsInstance(visit["distanceReliable"], bool)
                if visit["distanceReliable"]:
                    stop = self.stops[visit["stopID"]]
                    point = builder.interpolate(visit["distance"], cumulative, points)
                    self.assertLessEqual(builder.distance(point, (stop["latitude"], stop["longitude"])), 100.1)
            if len({v["stopID"] for v in visits}) < len(visits):
                loop_patterns += 1
        self.assertEqual(loop_patterns, self.audit["counts"]["patternsWithRepeatedStops"])

    def test_trip_pattern_counts_and_route_membership(self):
        counter = collections.Counter(self.catalog["tripPatterns"].values())
        for pattern in self.patterns.values():
            self.assertEqual(counter[pattern["id"]], pattern["tripCount"])
            self.assertIn(pattern["id"], self.routes[pattern["routeID"]]["patternIDs"])
        for route in self.routes.values():
            self.assertEqual(len(route["patternIDs"]), len(set(route["patternIDs"])))
            for identity in route["patternIDs"]:
                self.assertEqual(self.patterns[identity]["routeID"], route["id"])

    def test_unreliable_stop_visits_are_explicit(self):
        actual = sum(not v["distanceReliable"] for p in self.patterns.values() for v in p["stops"])
        self.assertEqual(actual, self.audit["counts"]["unreliableStopVisits"])
        for pattern in self.audit["patternsNeedingReview"]:
            visits = self.patterns[pattern["patternID"]]["stops"]
            for sequence in pattern["stopSequences"]:
                self.assertFalse(next(v for v in visits if v["sequence"] == sequence)["distanceReliable"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=pathlib.Path, default=CATALOG)
    parser.add_argument("--source", type=pathlib.Path)
    args, remaining = parser.parse_known_args()
    CATALOG, SOURCE = args.catalog, args.source
    unittest.main(argv=[__file__] + remaining, verbosity=2)
