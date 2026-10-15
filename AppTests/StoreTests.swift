import XCTest
@testable import NoPonto

@MainActor
final class StoreTests: XCTestCase {
    func testCatalogSearchKeepsAllRoutesAndSuffixVariants() async {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        XCTAssertFalse(store.isLoading)
        XCTAssertGreaterThan(store.searchRoutes("").count, 450)
        let results = store.searchRoutes("397")
        XCTAssertTrue(results.contains { $0.shortName == "397" })
        XCTAssertTrue(results.contains { $0.shortName == "SR397" })
        XCTAssertEqual(results.first?.shortName, "397")
        XCTAssertFalse(store.searchRoutes("bangu").isEmpty)
        XCTAssertEqual(TransitStore.normalized("São Conrado"), TransitStore.normalized("sao conrado"))
        XCTAssertFalse(store.searchRoutes("10").filter(\.isBRT).isEmpty)
    }

    func testFavoritePersistsExactPointAndDirection() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        let pattern = try XCTUnwrap(store.selectedPattern)
        let sequence = try XCTUnwrap(store.selectedStopSequence)
        let stop = try XCTUnwrap(store.selectedStop)
        store.addFavorite(name: "Meu embarque", group: "Ida")
        XCTAssertEqual(store.favorites.count, 1)
        let saved = try XCTUnwrap(store.favorites.first)
        XCTAssertEqual(saved.patternID, pattern.id)
        XCTAssertEqual(saved.stopID, stop.id)
        XCTAssertEqual(saved.stopSequence, sequence)
        let reopened = TransitStore(testing: true)
        await reopened.start()
        XCTAssertEqual(reopened.favorites.first?.id, saved.id)
        reopened.clearSelection()
        reopened.openFavorite(saved)
        XCTAssertEqual(reopened.selectedPatternID, pattern.id)
        XCTAssertEqual(reopened.selectedStopSequence, sequence)
        reopened.removeFavorite(saved.id)
        XCTAssertTrue(TransitStore(testing: true).favorites.isEmpty)
    }

    func testChangingDirectionRequiresNewPointConfirmation() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        let route = try XCTUnwrap(store.selectedRoute)
        let original = try XCTUnwrap(store.selectedPattern)
        let opposite = try XCTUnwrap(store.patterns(for: route.id).first { $0.direction != original.direction })
        store.selectPattern(opposite.id)
        XCTAssertNil(store.selectedStopSequence)
        XCTAssertTrue(store.arrivals.isEmpty)
        store.addFavorite(name: "Ainda não confirmado", group: "Volta")
        XCTAssertTrue(store.favorites.isEmpty)
    }

    func testInvalidFavoriteDoesNotSelectAnArbitraryStop() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        store.addFavorite(name: "Teste", group: "Ida")
        var saved = try XCTUnwrap(store.favorites.first)
        saved.stopID = "inexistente"
        store.clearSelection()
        store.openFavorite(saved)
        XCTAssertNil(store.selectedPatternID)
        XCTAssertTrue(store.statusMessage.contains("mudou"))
    }

    func testNewBundledCatalogWinsOverOlderCacheOffline() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        var older = try XCTUnwrap(store.catalog)
        var newer = older
        older.generatedAt = "2026-10-14T23:00:00Z"
        newer.generatedAt = "2026-10-15T00:00:00.000Z"
        let oldData = try JSONEncoder().encode(older)
        let newData = try JSONEncoder().encode(newer)
        XCTAssertEqual(try TransitStore.preferredCatalog(cached: oldData, bundled: newData).generatedAt, newer.generatedAt)
        XCTAssertEqual(try TransitStore.preferredCatalog(cached: newData, bundled: oldData).generatedAt, newer.generatedAt)
        XCTAssertEqual(try TransitStore.preferredCatalog(cached: Data("broken".utf8), bundled: newData).generatedAt, newer.generatedAt)
        XCTAssertThrowsError(try TransitStore.preferredCatalog(cached: nil, bundled: nil))
    }

    func testMissingTimestampCanBeShownOnlyForRecentValidSourceResponse() {
        let now = Date()
        let vehicle = unknownTimeVehicle()
        let source = SourceStatus(id: "onibus", name: "Ônibus", lastSuccess: now, vehicleCount: 1, error: nil, feedTimestamp: now)
        XCTAssertEqual(TransitStore.retainedVehicles([vehicle], sources: [source], now: now).count, 1)
        XCTAssertTrue(TransitStore.retainedVehicles([vehicle], sources: [source], now: now.addingTimeInterval(121)).isEmpty)
        XCTAssertTrue(TransitStore.retainedVehicles([vehicle], sources: [], now: now).isEmpty, "Cached positions without GPS timestamps cannot use app startup as their age")
        var oldFeed = source
        oldFeed.feedTimestamp = now.addingTimeInterval(-130)
        XCTAssertTrue(TransitStore.retainedVehicles([vehicle], sources: [oldFeed], now: now).isEmpty, "A fresh HTTP receipt cannot renew a known old feed")
    }

    func testDiagnosticsAndFeedGenerationTimeRemainVisible() {
        let now = Date()
        let store = TransitStore(testing: true, resetTestState: true)
        let valid = RealtimeBatch(source: "onibus", fetchedAt: now, feedTimestamp: now.addingTimeInterval(-20),
                                  vehicles: [unknownTimeVehicle()], issues: ["1 posição inválida descartada"])
        store.applyRealtimeBatch(valid)
        let source = store.sourceStates[0]
        XCTAssertEqual(source.feedTimestamp, valid.feedTimestamp)
        XCTAssertEqual(source.lastSuccess, now)
        XCTAssertEqual(source.diagnostics, valid.issues)
        XCTAssertNil(source.error, "Partial valid data keeps operating with a visible warning")
        XCTAssertFalse(source.qualityWarnings(at: now).isEmpty)
        store.showStaleVehicles = true
        XCTAssertEqual(store.visibleVehicles().count, 1)

        store.applyRealtimeBatch(RealtimeBatch(source: "onibus", fetchedAt: now.addingTimeInterval(30), feedTimestamp: now.addingTimeInterval(30), vehicles: [], issues: ["Todas as posições inválidas"]))
        XCTAssertNotNil(store.sourceStates[0].error, "An all-invalid response must not masquerade as a healthy empty fleet")
        XCTAssertEqual(store.sourceStates[0].lastSuccess, now, "Invalid response cannot renew previous undated observations")
        XCTAssertEqual(store.vehicles.count, 1, "Last valid observations remain visibly aging")
        store.refreshLocalState(at: now.addingTimeInterval(121))
        XCTAssertTrue(store.vehicles.isEmpty)

        store.applyRealtimeBatch(RealtimeBatch(source: "onibus", fetchedAt: now, feedTimestamp: now, vehicles: []))
        XCTAssertNil(store.sourceStates[0].error, "A legitimate empty full snapshot is not a parsing error")
    }

    func testLocalClockExpiresArrivalsWithoutWaitingForNetwork() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        XCTAssertFalse(store.arrivals.isEmpty)
        let latest = try XCTUnwrap(store.vehicles.compactMap(\.timestamp).max())
        store.refreshLocalState(at: latest.addingTimeInterval(121))
        XCTAssertFalse(store.arrivals.isEmpty, "A stale vehicle remains identifiable instead of disappearing immediately")
        XCTAssertTrue(store.arrivals.allSatisfy { $0.confidence == .unavailable && $0.secondsLower == nil && $0.secondsUpper == nil })
        XCTAssertTrue(store.arrivals.allSatisfy { ($0.positionAge ?? 0) >= 121 })
    }

    func testSourceWarningsDistinguishResponseTimeFromFeedTime() {
        let now = Date()
        let source = SourceStatus(id: "onibus", name: "Ônibus", lastSuccess: now, vehicleCount: 10, error: nil,
                                  feedTimestamp: now.addingTimeInterval(-130))
        XCTAssertTrue(source.qualityWarnings(at: now).contains { $0.contains("desatualizado") })
        var missing = source
        missing.feedTimestamp = nil
        XCTAssertTrue(missing.qualityWarnings(at: now).contains { $0.contains("não informa") })
    }

    private func unknownTimeVehicle() -> TransitVehicle {
        TransitVehicle(id: "onibus:sem-horario", vehicleID: "sem-horario", label: "Sem horário", source: "onibus",
                       routeID: "desconhecida", tripID: nil, direction: nil, latitude: -22.9, longitude: -43.2,
                       bearing: nil, speed: nil, timestamp: nil)
    }
}
