import XCTest
@testable import NoPonto

@MainActor
final class StoreTests: XCTestCase {
    func testCatalogSearchPreservesCatalogAndSuggestsOnlyAfterThreshold() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        XCTAssertFalse(store.isLoading)
        XCTAssertGreaterThan(store.catalog?.routes.count ?? 0, 450)
        for query in ["", "3", " 3 ", "SR3", "SN3", "SR", "SN", "b"] {
            XCTAssertTrue(store.searchRoutes(query).isEmpty, "No premature suggestions for \(query)")
        }
        XCTAssertLessThanOrEqual(store.searchRoutes("39").count, 8)
        let results = store.searchRoutes("397")
        XCTAssertTrue(results.contains { $0.shortName == "397" })
        XCTAssertTrue(results.contains { $0.shortName == "SR397" })
        XCTAssertTrue(results.contains { $0.shortName == "SN397" })
        XCTAssertEqual(results.first?.shortName, "397")
        for prefix in ["SR", "SN"] {
            let suggestions = store.searchRoutes(prefix + "39").map(\.shortName)
            let index393 = try XCTUnwrap(suggestions.firstIndex(of: prefix + "393"))
            let index397 = try XCTUnwrap(suggestions.firstIndex(of: prefix + "397"))
            XCTAssertLessThan(index393, index397, "A partial prefix orders 393 before 397 without omitting the requested variant")
            XCTAssertEqual(store.searchRoutes(prefix + "397").first?.shortName, prefix + "397", "An exact prefixed number ranks first")
        }
        XCTAssertFalse(store.searchRoutes("bangu").isEmpty)
        XCTAssertEqual(TransitStore.normalized("São Conrado"), TransitStore.normalized("sao conrado"))
        XCTAssertFalse(store.searchRoutes("10", mode: "brt").isEmpty)
        XCTAssertTrue(store.searchRoutes("sa", mode: "brt").allSatisfy(\.isBRT))
    }

    func testFreshInstallHasNoMapVehiclesEvenWhenFeedHasData() async {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        XCTAssertFalse(store.vehicles.isEmpty, "Demo contains observations to prove map filtering")
        XCTAssertEqual(store.vehicles.count, 9)
        XCTAssertEqual(Set(store.vehicles.map(\.id)).count, 9)
        XCTAssertEqual(Set(store.vehicles.compactMap { store.route($0.routeID)?.shortName }), Set(["369", "397", "SR397"]))
        XCTAssertTrue(store.savedRoutes.isEmpty)
        XCTAssertTrue(store.selectedRouteIDs.isEmpty)
        XCTAssertNil(store.selectedRoute)
        XCTAssertNil(store.selectedPattern)
        XCTAssertNil(store.selectedStopSequence)
        XCTAssertTrue(store.arrivals.isEmpty)
        XCTAssertTrue(store.visibleVehicles().isEmpty)
        store.showStaleVehicles = true
        XCTAssertTrue(store.visibleVehicles().isEmpty, "The stale setting cannot turn empty selection into the whole fleet")
    }

    func testSelectingRoutesAutosavesOrderAndRemovalPersists() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        let first = try XCTUnwrap(store.searchRoutes("369").first { $0.shortName == "369" })
        let second = try XCTUnwrap(store.searchRoutes("397").first { $0.shortName == "397" })
        store.selectRoute(first.id)
        XCTAssertFalse(store.visibleVehicles().isEmpty)
        store.selectRoute(second.id)
        store.selectRoute(first.id)
        XCTAssertEqual(store.savedRoutes.map(\.id), [first.id, second.id], "Reactivating a saved route does not reorder or duplicate it")
        XCTAssertEqual(store.selectedRoute?.id, first.id)
        XCTAssertTrue(store.visibleVehicles().allSatisfy { store.selectedRouteIDs.contains($0.routeID) })

        let reopened = TransitStore(testing: true)
        await reopened.start()
        XCTAssertEqual(reopened.savedRoutes.map(\.id), [first.id, second.id])
        XCTAssertEqual(reopened.selectedRoute?.id, first.id)
        reopened.removeRoute(first.id)
        XCTAssertEqual(reopened.savedRoutes.map(\.id), [second.id])
        XCTAssertEqual(reopened.selectedRoute?.id, second.id)
        reopened.removeRoute(second.id)
        XCTAssertTrue(reopened.savedRoutes.isEmpty)
        XCTAssertTrue(reopened.visibleVehicles().isEmpty)
        XCTAssertNil(reopened.selectedPattern)

        let emptyAgain = TransitStore(testing: true)
        await emptyAgain.start()
        XCTAssertTrue(emptyAgain.savedRoutes.isEmpty)
        XCTAssertTrue(emptyAgain.visibleVehicles().isEmpty, "Demo must respect an explicitly emptied saved list on relaunch")
    }

    func testRemoveAllRoutesKeepsDetailedFavoritesAndDoesNotImportThemOnRelaunch() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        try selectDemoJourney(store)
        store.addFavorite(name: "Ponto preservado", group: "Ida")
        let favorite = try XCTUnwrap(store.favorites.first)
        store.removeAllRoutes()
        XCTAssertTrue(store.visibleVehicles().isEmpty)
        XCTAssertEqual(store.favorites.first?.id, favorite.id)
        let reopened = TransitStore(testing: true)
        await reopened.start()
        XCTAssertEqual(reopened.favorites.first?.id, favorite.id)
        XCTAssertTrue(reopened.savedRoutes.isEmpty, "Existing detailed favorites are not imported as route subscriptions")
        XCTAssertTrue(reopened.visibleVehicles().isEmpty)
        reopened.openFavorite(favorite)
        XCTAssertEqual(reopened.savedRoutes.map(\.id), [favorite.routeID], "Only explicitly opening a favorite adds its route")
    }

    func testFavoritePersistsExactPointAndDirection() async throws {
        let store = TransitStore(testing: true, resetTestState: true)
        await store.start()
        try selectDemoJourney(store)
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
        XCTAssertEqual(reopened.selectedPatternID, pattern.id)
        XCTAssertEqual(reopened.selectedStopSequence, sequence)
        XCTAssertEqual(reopened.selectedStop?.id, stop.id)
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
        try selectDemoJourney(store)
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
        try selectDemoJourney(store)
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
        XCTAssertEqual(store.vehicles.count, 1)
        XCTAssertTrue(store.visibleVehicles().isEmpty, "Receiving data cannot subscribe a route on the user's behalf")

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
        try selectDemoJourney(store)
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

    private func selectDemoJourney(_ store: TransitStore) throws {
        let route = try XCTUnwrap(store.searchRoutes("369").first { $0.shortName == "369" })
        store.selectRoute(route.id)
        let pattern = try XCTUnwrap(store.selectedPattern)
        let visit = try XCTUnwrap(pattern.stops.dropFirst(5).first { $0.distanceReliable && $0.distance > 1600 })
        store.selectStop(sequence: visit.sequence)
    }
}
