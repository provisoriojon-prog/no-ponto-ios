import Foundation

/// A bounded, dependency-free reader of the official GTFS-Realtime wire format.
/// Unknown protobuf fields are ignored; a malformed envelope is never a successful empty feed.
enum GTFSRealtime {
    enum DecodeError: Error, LocalizedError {
        case malformed(String)
        var errorDescription: String? {
            switch self { case .malformed(let detail): return "Dados de localização inválidos: \(detail)" }
        }
    }

    static func decode(_ data: Data, source: String, fetchedAt: Date) throws -> RealtimeBatch {
        guard !data.isEmpty, data.count <= 16 * 1_024 * 1_024 else {
            throw DecodeError.malformed("tamanho inesperado")
        }
        let root = try Message(Array(data)[...])
        guard let headerBytes = root.bytes(1) else { throw DecodeError.malformed("cabeçalho ausente") }
        let header = try Message(headerBytes)
        guard let version = header.string(1), ["1.0", "2.0"].contains(version) else {
            throw DecodeError.malformed("versão GTFS-RT não reconhecida")
        }
        guard (header.integer(2) ?? 0) == 0 else {
            throw DecodeError.malformed("feed diferencial não suportado")
        }
        var result = RealtimeBatch(source: source, fetchedAt: fetchedAt,
                                   feedTimestamp: date(header.integer(3)), vehicles: [])
        var byID: [String: TransitVehicle] = [:]
        var rejected = 0
        var duplicates = 0
        for field in root.fields where field.number == 2 {
            guard case .bytes(let bytes) = field.value else { throw DecodeError.malformed("entidade inválida") }
            // Errors inside an entity invalidate that entity, not unrelated valid positions.
            do {
                let entity = try Message(bytes)
                if entity.integer(2) == 1 { continue }
                guard let payload = entity.bytes(4) else { continue } // TripUpdates/alerts are not positions.
                let vehicle = try Message(payload)
                guard let positionBytes = vehicle.bytes(2) else { rejected += 1; continue }
                let position = try Message(positionBytes)
                guard let latitude = position.float(1), let longitude = position.float(2),
                      GeoPoint(latitude: latitude, longitude: longitude).isValid else {
                    rejected += 1; continue
                }
                let trip = try vehicle.bytes(1).map { try Message($0) }
                if let relationship = trip?.integer(4), relationship == 3 || relationship == 7 { continue }
                let descriptor = try vehicle.bytes(8).map { try Message($0) }
                let rawID = descriptor?.string(1) ?? entity.string(1) ?? ""
                guard !rawID.isEmpty, rawID.utf8.count <= 512 else { rejected += 1; continue }
                let rawDirection = trip?.integer(6)
                let direction: Int? = rawDirection.flatMap { $0 <= 1 ? Int($0) : nil }
                let bearing = position.float(3).flatMap { $0.isFinite && $0 >= 0 && $0 <= 360 ? $0.truncatingRemainder(dividingBy: 360) : nil }
                let speed = position.float(5).flatMap { $0.isFinite && $0 >= 0 && $0 <= 70 ? $0 : nil }
                let parsed = TransitVehicle(
                    id: source + ":" + rawID, vehicleID: rawID,
                    label: descriptor?.string(2) ?? rawID, source: source,
                    routeID: trip?.string(5) ?? "", tripID: trip?.string(1), direction: direction,
                    latitude: latitude, longitude: longitude, bearing: bearing, speed: speed,
                    timestamp: date(vehicle.integer(5)))
                if let old = byID[parsed.id] {
                    duplicates += 1
                    if (old.timestamp ?? .distantPast) >= (parsed.timestamp ?? .distantPast) { continue }
                }
                byID[parsed.id] = parsed
            } catch { rejected += 1 }
        }
        result.vehicles = byID.values.sorted { $0.id < $1.id }
        if rejected > 0 { result.issues.append("\(rejected) posição(ões) inválida(s) descartada(s)") }
        if duplicates > 0 { result.issues.append("\(duplicates) posição(ões) duplicada(s); mantido o sinal mais recente") }
        return result
    }

    private static func date(_ seconds: UInt64?) -> Date? {
        guard let seconds = seconds, seconds > 0, seconds <= 253_402_300_799 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds))
    }

    private enum Value {
        case integer(UInt64), fixed32(UInt32), fixed64(UInt64), bytes(ArraySlice<UInt8>)
    }
    private struct Field { let number: Int; let value: Value }
    private struct Message {
        let fields: [Field]
        init(_ bytes: ArraySlice<UInt8>) throws {
            var reader = Reader(bytes: bytes, offset: bytes.startIndex)
            var parsed: [Field] = []
            while reader.offset < bytes.endIndex {
                guard parsed.count < 100_000 else { throw DecodeError.malformed("campos em excesso") }
                let key = try reader.varint()
                let number = key >> 3
                guard number > 0, number <= 536_870_911 else { throw DecodeError.malformed("número de campo inválido") }
                let value: Value
                switch key & 7 {
                case 0: value = .integer(try reader.varint())
                case 1: value = .fixed64(try reader.fixed(count: 8))
                case 2:
                    let length = try reader.varint()
                    guard length <= UInt64(bytes.endIndex - reader.offset) else { throw DecodeError.malformed("campo truncado") }
                    let end = reader.offset + Int(length)
                    value = .bytes(bytes[reader.offset..<end]); reader.offset = end
                case 5: value = .fixed32(UInt32(try reader.fixed(count: 4)))
                default: throw DecodeError.malformed("tipo protobuf inválido")
                }
                parsed.append(Field(number: Int(number), value: value))
            }
            fields = parsed
        }
        func bytes(_ field: Int) -> ArraySlice<UInt8>? {
            guard let last = fields.last(where: { $0.number == field }), case .bytes(let value) = last.value else { return nil }
            return value
        }
        func string(_ field: Int) -> String? {
            guard let value = bytes(field), value.count <= 4_096,
                  let string = String(bytes: value, encoding: .utf8), !string.isEmpty else { return nil }
            return string
        }
        func integer(_ field: Int) -> UInt64? {
            guard let last = fields.last(where: { $0.number == field }), case .integer(let value) = last.value else { return nil }
            return value
        }
        func float(_ field: Int) -> Double? {
            guard let last = fields.last(where: { $0.number == field }), case .fixed32(let value) = last.value else { return nil }
            return Double(Float(bitPattern: value))
        }
    }
    private struct Reader {
        let bytes: ArraySlice<UInt8>
        var offset: Int
        mutating func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.endIndex else { throw DecodeError.malformed("varint truncado") }
                let byte = bytes[offset]; offset += 1
                if index == 9 && byte > 1 { throw DecodeError.malformed("varint excede 64 bits") }
                value |= UInt64(byte & 127) << (index * 7)
                if byte & 128 == 0 { return value }
            }
            throw DecodeError.malformed("varint inválido")
        }
        mutating func fixed(count: Int) throws -> UInt64 {
            guard bytes.endIndex - offset >= count else { throw DecodeError.malformed("número truncado") }
            var value: UInt64 = 0
            for index in 0..<count { value |= UInt64(bytes[offset + index]) << (index * 8) }
            offset += count
            return value
        }
    }
}
