import Foundation

/// Pure Foundation journey matching and conservative local arrival estimates.
/// Call from one actor (the store's MainActor). No network, timers or location retention on disk.
final class TransitEngine {
    private let catalog: TransitCatalog
    private let patternsByID: [String: TransitPattern]
    private let patternsByRoute: [String: [TransitPattern]]
    private var shapes: [String: TransitGeometry.PreparedPolyline] = [:]
    private var history: [String: [TransitVehicle]] = [:]
    private var quarantinedUntil: [String: Date] = [:]
    private let maximumRouteDistance = 100.0

    init(catalog: TransitCatalog) {
        self.catalog = catalog
        // Keep the first record for duplicate IDs; remote data must not crash Dictionary initialization.
        patternsByID = Dictionary(catalog.patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        patternsByRoute = Dictionary(grouping: catalog.patterns, by: \.routeID)
        var preparedByShape: [String: (String, TransitGeometry.PreparedPolyline)] = [:]
        for pattern in catalog.patterns {
            if shapes[pattern.id] == nil {
                if let cached = preparedByShape[pattern.shapeID], cached.0 == pattern.polyline {
                    shapes[pattern.id] = cached.1
                } else {
                    let prepared = TransitGeometry.PreparedPolyline(TransitGeometry.decodePolyline(pattern.polyline))
                    preparedByShape[pattern.shapeID] = (pattern.polyline, prepared)
                    shapes[pattern.id] = prepared
                }
            }
        }
    }

    func ingest(_ vehicles: [TransitVehicle], now: Date) {
        let cutoff = now.addingTimeInterval(-360)
        history = history.filter { ($0.value.last?.timestamp ?? .distantPast) >= cutoff }
        quarantinedUntil = quarantinedUntil.filter { $0.value > now }
        for vehicle in vehicles where vehicle.coordinate.isValid && vehicle.isFresh(at: now) {
            guard let timestamp = vehicle.timestamp else { continue }
            var samples = history[vehicle.id] ?? []
            if let previous = samples.last {
                if !sameJourney(previous, vehicle) {
                    samples.removeAll()
                } else if let previousTime = previous.timestamp {
                    let delta = timestamp.timeIntervalSince(previousTime)
                    if delta < 0 { continue }
                    let traveled = TransitGeometry.distance(previous.coordinate, vehicle.coordinate)
                    if delta == 0 {
                        if traveled > 30 { quarantinedUntil[vehicle.id] = now.addingTimeInterval(90) }
                        continue // Cached feeds are not additional movement observations.
                    }
                    if traveled / delta > 45 {
                        samples.removeAll()
                        quarantinedUntil[vehicle.id] = now.addingTimeInterval(90)
                    }
                }
            }
            samples.append(vehicle)
            samples = Array(samples.filter { ($0.timestamp ?? .distantPast) >= cutoff }.suffix(12))
            history[vehicle.id] = samples
        }
        if history.count > 10_000 {
            let retained = history.sorted { ($0.value.last?.timestamp ?? .distantPast) > ($1.value.last?.timestamp ?? .distantPast) }.prefix(10_000)
            history = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }
    }

    func match(_ vehicle: TransitVehicle) -> VehicleMatch? {
        guard vehicle.coordinate.isValid else { return nil }
        if let tripID = vehicle.tripID, let patternID = catalog.tripPatterns[tripID], let pattern = patternsByID[patternID] {
            guard vehicle.routeID.isEmpty || pattern.routeID == vehicle.routeID,
                  vehicle.direction == nil || vehicle.direction == pattern.direction,
                  let projection = projection(vehicle, patternID: pattern.id) else { return nil }
            return VehicleMatch(patternID: pattern.id, progress: projection.progress,
                                distanceFromRoute: projection.distance, certainty: .exactTrip,
                                reason: "Viagem do catálogo; posição conferida no trajeto")
        }
        // Do not strip suffixes or guess a public route from an unknown provider identifier.
        let candidates = (patternsByRoute[vehicle.routeID] ?? []).filter {
            vehicle.direction == nil || vehicle.direction == $0.direction
        }
        var matches: [(TransitPattern, RouteProjection)] = []
        for pattern in candidates {
            if let position = projection(vehicle, patternID: pattern.id) { matches.append((pattern, position)) }
        }
        let heading = movementBearing(vehicle)
        func score(_ projection: RouteProjection) -> Double {
            projection.distance + (heading.map { TransitGeometry.angleDifference($0, projection.bearing) * 0.35 } ?? 0)
        }
        matches.sort { score($0.1) < score($1.1) }
        guard let best = matches.first else { return nil }
        // Shared road sections cannot tell an express, short turn or branch from the full route.
        if matches.dropFirst().contains(where: { score($0.1) - score(best.1) < 35 }) { return nil }
        return VehicleMatch(patternID: best.0.id, progress: best.1.progress,
                            distanceFromRoute: best.1.distance, certainty: .routeInferred,
                            reason: "Trajeto provável pela linha, sentido e posição; viagem não encontrada no catálogo")
    }

    func arrivals(patternID: String, stopSequence: Int, vehicles: [TransitVehicle], now: Date) -> [ArrivalEstimate] {
        guard let pattern = patternsByID[patternID],
              let visit = pattern.stops.first(where: { $0.sequence == stopSequence }) else { return [] }
        var estimates: [ArrivalEstimate] = []
        for vehicle in vehicles {
            let tripPatternID = vehicle.tripID.flatMap { catalog.tripPatterns[$0] }
            guard vehicle.routeID == pattern.routeID || (vehicle.routeID.isEmpty && tripPatternID == patternID),
                  vehicle.direction == nil || vehicle.direction == pattern.direction else { continue }
            // An exact different variant must not appear as serving the selected pattern's stop.
            if let tripPatternID = tripPatternID, tripPatternID != patternID { continue }
            let age = vehicle.age(at: now)
            func unavailable(_ reason: String, distance: Double? = nil) -> ArrivalEstimate {
                ArrivalEstimate(vehicleID: vehicle.id, routeID: pattern.routeID, patternID: pattern.id,
                                stopID: visit.stopID, stopSequence: visit.sequence,
                                secondsLower: nil, secondsUpper: nil, confidence: .unavailable,
                                reason: reason, distance: distance, positionAge: age)
            }
            guard let age = age else { estimates.append(unavailable("Posição sem horário de GPS")); continue }
            guard age >= -15 else { estimates.append(unavailable("Relógio do GPS adiantado; aguardando posição válida")); continue }
            guard age <= 120 else { estimates.append(unavailable("Sinal antigo; chegada indisponível")); continue }
            guard visit.distanceReliable, visit.distance.isFinite, visit.distance >= 0,
                  let shape = shapes[patternID], visit.distance <= shape.length + 30 else {
                estimates.append(unavailable("Ponto sem posição confiável neste trajeto")); continue
            }
            if let until = quarantinedUntil[vehicle.id], until > now {
                estimates.append(unavailable("Salto no GPS; aguardando novas posições consistentes")); continue
            }
            guard let matched = match(vehicle) else {
                estimates.append(unavailable("Trajeto ou sentido ainda não confirmado")); continue
            }
            guard matched.patternID == patternID else { continue }
            let remaining = visit.distance - matched.progress
            guard remaining >= -25 else { continue } // Already passed this visit, including repeated stop IDs.
            let distance = max(0, remaining)
            let observations = movementObservations(vehicle, patternID: patternID)
            guard observations.count >= 2, let first = observations.first, let last = observations.last,
                  last.time.timeIntervalSince(first.time) >= 30 else {
                estimates.append(unavailable("Calculando: aguardando movimento entre atualizações", distance: distance)); continue
            }
            var speeds: [Double] = []
            var invalid = false
            for index in 1..<observations.count {
                let elapsed = observations[index].time.timeIntervalSince(observations[index - 1].time)
                let progress = observations[index].progress - observations[index - 1].progress
                guard elapsed >= 5 else { continue }
                if progress < -35 || progress / elapsed > 40 { invalid = true; break }
                speeds.append(max(0, progress / elapsed))
            }
            guard !invalid, let latestSpeed = speeds.last, latestSpeed >= 0.6 else {
                estimates.append(unavailable(invalid ? "Movimento incompatível com o trajeto" : "Ônibus parado ou muito lento; aguardando movimento", distance: distance)); continue
            }
            let observedSpeed = median(speeds)
            guard observedSpeed >= 1, observedSpeed <= 35 else {
                estimates.append(unavailable("Movimento insuficiente para estimar a chegada", distance: distance)); continue
            }
            let base = distance / observedSpeed
            guard base <= 2_700 else {
                estimates.append(unavailable("Muito distante para estimar com este histórico curto", distance: distance)); continue
            }
            let span = last.time.timeIntervalSince(first.time)
            let dispersion = median(speeds.map { abs($0 - observedSpeed) }) / observedSpeed
            let reliable = matched.certainty == .exactTrip && observations.count >= 4 && span >= 90 &&
                age <= 45 && matched.distanceFromRoute <= 35 && dispersion <= 0.35 && base <= 600
            // Heuristic uncertainty bands, not calibrated probabilities or official TripUpdates.
            // Future dwell/congestion is unknown. The upper band leaves room for intermediate stops.
            let intermediateStops = pattern.stops.filter { $0.distance > matched.progress && $0.distance < visit.distance }.count
            let factor = reliable ? 0.7 : 0.5
            let lower = max(0, base * factor - max(0, age) - 15)
            let upper = max(lower + 45, base * (reliable ? 1.5 : 2.0) + max(0, age) + 45 + Double(min(15, intermediateStops)) * 20)
            let reason = reliable
                ? "Estimativa local pelo movimento recente; pode mudar com trânsito e paradas"
                : "Aproximação pelo movimento recente; histórico curto ou trajeto inferido"
            estimates.append(ArrivalEstimate(vehicleID: vehicle.id, routeID: pattern.routeID,
                                             patternID: pattern.id, stopID: visit.stopID, stopSequence: visit.sequence,
                                             secondsLower: lower, secondsUpper: upper,
                                             confidence: reliable ? .good : .limited, reason: reason,
                                             distance: distance, positionAge: age))
        }
        return estimates.sorted {
            let left = $0.secondsLower ?? .infinity, right = $1.secondsLower ?? .infinity
            if left != right { return left < right }
            let leftDistance = $0.distance ?? .infinity, rightDistance = $1.distance ?? .infinity
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return $0.vehicleID < $1.vehicleID
        }
    }

    private func sameJourney(_ a: TransitVehicle, _ b: TransitVehicle) -> Bool {
        a.routeID == b.routeID && a.tripID == b.tripID && a.direction == b.direction
    }

    private func previousSample(_ vehicle: TransitVehicle) -> TransitVehicle? {
        guard let timestamp = vehicle.timestamp else { return nil }
        return history[vehicle.id]?.last(where: {
            guard let time = $0.timestamp else { return false }
            let interval = timestamp.timeIntervalSince(time)
            return interval >= 5 && interval <= 120 && sameJourney($0, vehicle)
        })
    }

    private func movementBearing(_ vehicle: TransitVehicle) -> Double? {
        if let previous = previousSample(vehicle),
           TransitGeometry.distance(previous.coordinate, vehicle.coordinate) >= 20 {
            return TransitGeometry.bearing(previous.coordinate, vehicle.coordinate)
        }
        if let speed = vehicle.speed, speed >= 1.5, let bearing = vehicle.bearing,
           bearing.isFinite, (0...360).contains(bearing) { return bearing }
        return nil
    }

    private func projection(_ vehicle: TransitVehicle, patternID: String) -> RouteProjection? {
        guard let shape = shapes[patternID] else { return nil }
        let heading = movementBearing(vehicle)
        var prior: RouteProjection?
        var elapsed: Double?
        if let previous = previousSample(vehicle), let previousTime = previous.timestamp, let timestamp = vehicle.timestamp {
            // A spatially ambiguous prior observation cannot be used to manufacture continuity.
            prior = chooseProjection(previous.coordinate, shape: shape, heading: movementBearing(previous), prior: nil, elapsed: nil)
            elapsed = timestamp.timeIntervalSince(previousTime)
        }
        return chooseProjection(vehicle.coordinate, shape: shape, heading: heading, prior: prior, elapsed: elapsed)
    }

    private func chooseProjection(_ point: GeoPoint, shape: TransitGeometry.PreparedPolyline,
                                  heading: Double?, prior: RouteProjection?, elapsed: Double?) -> RouteProjection? {
        var candidates = shape.projections(point, within: maximumRouteDistance).filter { candidate in
            if let heading = heading, TransitGeometry.angleDifference(heading, candidate.bearing) > 100 { return false }
            if let prior = prior, let elapsed = elapsed, elapsed > 0 {
                let advance = candidate.progress - prior.progress
                if advance < -45 || advance > elapsed * 40 + 40 { return false }
            }
            return true
        }
        func score(_ candidate: RouteProjection) -> Double {
            candidate.distance + (heading.map { TransitGeometry.angleDifference($0, candidate.bearing) * 0.35 } ?? 0)
        }
        candidates.sort { score($0) < score($1) }
        guard let best = candidates.first else { return nil }
        // Crossings and repeated road segments can represent different visits on a loop.
        if candidates.dropFirst().contains(where: {
            abs($0.progress - best.progress) > 100 && score($0) - score(best) < 25
        }) { return nil }
        return best
    }

    private struct Observation { var time: Date; var progress: Double }
    private func movementObservations(_ vehicle: TransitVehicle, patternID: String) -> [Observation] {
        guard let timestamp = vehicle.timestamp else { return [] }
        let samples = (history[vehicle.id] ?? []).filter {
            guard let time = $0.timestamp else { return false }
            return sameJourney($0, vehicle) && time <= timestamp && timestamp.timeIntervalSince(time) <= 180
        }
        var result: [Observation] = []
        for sample in samples {
            guard let time = sample.timestamp, let position = projection(sample, patternID: patternID) else {
                result.removeAll() // Resume evidence only after an unresolved/offroute interval.
                continue
            }
            result.append(Observation(time: time, progress: position.progress))
        }
        // A caller's new position must correspond to the history that underlies the estimate.
        guard let last = samples.last, last.timestamp == vehicle.timestamp,
              TransitGeometry.distance(last.coordinate, vehicle.coordinate) < 10,
              result.last?.time == timestamp else { return [] }
        return result
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let values = values.sorted()
        let midpoint = values.count / 2
        return values.count % 2 == 0 ? (values[midpoint - 1] + values[midpoint]) / 2 : values[midpoint]
    }
}
