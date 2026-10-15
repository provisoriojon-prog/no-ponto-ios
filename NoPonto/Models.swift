import Foundation

struct GeoPoint: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var isValid: Bool { latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}
struct TransitCatalog: Codable, Sendable {
    var schemaVersion: Int
    var generatedAt: String
    var sourceModified: String
    var sourceURL: String
    var validFrom: String
    var validUntil: String
    var routes: [TransitRoute]
    var stops: [TransitStop]
    var patterns: [TransitPattern]
    var tripPatterns: [String: String]
}
struct TransitRoute: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var shortName: String
    var longName: String
    var agency: String
    var mode: String // bus or brt
    var color: String // RRGGBB
    var patternIDs: [String]
    var isBRT: Bool { mode == "brt" }
}
struct TransitStop: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}
struct StopVisit: Codable, Hashable, Sendable {
    var stopID: String
    var sequence: Int
    var distance: Double
    var scheduledOffset: Double?
    var distanceReliable: Bool = true
}
struct TransitPattern: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var routeID: String
    var direction: Int
    var headsign: String
    var shapeID: String
    var polyline: String
    var stops: [StopVisit]
    var tripCount: Int
}
struct TransitVehicle: Codable, Identifiable, Hashable, Sendable {
    var id: String // source:vehicle ID
    var vehicleID: String
    var label: String
    var source: String // onibus or brt
    var routeID: String
    var tripID: String?
    var direction: Int?
    var latitude: Double
    var longitude: Double
    var bearing: Double?
    var speed: Double?
    var timestamp: Date?
    var coordinate: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
    func age(at now: Date = Date()) -> TimeInterval? { timestamp.map { now.timeIntervalSince($0) } }
    func isFresh(at now: Date = Date()) -> Bool { guard let age = age(at: now) else { return false }; return age >= -15 && age <= 120 }
}
struct RealtimeBatch: Sendable {
    var source: String
    var fetchedAt: Date
    var feedTimestamp: Date?
    var vehicles: [TransitVehicle]
    var issues: [String] = []
}
enum MatchCertainty: String, Codable, Sendable { case exactTrip, routeInferred }
struct VehicleMatch: Sendable {
    var patternID: String
    var progress: Double
    var distanceFromRoute: Double
    var certainty: MatchCertainty
    var reason: String
}
struct RouteProjection: Sendable {
    var progress: Double
    var distance: Double
    var segment: Int
    var bearing: Double
}
enum EstimateConfidence: String, Codable, Sendable { case good, limited, unavailable }
struct ArrivalEstimate: Identifiable, Sendable {
    var vehicleID: String
    var routeID: String
    var patternID: String
    var stopID: String
    var stopSequence: Int
    var secondsLower: Double?
    var secondsUpper: Double?
    var confidence: EstimateConfidence
    var reason: String
    var distance: Double?
    var positionAge: Double?
    var id: String { vehicleID + ":" + patternID + ":" + String(stopSequence) }
}
struct SourceStatus: Identifiable, Sendable {
    var id: String
    var name: String
    var lastSuccess: Date?
    var vehicleCount: Int
    var error: String?
    var feedTimestamp: Date? = nil
    var diagnostics: [String] = []
    func qualityWarnings(at now: Date = Date()) -> [String] {
        var warnings = diagnostics
        if let timestamp = feedTimestamp {
            let age = now.timeIntervalSince(timestamp)
            if age > 120 { warnings.append("O horário publicado pela fonte está desatualizado.") }
            else if age < -15 { warnings.append("O relógio publicado pela fonte está adiantado.") }
        } else if lastSuccess != nil {
            warnings.append("A resposta não informa o horário de geração da fonte.")
        }
        return warnings
    }
}
struct FavoriteJourney: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var group: String
    var routeID: String
    var patternID: String
    var stopID: String
    var stopSequence: Int
    var createdAt: Date
}
