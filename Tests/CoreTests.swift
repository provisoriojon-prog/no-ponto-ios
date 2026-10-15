import Foundation

/// swiftc -O NoPonto/Models.swift NoPonto/Core/*.swift Tests/CoreTests.swift -o core-tests
/// ./core-tests [official-onibus-snapshot.pb official-brt-snapshot.pb [catalog.json]]
/// Deterministic tests never require a live server; recorded official feeds are an optional separate pass.
@main
struct CoreTests {
    private static var checks = 0
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let metersPerDegree = TransitGeometry.earthRadius * Double.pi / 180

    static func main() throws {
        try parserTests()
        geometryTests()
        engineTests()
        if CommandLine.arguments.count >= 3 {
            try officialTests(busPath: CommandLine.arguments[1], brtPath: CommandLine.arguments[2],
                              catalogPath: CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil)
        }
        print("PASS: \(checks) verificações do núcleo No Ponto")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else { fatalError("FAIL: \(message)") }
    }
    private static func near(_ a: Double, _ b: Double, tolerance: Double = 1) -> Bool { abs(a - b) <= tolerance }
    private static func checkThrows(_ message: String, _ closure: () throws -> Void) {
        checks += 1
        do { try closure(); fatalError("FAIL: \(message)") } catch { }
    }

    private static func parserTests() throws {
        let stamp: UInt64 = 1_800_000_000
        let original = feed([entity(id: "e1", vehicleID: "A100", latitude: -22.9, longitude: -43.2, timestamp: stamp)], timestamp: stamp + 8)
        let batch = try GTFSRealtime.decode(Data(original), source: "onibus", fetchedAt: now)
        check(batch.vehicles.count == 1, "decode valid position")
        let vehicle = batch.vehicles[0]
        check(vehicle.id == "onibus:A100" && vehicle.vehicleID == "A100", "stable source-qualified vehicle identity")
        check(vehicle.routeID == "R369" && vehicle.tripID == "t-out" && vehicle.direction == 0, "GTFS TripDescriptor field numbers")
        check(vehicle.bearing == 90 && vehicle.speed == 10, "protobuf fixed32 positions")
        check(near(vehicle.latitude, -22.9, tolerance: 0.00001), "float32 latitude")
        check(vehicle.timestamp == now && batch.feedTimestamp == now.addingTimeInterval(8), "individual timestamp distinct from feed timestamp")
        check(vehicle.isFresh(at: now), "current GPS is fresh")

        let noTime = try GTFSRealtime.decode(Data(feed([entity(id: "x", timestamp: nil)])), source: "onibus", fetchedAt: now)
        check(noTime.vehicles[0].timestamp == nil, "never substitute feed receipt for GPS timestamp")
        let future = try GTFSRealtime.decode(Data(feed([entity(id: "x", timestamp: stamp + 60)])), source: "onibus", fetchedAt: now)
        check(!future.vehicles[0].isFresh(at: now), "future GPS rejected for arrivals")
        let invalid = try GTFSRealtime.decode(Data(feed([entity(id: "bad", latitude: .nan), entity(id: "outside", latitude: 91)])), source: "onibus", fetchedAt: now)
        check(invalid.vehicles.isEmpty && !invalid.issues.isEmpty, "reject invalid coordinate records with diagnostics")
        let duplicated = try GTFSRealtime.decode(Data(feed([entity(id: "x", vehicleID: "A", timestamp: stamp), entity(id: "y", vehicleID: "A", timestamp: stamp - 20)])), source: "onibus", fetchedAt: now)
        check(duplicated.vehicles.count == 1 && duplicated.vehicles[0].timestamp == now, "deduplicate by newest vehicle timestamp")
        check(!duplicated.issues.isEmpty, "duplicate diagnostic")
        let deleted = integer(2, 1) + bytes(4, [])
        let deletedBatch = try GTFSRealtime.decode(Data(feed([deleted])), source: "onibus", fetchedAt: now)
        check(deletedBatch.vehicles.isEmpty, "deleted entity ignored")
        let unknowns = integer(90, 42) + bytes(91, [1, 2, 3]) + key(92, 1) + Array(repeating: UInt8(0), count: 8) + fixed(93, 0)
        let forward = try GTFSRealtime.decode(Data(original + unknowns), source: "onibus", fetchedAt: now)
        check(forward.vehicles.count == 1, "ignore future varint/bytes/fixed32/fixed64 fields")
        let corruptEntity = try GTFSRealtime.decode(Data(feed([[0x80], entity(id: "good")])), source: "onibus", fetchedAt: now)
        check(corruptEntity.vehicles.count == 1 && !corruptEntity.issues.isEmpty, "one malformed entity cannot erase healthy entities")
        checkThrows("empty protobuf rejected") { _ = try GTFSRealtime.decode(Data(), source: "bus", fetchedAt: now) }
        checkThrows("truncated varint rejected") { _ = try GTFSRealtime.decode(Data([0x80]), source: "bus", fetchedAt: now) }
        checkThrows("overflow varint rejected") { _ = try GTFSRealtime.decode(Data(Array(repeating: 0xff, count: 10)), source: "bus", fetchedAt: now) }
        checkThrows("truncated payload rejected") { _ = try GTFSRealtime.decode(Data([0x0a, 0x7f, 0]), source: "bus", fetchedAt: now) }
        checkThrows("wire type rejected") { _ = try GTFSRealtime.decode(Data([0x0f]), source: "bus", fetchedAt: now) }
        checkThrows("header required") { _ = try GTFSRealtime.decode(Data(bytes(2, entity(id: "x"))), source: "bus", fetchedAt: now) }
        checkThrows("differential never treated as full snapshot") { _ = try GTFSRealtime.decode(Data(bytes(1, string(1, "2.0") + integer(2, 1))), source: "bus", fetchedAt: now) }
        let missingPosition = bytes(4, bytes(1, string(5, "R369")))
        let noPosition = try GTFSRealtime.decode(Data(feed([missingPosition])), source: "bus", fetchedAt: now)
        check(noPosition.vehicles.isEmpty, "missing coordinates not silently decoded as zero-zero")
    }

    private static func geometryTests() {
        let point = GeoPoint(latitude: 0, longitude: 0)
        check(near(TransitGeometry.distance(point, GeoPoint(latitude: 0, longitude: 1)), 111_194.9266, tolerance: 0.01), "haversine units meters")
        check(near(TransitGeometry.bearing(point, GeoPoint(latitude: 0, longitude: 1)), 90, tolerance: 0.01), "east bearing")
        check(near(TransitGeometry.angleDifference(359, 1), 2), "bearing wraps north")
        let decoded = TransitGeometry.decodePolyline("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        check(decoded.count == 3 && near(decoded[2].longitude, -126.453, tolerance: 0.000001), "standard precision5 polyline")
        check(TransitGeometry.decodePolyline("_p~iF~ps|U_").isEmpty, "partial shape rejected")
        check(TransitGeometry.decodePolyline("\u{0000}").isEmpty, "invalid polyline byte rejected")
        let route = [coordinate(0), coordinate(1_000), coordinate(2_000)]
        let projection = TransitGeometry.project(GeoPoint(latitude: 0.0001, longitude: coordinate(1_200).longitude), onto: route)!
        check(near(projection.progress, 1_200, tolerance: 0.5), "along-route projection distance")
        check(near(projection.distance, 11.119, tolerance: 0.1), "cross-track distance")
        check(TransitGeometry.project(point, onto: [point, point]) == nil, "degenerate geometry")
        check(TransitGeometry.project(GeoPoint(latitude: .nan, longitude: 0), onto: route) == nil, "NaN location cannot project")
        let dateLine = TransitGeometry.project(GeoPoint(latitude: 0, longitude: 180), onto: [GeoPoint(latitude: 0, longitude: 179.999), GeoPoint(latitude: 0, longitude: -179.999)])!
        check(dateLine.distance < 0.01 && near(dateLine.progress, 111.195, tolerance: 0.5), "dateline projection")
    }

    private static func engineTests() {
        let standard = catalog()
        let engine = TransitEngine(catalog: standard)
        let initial = vehicle(progress: 500, seconds: -90)
        check(engine.match(initial)?.certainty == .exactTrip, "exact trip verified spatially")
        var offRoute = initial; offRoute.latitude = 0.02
        check(engine.match(offRoute) == nil, "exact trip not trusted offroute")
        var wrongRoute = initial; wrongRoute.routeID = "OTHER"
        check(engine.match(wrongRoute) == nil, "exact trip cannot override conflicting route")
        var wrongDirection = initial; wrongDirection.direction = 1
        check(engine.match(wrongDirection) == nil, "exact trip cannot override conflicting direction")
        var backwards = initial; backwards.bearing = 270
        check(engine.match(backwards) == nil, "opposing observed bearing rejected")
        var unknown = initial; unknown.tripID = "missing-from-catalog"
        check(engine.match(unknown)?.certainty == .routeInferred, "missing trip ID allows spatially unique route/direction")
        unknown.routeID = "UNLISTED"
        check(engine.match(unknown) == nil, "unknown official route ID not guessed by a number substring")
        let firstOnly = TransitEngine(catalog: standard)
        let first = vehicle(progress: 500, seconds: 0)
        firstOnly.ingest([first], now: now)
        check(firstOnly.arrivals(patternID: "out", stopSequence: 20, vehicles: [first], now: now).first?.confidence == .unavailable, "one GPS sample is not ETA")
        firstOnly.ingest([first], now: now.addingTimeInterval(30))
        check(firstOnly.arrivals(patternID: "out", stopSequence: 20, vehicles: [first], now: now.addingTimeInterval(30)).first?.confidence == .unavailable, "repeated cached timestamp not movement")

        var last = initial
        for index in 0..<4 {
            last = vehicle(progress: 500 + Double(index) * 300, seconds: Double(index - 3) * 30)
            engine.ingest([last], now: last.timestamp!)
        }
        let arrival = engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [last], now: now).first!
        check(arrival.confidence == .good, "90s consistent exact-trip movement")
        check(arrival.secondsLower! >= 0 && arrival.secondsLower! < 60 && arrival.secondsUpper! > 60, "arrival is interval around observed 60s, not exact promise")
        check(near(arrival.distance!, 600, tolerance: 2), "remaining distance follows route")
        let delayed = engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [last], now: now.addingTimeInterval(121)).first!
        check(delayed.confidence == .unavailable && delayed.secondsLower == nil, "stale individual GPS unavailable")
        let future = engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [last], now: now.addingTimeInterval(-20)).first!
        check(future.confidence == .unavailable, "future individual GPS unavailable")
        var noTime = last; noTime.timestamp = nil
        check(engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [noTime], now: now).first?.confidence == .unavailable, "timestamp required for ETA")
        check(engine.arrivals(patternID: "out", stopSequence: 1, vehicles: [last], now: now).isEmpty, "already passed selected stop excluded")
        check(engine.arrivals(patternID: "back", stopSequence: 20, vehicles: [last], now: now).isEmpty, "opposite direction excluded")
        check(engine.arrivals(patternID: "out", stopSequence: 999, vehicles: [last], now: now).isEmpty, "missing stop sequence handled")

        let short = TransitEngine(catalog: standard)
        let v0 = vehicle(progress: 500, seconds: -30), v1 = vehicle(progress: 800, seconds: 0)
        short.ingest([v0], now: now.addingTimeInterval(-30)); short.ingest([v1], now: now)
        check(short.arrivals(patternID: "out", stopSequence: 20, vehicles: [v1], now: now).first?.confidence == .limited, "two observations yield only broad limited ETA")
        let stopped = vehicle(progress: 800, seconds: 30)
        short.ingest([stopped], now: now.addingTimeInterval(30))
        check(short.arrivals(patternID: "out", stopSequence: 20, vehicles: [stopped], now: now.addingTimeInterval(30)).first?.confidence == .unavailable, "latest stopped interval cannot reuse older moving speed")
        let teleport = TransitEngine(catalog: standard)
        teleport.ingest([vehicle(progress: 0, seconds: -30)], now: now.addingTimeInterval(-30))
        let jump = vehicle(progress: 1_800, seconds: 0)
        teleport.ingest([jump], now: now)
        check(teleport.arrivals(patternID: "out", stopSequence: 30, vehicles: [jump], now: now).first?.reason.contains("Salto") == true, "teleport quarantined")

        var ambiguousCatalog = standard
        var variant = ambiguousCatalog.patterns[0]; variant.id = "express"; variant.stops.remove(at: 1)
        ambiguousCatalog.patterns.append(variant)
        let ambiguous = TransitEngine(catalog: ambiguousCatalog)
        var inferred = first; inferred.tripID = "unknown"
        check(ambiguous.match(inferred) == nil, "same geometry different stop variants never guessed")
        check(ambiguous.match(first)?.patternID == "out", "exact trip resolves variants only after geometry check")

        var badStopCatalog = standard
        badStopCatalog.patterns[0].stops[1].distanceReliable = false
        let badStop = TransitEngine(catalog: badStopCatalog)
        check(badStop.arrivals(patternID: "out", stopSequence: 20, vehicles: [first], now: now).first?.reason.contains("Ponto") == true, "unreliable stop projection blocks arrival")
        var repeatedCatalog = standard
        repeatedCatalog.patterns[0].stops[2].stopID = "s1"
        let repeated = TransitEngine(catalog: repeatedCatalog)
        check(repeated.arrivals(patternID: "out", stopSequence: 1, vehicles: [last], now: now).isEmpty, "first occurrence of repeated stop already passed")
        check(!repeated.arrivals(patternID: "out", stopSequence: 30, vehicles: [last], now: now).isEmpty, "later visit to same stop distinguished by stop sequence")
        var loopCatalog = standard
        loopCatalog.patterns[0].polyline = encode([coordinate(0), coordinate(1_000), GeoPoint(latitude: 0.01, longitude: coordinate(1_000).longitude), GeoPoint(latitude: 0.01, longitude: 0), coordinate(0), coordinate(1_000)])
        check(TransitEngine(catalog: loopCatalog).match(first) == nil, "repeated same-direction segment ambiguous without visit history")
        var sortedVehicle = last; sortedVehicle.id = "onibus:old"; sortedVehicle.timestamp = now.addingTimeInterval(-200)
        let sorted = engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [sortedVehicle, last], now: now)
        check(sorted.first?.vehicleID == last.id && sorted.last?.confidence == .unavailable, "available estimates precede stale signals")
        var conflict = last; conflict.longitude = coordinate(1_600).longitude
        engine.ingest([conflict], now: now)
        check(engine.arrivals(patternID: "out", stopSequence: 20, vehicles: [conflict], now: now).first?.confidence == .unavailable, "conflicting coordinates at same timestamp invalidate prediction")
    }

    private static func officialTests(busPath: String, brtPath: String, catalogPath: String?) throws {
        let bus = try GTFSRealtime.decode(Data(contentsOf: URL(fileURLWithPath: busPath)), source: "onibus", fetchedAt: now)
        let brt = try GTFSRealtime.decode(Data(contentsOf: URL(fileURLWithPath: brtPath)), source: "brt", fetchedAt: now)
        check(!bus.vehicles.isEmpty && !brt.vehicles.isEmpty, "recorded official municipal and BRT feeds decode")
        check(bus.vehicles.allSatisfy { $0.coordinate.isValid && $0.id.hasPrefix("onibus:") }, "official bus coordinates and namespace")
        check(brt.vehicles.allSatisfy { $0.coordinate.isValid && $0.id.hasPrefix("brt:") }, "official BRT coordinates and namespace")
        check(bus.feedTimestamp != nil && brt.feedTimestamp != nil, "official feed timestamps")
        print("OFFICIAL FIXTURES: bus=\(bus.vehicles.count), brt=\(brt.vehicles.count), diagnostics=\(bus.issues + brt.issues)")
        if let catalogPath = catalogPath {
            let realCatalog = try JSONDecoder().decode(TransitCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: catalogPath)))
            let engine = TransitEngine(catalog: realCatalog)
            let matched = (bus.vehicles + brt.vehicles).compactMap { engine.match($0) }
            check(!matched.isEmpty, "real vehicles spatially match official catalog")
            check(matched.allSatisfy { $0.distanceFromRoute <= 100 && $0.progress >= 0 }, "real matched positions satisfy geometry gate")
            let exact = matched.filter { $0.certainty == .exactTrip }.count
            print("OFFICIAL MATCHING: matched=\(matched.count), exact=\(exact), inferred=\(matched.count - exact); remaining deliberately unresolved")
        }
    }

    private static func coordinate(_ progress: Double) -> GeoPoint { GeoPoint(latitude: 0, longitude: progress / metersPerDegree) }
    private static func vehicle(progress: Double, seconds: Double) -> TransitVehicle {
        TransitVehicle(id: "onibus:A", vehicleID: "A", label: "A", source: "onibus", routeID: "R369", tripID: "t-out", direction: 0,
                       latitude: 0, longitude: coordinate(progress).longitude, bearing: 90, speed: 10, timestamp: now.addingTimeInterval(seconds))
    }
    private static func catalog() -> TransitCatalog {
        let out = TransitPattern(id: "out", routeID: "R369", direction: 0, headsign: "Centro", shapeID: "shape-out",
                                 polyline: encode([coordinate(0), coordinate(2_000), coordinate(4_000)]),
                                 stops: [StopVisit(stopID: "s1", sequence: 1, distance: 0, scheduledOffset: nil), StopVisit(stopID: "s2", sequence: 20, distance: 2_000, scheduledOffset: nil), StopVisit(stopID: "s3", sequence: 30, distance: 4_000, scheduledOffset: nil)], tripCount: 1)
        let back = TransitPattern(id: "back", routeID: "R369", direction: 1, headsign: "Bairro", shapeID: "shape-back",
                                  polyline: encode([coordinate(4_000), coordinate(2_000), coordinate(0)]), stops: out.stops, tripCount: 1)
        return TransitCatalog(schemaVersion: 1, generatedAt: "2026-10-15", sourceModified: "2026-10-15", sourceURL: "fixture://deterministic", validFrom: "20260101", validUntil: "20261231",
                              routes: [TransitRoute(id: "R369", shortName: "369", longName: "Bairro – Centro", agency: "Teste", mode: "bus", color: "0055AA", patternIDs: ["out", "back"])], stops: [], patterns: [out, back], tripPatterns: ["t-out": "out", "t-back": "back"])
    }
    private static func encode(_ points: [GeoPoint]) -> String {
        var bytes: [UInt8] = [], previous = [Int64(0), Int64(0)]
        for point in points {
            for (index, coordinate) in [point.latitude, point.longitude].enumerated() {
                let value = Int64((coordinate * 100_000).rounded()), delta = value - previous[index]
                previous[index] = value
                var encoded = delta < 0 ? ~(delta << 1) : delta << 1
                while encoded >= 32 { bytes.append(UInt8((encoded & 31) | 32) + 63); encoded >>= 5 }
                bytes.append(UInt8(encoded) + 63)
            }
        }
        return String(bytes: bytes, encoding: .utf8)!
    }
    private static func varint(_ input: UInt64) -> [UInt8] {
        var number = input, output: [UInt8] = []
        while number >= 128 { output.append(UInt8(number & 127) | 128); number >>= 7 }
        output.append(UInt8(number)); return output
    }
    private static func key(_ field: Int, _ wire: Int) -> [UInt8] { varint(UInt64(field * 8 + wire)) }
    private static func integer(_ field: Int, _ value: UInt64) -> [UInt8] { key(field, 0) + varint(value) }
    private static func bytes(_ field: Int, _ value: [UInt8]) -> [UInt8] { key(field, 2) + varint(UInt64(value.count)) + value }
    private static func string(_ field: Int, _ value: String) -> [UInt8] { bytes(field, Array(value.utf8)) }
    private static func fixed(_ field: Int, _ value: Float) -> [UInt8] {
        let bits = value.bitPattern
        return key(field, 5) + (0..<4).map { UInt8((bits >> ($0 * 8)) & 255) }
    }
    private static func entity(id: String, vehicleID: String? = nil, latitude: Float = -22.9, longitude: Float = -43.2, timestamp: UInt64? = 1_800_000_000) -> [UInt8] {
        let trip = string(1, "t-out") + string(5, "R369") + integer(6, 0)
        let position = fixed(1, latitude) + fixed(2, longitude) + fixed(3, 90) + fixed(5, 10)
        var vehicle = bytes(1, trip) + bytes(2, position) + bytes(8, string(1, vehicleID ?? id) + string(2, "Ônibus"))
        if let timestamp = timestamp { vehicle += integer(5, timestamp) }
        return string(1, id) + bytes(4, vehicle)
    }
    private static func feed(_ entities: [[UInt8]], timestamp: UInt64 = 1_800_000_000) -> [UInt8] {
        bytes(1, string(1, "2.0") + integer(3, timestamp)) + entities.flatMap { bytes(2, $0) }
    }
}
