import Foundation

enum TransitGeometry {
    static let earthRadius = 6_371_000.0
    private static let radians = Double.pi / 180

    static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        guard a.isValid, b.isValid else { return .infinity }
        let dLat = (b.latitude - a.latitude) * radians
        let dLon = longitudeDelta(b.longitude - a.longitude) * radians
        let h = pow(sin(dLat / 2), 2) + cos(a.latitude * radians) * cos(b.latitude * radians) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(sqrt(min(1, max(0, h))))
    }

    static func bearing(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        guard a.isValid, b.isValid else { return 0 }
        let dLon = longitudeDelta(b.longitude - a.longitude) * radians
        let y = sin(dLon) * cos(b.latitude * radians)
        let x = cos(a.latitude * radians) * sin(b.latitude * radians) - sin(a.latitude * radians) * cos(b.latitude * radians) * cos(dLon)
        return (atan2(y, x) / radians + 360).truncatingRemainder(dividingBy: 360)
    }

    static func angleDifference(_ a: Double, _ b: Double) -> Double {
        abs(longitudeDelta(a - b))
    }

    /// Returns [] for malformed or unbounded polylines; never returns a partially decoded route.
    static func decodePolyline(_ encoded: String) -> [GeoPoint] {
        let bytes = Array(encoded.utf8)
        guard bytes.count <= 2_000_000 else { return [] }
        var index = 0
        var latitude: Int64 = 0
        var longitude: Int64 = 0
        var points: [GeoPoint] = []
        func nextDelta() -> Int64? {
            var value: Int64 = 0
            var shift = 0
            while index < bytes.count && shift <= 30 {
                let char = bytes[index]; index += 1
                guard char >= 63 && char <= 126 else { return nil }
                let byte = Int64(char - 63)
                value |= (byte & 31) << shift
                if byte < 32 { return value & 1 == 0 ? value >> 1 : ~(value >> 1) }
                shift += 5
            }
            return nil
        }
        while index < bytes.count {
            guard let dLat = nextDelta(), let dLon = nextDelta() else { return [] }
            latitude += dLat; longitude += dLon
            let point = GeoPoint(latitude: Double(latitude) / 100_000, longitude: Double(longitude) / 100_000)
            guard point.isValid else { return [] }
            points.append(point)
        }
        return points
    }

    static func project(_ point: GeoPoint, onto points: [GeoPoint]) -> RouteProjection? {
        PreparedPolyline(points).projections(point).min { $0.distance < $1.distance }
    }

    private static func longitudeDelta(_ value: Double) -> Double {
        var delta = value.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    /// Precomputes cumulative geodesic lengths. Local segment projection is accurate for city streets.
    struct PreparedPolyline {
        struct Segment {
            var start: GeoPoint
            var end: GeoPoint
            var progress: Double
            var length: Double
            var bearing: Double
            var index: Int
        }
        let segments: [Segment]
        let length: Double
        init(_ points: [GeoPoint]) {
            var segments: [Segment] = []
            var progress = 0.0
            if points.count >= 2 && points.allSatisfy(\.isValid) {
                for index in 0..<(points.count - 1) {
                    let a = points[index], b = points[index + 1]
                    let length = TransitGeometry.distance(a, b)
                    if length > 0.01 {
                        segments.append(Segment(start: a, end: b, progress: progress,
                                                length: length, bearing: TransitGeometry.bearing(a, b), index: index))
                        progress += length
                    }
                }
            }
            self.segments = segments
            length = progress
        }
        func projections(_ point: GeoPoint, within maxDistance: Double = .infinity) -> [RouteProjection] {
            guard point.isValid else { return [] }
            var results: [RouteProjection] = []
            let scale = TransitGeometry.earthRadius * TransitGeometry.radians
            let cosLatitude = cos(point.latitude * TransitGeometry.radians)
            for segment in segments {
                let ax = TransitGeometry.longitudeDelta(segment.start.longitude - point.longitude) * scale * cosLatitude
                let ay = (segment.start.latitude - point.latitude) * scale
                let bx = ax + TransitGeometry.longitudeDelta(segment.end.longitude - segment.start.longitude) * scale * cosLatitude
                let by = (segment.end.latitude - point.latitude) * scale
                if maxDistance.isFinite && (min(ax, bx) > maxDistance || max(ax, bx) < -maxDistance || min(ay, by) > maxDistance || max(ay, by) < -maxDistance) { continue }
                let dx = bx - ax, dy = by - ay
                let square = dx * dx + dy * dy
                guard square > 0 else { continue }
                let t = min(1, max(0, -(ax * dx + ay * dy) / square))
                let distance = hypot(ax + t * dx, ay + t * dy)
                if distance <= maxDistance {
                    results.append(RouteProjection(progress: segment.progress + segment.length * t,
                                                   distance: distance, segment: segment.index, bearing: segment.bearing))
                }
            }
            return results
        }
    }
}
