import Foundation
import Combine

@MainActor
final class TransitStore: ObservableObject {
    @Published private(set) var catalog: TransitCatalog?
    @Published private(set) var vehicles: [TransitVehicle] = []
    @Published private(set) var isLoading = true
    @Published private(set) var isRefreshing = false
    @Published var statusMessage = "Preparando o catálogo…"
    @Published private(set) var sourceStates = [
        SourceStatus(id: "onibus", name: "Ônibus", lastSuccess: nil, vehicleCount: 0, error: nil),
        SourceStatus(id: "brt", name: "BRT", lastSuccess: nil, vehicleCount: 0, error: nil)
    ]
    @Published private(set) var selectedRouteIDs: Set<String> = []
    @Published private var savedRouteIDs: [String] = []
    @Published private(set) var selectedPrimaryRouteID: String?
    @Published var selectedPatternID: String?
    @Published var selectedStopSequence: Int?
    @Published private(set) var favorites: [FavoriteJourney] = []
    @Published var searchText = ""
    @Published var showStops = true { didSet { preferences.set(showStops, forKey: "showStops") } }
    @Published var showStaleVehicles = false { didSet { preferences.set(showStaleVehicles, forKey: "showStaleVehicles") } }
    @Published private(set) var arrivals: [ArrivalEstimate] = []
    @Published private(set) var isUpdatingCatalog = false
    private(set) var engine: TransitEngine?
    private var routesByID: [String: TransitRoute] = [:]
    private var stopsByID: [String: TransitStop] = [:]
    private var patternsByID: [String: TransitPattern] = [:]
    private var searchIndex: [String: String] = [:]
    private var routePrefixes: Set<String> = []
    private var restoredStopID: String?
    private var active = true
    private var started = false
    private var pollingTask: Task<Void, Never>?
    private var freshnessTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    private var lastSourceSummary: String?
    private var failures: [String: Int] = [:]
    private var nextAttempt: [String: Date] = [:]
    private let preferences: UserDefaults
    private let cacheDirectory: URL
    private let catalogDownloadURL = URL(string: "https://github.com/provisoriojon-prog/no-ponto-ios/releases/latest/download/catalog.json")!
    let isDemoMode: Bool

    init(testing: Bool = false, resetTestState: Bool = false) {
        #if DEBUG
        isDemoMode = testing || ProcessInfo.processInfo.arguments.contains("--ui-testing")
        #else
        isDemoMode = false
        #endif
        if isDemoMode {
            let suite = "br.com.provisoriojon.noponto.ui-tests"
            if resetTestState || ProcessInfo.processInfo.arguments.contains("--reset-test-state") {
                UserDefaults.standard.removePersistentDomain(forName: suite)
            }
            preferences = UserDefaults(suiteName: suite) ?? .standard
        } else {
            preferences = .standard
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        cacheDirectory = base.appendingPathComponent(isDemoMode ? "NoPontoTests" : "NoPonto", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        showStops = preferences.object(forKey: "showStops") as? Bool ?? true
        showStaleVehicles = preferences.bool(forKey: "showStaleVehicles")
        if let data = preferences.data(forKey: "favorites.v1"), let saved = try? JSONDecoder().decode([FavoriteJourney].self, from: data) {
            favorites = saved
        }
        // Route subscriptions are independent of detailed journey favorites. Never migrate favorites silently.
        if let data = preferences.data(forKey: "savedRoutes.v1"), let saved = try? JSONDecoder().decode(SavedRouteSelection.self, from: data) {
            var seen: Set<String> = []
            savedRouteIDs = saved.routeIDs.filter { seen.insert($0).inserted }
            selectedRouteIDs = Set(savedRouteIDs)
            selectedPrimaryRouteID = saved.primaryRouteID
            selectedPatternID = saved.patternID
            selectedStopSequence = saved.stopSequence
            restoredStopID = saved.stopID
        }
    }

    var selectedPattern: TransitPattern? { selectedPatternID.flatMap { patternsByID[$0] } }
    var savedRoutes: [TransitRoute] { savedRouteIDs.compactMap { routesByID[$0] } }
    var selectedRoute: TransitRoute? { selectedPrimaryRouteID.flatMap { routesByID[$0] } }
    var selectedVisits: [StopVisit] { selectedPattern?.stops ?? [] }
    var selectedStop: TransitStop? {
        guard let seq = selectedStopSequence, let visit = selectedVisits.first(where: { $0.sequence == seq }) else { return nil }
        return stopsByID[visit.stopID]
    }
    var unknownRouteCount: Int { Set(vehicles.filter { routesByID[$0.routeID] == nil }.map(\.routeID)).count }
    var catalogNotice: String {
        guard let catalog else { return "Catálogo ainda indisponível." }
        let date = String(catalog.sourceModified.prefix(10))
        return "\(catalog.routes.count) linhas/serviços · \(catalog.stops.count) pontos · base \(date). Algumas viagens ao vivo podem ter alterações posteriores."
    }

    func start() async {
        guard !started else { return }
        started = true
        let cached = cacheDirectory.appendingPathComponent("catalog.json")
        let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json")
        do {
            let loaded = try await Task.detached(priority: .userInitiated) { () throws -> TransitCatalog in
                let cacheData = try? Data(contentsOf: cached)
                let bundleData = bundled.flatMap { try? Data(contentsOf: $0) }
                return try Self.preferredCatalog(cached: cacheData, bundled: bundleData)
            }.value
            installCatalog(loaded)
            isLoading = false
            #if DEBUG
            if isDemoMode { prepareDemo(); return }
            #endif
            loadLastPositions()
            beginFreshnessClock()
            await refresh()
            beginPolling()
            let last = preferences.object(forKey: "catalogCheck") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 86_400 {
                catalogTask = Task { [weak self] in await self?.updateCatalog(silent: true) }
            }
        } catch {
            isLoading = false
            statusMessage = "Não foi possível abrir o catálogo. \(error.localizedDescription)"
            started = false
        }
    }

    /// New IPA resources must supersede an older cache even while the device is offline.
    nonisolated static func preferredCatalog(cached: Data?, bundled: Data?) throws -> TransitCatalog {
        let cache = cached.flatMap { try? decodeCatalog($0) }
        let bundle = bundled.flatMap { try? decodeCatalog($0) }
        if let cache = cache, let bundle = bundle {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            func date(_ value: String) -> Date? {
                if let date = formatter.date(from: value) { return date }
                let plain = ISO8601DateFormatter()
                return plain.date(from: value)
            }
            if let cacheDate = date(cache.generatedAt), let bundleDate = date(bundle.generatedAt) {
                return cacheDate > bundleDate ? cache : bundle
            }
            return cache.generatedAt > bundle.generatedAt ? cache : bundle
        }
        if let available = bundle ?? cache { return available }
        throw StoreFailure.message("Não há um catálogo válido incluído ou salvo nesta instalação.")
    }

    nonisolated private static func decodeCatalog(_ data: Data) throws -> TransitCatalog {
        guard data.count < 35_000_000 else { throw StoreFailure.message("Catálogo maior que o limite esperado.") }
        let c = try JSONDecoder().decode(TransitCatalog.self, from: data)
        guard c.schemaVersion == 1, !c.routes.isEmpty, !c.stops.isEmpty, !c.patterns.isEmpty,
              Set(c.routes.map(\.id)).count == c.routes.count,
              Set(c.stops.map(\.id)).count == c.stops.count,
              Set(c.patterns.map(\.id)).count == c.patterns.count,
              c.stops.allSatisfy({ $0.coordinate.isValid }) else {
            throw StoreFailure.message("Catálogo incompatível ou incompleto.")
        }
        return c
    }

    private func installCatalog(_ loaded: TransitCatalog) {
        let previousStopID = selectedStop?.id ?? restoredStopID
        routesByID = Dictionary(uniqueKeysWithValues: loaded.routes.map { ($0.id, $0) })
        stopsByID = Dictionary(uniqueKeysWithValues: loaded.stops.map { ($0.id, $0) })
        patternsByID = Dictionary(uniqueKeysWithValues: loaded.patterns.map { ($0.id, $0) })
        searchIndex = Dictionary(uniqueKeysWithValues: loaded.routes.map { route in
            let destinations = route.patternIDs.compactMap { patternsByID[$0]?.headsign }.joined(separator: " ")
            return (route.id, Self.normalized(route.shortName + " " + route.longName + " " + destinations))
        })
        routePrefixes = Set(loaded.routes.map { Self.normalized(String($0.shortName.prefix(while: { $0.isLetter }))) }.filter { !$0.isEmpty })
        engine = TransitEngine(catalog: loaded)
        catalog = loaded
        savedRouteIDs = savedRouteIDs.filter { routesByID[$0] != nil }
        selectedRouteIDs = Set(savedRouteIDs)
        if selectedPrimaryRouteID.map({ !selectedRouteIDs.contains($0) }) ?? true {
            selectedPrimaryRouteID = savedRouteIDs.first
        }
        if selectedPrimaryRouteID == nil {
            selectedPatternID = nil
            selectedStopSequence = nil
        } else if selectedPattern?.routeID != selectedPrimaryRouteID {
            selectedPatternID = selectedPrimaryRouteID.flatMap { patterns(for: $0).first?.id }
            selectedStopSequence = nil
        }
        if let sequence = selectedStopSequence,
           !selectedVisits.contains(where: { $0.sequence == sequence && $0.stopID == previousStopID }) {
            selectedStopSequence = nil
        }
        persistRouteSelection()
        recalculateArrivals()
    }

    func updateCatalog(silent: Bool = false) async {
        guard !isUpdatingCatalog, !isDemoMode else { return }
        isUpdatingCatalog = true
        defer { isUpdatingCatalog = false }
        do {
            var request = URLRequest(url: catalogDownloadURL)
            request.timeoutInterval = 40
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StoreFailure.message("Atualização do catálogo indisponível.") }
            let loaded = try await Task.detached { try Self.decodeCatalog(data) }.value
            if let current = catalog, loaded.generatedAt < current.generatedAt { throw StoreFailure.message("O catálogo recebido é anterior ao instalado.") }
            preferences.set(Date(), forKey: "catalogCheck")
            if loaded.generatedAt != catalog?.generatedAt {
                try data.write(to: cacheDirectory.appendingPathComponent("catalog.json"), options: .atomic)
                installCatalog(loaded)
                engine?.ingest(vehicles, now: Date())
                recalculateArrivals()
            }
            if !silent { statusMessage = "Catálogo conferido. Seus favoritos foram preservados." }
        } catch {
            if !silent { statusMessage = "Sem atualização agora. O catálogo salvo continua disponível." }
        }
    }

    func setActive(_ value: Bool) {
        let resumed = value && !active
        active = value
        if value {
            refreshLocalState()
            beginFreshnessClock()
            beginPolling()
            if resumed, catalog != nil { Task { [weak self] in await self?.refresh() } }
        }
        else {
            pollingTask?.cancel(); pollingTask = nil
            freshnessTask?.cancel(); freshnessTask = nil
        }
    }

    private func beginFreshnessClock() {
        guard active, catalog != nil, freshnessTask == nil, !isDemoMode else { return }
        freshnessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.active else { return }
                self.refreshLocalState()
            }
        }
    }

    /// Independent of network completion: GPS age and ETA must expire during a slow/failed request.
    func refreshLocalState(at now: Date = Date()) {
        vehicles = Self.retainedVehicles(vehicles, sources: sourceStates, now: now)
        recalculateArrivals(at: now)
        if statusMessage == lastSourceSummary { updateSourceSummary(at: now) }
    }

    nonisolated static func retainedVehicles(_ vehicles: [TransitVehicle], sources: [SourceStatus], now: Date) -> [TransitVehicle] {
        vehicles.filter { vehicle in
            guard vehicle.coordinate.isValid else { return false }
            if let age = vehicle.age(at: now) { return age >= -15 && age <= 1800 }
            // A timestamp-less position can only be shown as uncertain within a recent source response.
            guard let source = sources.first(where: { $0.id == vehicle.source }), let received = source.lastSuccess else { return false }
            let reference = source.feedTimestamp.map { min(received, $0) } ?? received
            let age = now.timeIntervalSince(reference)
            return age >= -15 && age <= 120
        }
    }

    private func beginPolling() {
        guard active, catalog != nil, pollingTask == nil, !isDemoMode else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                guard let self, self.active else { return }
                await self.refresh(force: false)
            }
        }
    }

    func refresh() async { await refresh(force: true) }

    private func refresh(force: Bool) async {
        guard !isRefreshing, catalog != nil, !isDemoMode else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let now = Date()
        let sources = ["onibus", "brt"].filter { force || (nextAttempt[$0] ?? .distantPast) <= now }
        guard !sources.isEmpty else { recalculateArrivals(); return }
        let results = await withTaskGroup(of: FetchOutcome.self) { group in
            for source in sources { group.addTask { await Self.fetch(source) } }
            var outcomes: [FetchOutcome] = []
            for await result in group { outcomes.append(result) }
            return outcomes
        }
        for result in results {
            guard let index = sourceStates.firstIndex(where: { $0.id == result.source }) else { continue }
            if let batch = result.batch {
                applyRealtimeBatch(batch)
            } else {
                let failure = min((failures[result.source] ?? 0) + 1, 5)
                failures[result.source] = failure
                nextAttempt[result.source] = Date().addingTimeInterval(min(900, 30 * pow(2, Double(failure))))
                sourceStates[index].error = result.message ?? "Fonte temporariamente indisponível."
            }
        }
        vehicles = Self.retainedVehicles(vehicles, sources: sourceStates, now: Date())
        engine?.ingest(vehicles, now: Date())
        recalculateArrivals()
        updateSourceSummary(at: Date())
        saveLastPositions()
    }

    func applyRealtimeBatch(_ batch: RealtimeBatch) {
        guard let index = sourceStates.firstIndex(where: { $0.id == batch.source }) else { return }
        sourceStates[index].feedTimestamp = batch.feedTimestamp
        sourceStates[index].diagnostics = batch.issues
        sourceStates[index].vehicleCount = batch.vehicles.count
        if batch.vehicles.isEmpty && !batch.issues.isEmpty {
            sourceStates[index].error = "A fonte respondeu, mas nenhuma posição pôde ser validada."
            let failure = min((failures[batch.source] ?? 0) + 1, 5)
            failures[batch.source] = failure
            nextAttempt[batch.source] = Date().addingTimeInterval(min(900, 30 * pow(2, Double(failure))))
            return // Keep previous observations visibly aging rather than replacing them with corrupt data.
        }
        failures[batch.source] = 0
        nextAttempt[batch.source] = Date().addingTimeInterval(25)
        sourceStates[index].lastSuccess = batch.fetchedAt
        sourceStates[index].error = nil
        // Each valid feed is a full snapshot. Preserve only the other source.
        vehicles.removeAll { $0.source == batch.source }
        vehicles.append(contentsOf: batch.vehicles)
    }

    private func updateSourceSummary(at now: Date) {
        if sourceStates.allSatisfy({ $0.error != nil }) {
            statusMessage = "Sem conexão com as fontes. Catálogo e favoritos continuam disponíveis."
        } else if let failed = sourceStates.first(where: { $0.error != nil }) {
            statusMessage = "\(failed.name) sem atualização · a outra fonte continua disponível."
        } else if sourceStates.contains(where: { !$0.qualityWarnings(at: now).isEmpty }) {
            let live = vehicles.filter { $0.isFresh(at: now) }.count
            statusMessage = "\(live) posições recentes · fontes com avisos; confira em Ajustes"
        } else {
            let live = vehicles.filter { $0.isFresh(at: now) }.count
            statusMessage = "\(live) veículos com posição recente · atualização a cada 30 s"
        }
        lastSourceSummary = statusMessage
    }

    nonisolated private static func fetch(_ source: String) async -> FetchOutcome {
        let url = URL(string: "https://dados.mobilidade.rio/gtfs/realtime/\(source)/vehicle-positions")!
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 35
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw StoreFailure.message(status == 429 ? "A fonte pediu uma pausa nas consultas." : "A fonte não respondeu normalmente.")
            }
            guard data.count <= 12_000_000 else { throw StoreFailure.message("Resposta maior que o limite esperado.") }
            let batch = try GTFSRealtime.decode(data, source: source, fetchedAt: Date())
            return FetchOutcome(source: source, batch: batch, message: nil)
        } catch {
            return FetchOutcome(source: source, batch: nil, message: error is CancellationError ? "Consulta pausada." : "Não foi possível atualizar esta fonte.")
        }
    }

    func route(_ id: String) -> TransitRoute? { routesByID[id] }
    func stop(_ id: String) -> TransitStop? { stopsByID[id] }
    func patterns(for routeID: String) -> [TransitPattern] {
        (routesByID[routeID]?.patternIDs ?? []).compactMap { patternsByID[$0] }.sorted {
            if $0.direction != $1.direction { return $0.direction < $1.direction }
            if $0.tripCount != $1.tripCount { return $0.tripCount > $1.tripCount }
            return $0.id < $1.id
        }
    }
    func searchRoutes(_ query: String, mode: String? = nil) -> [TransitRoute] {
        let q = Self.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let digitCount = q.filter(\.isNumber).count
        if digitCount > 0 {
            guard digitCount >= 2 else { return [] }
        } else {
            guard q.filter(\.isLetter).count >= 2, !routePrefixes.contains(q) else { return [] }
        }
        let tokens = q.split(separator: " ").map(String.init)
        let results = (catalog?.routes ?? []).filter { route in
            let correctMode = mode == nil || mode == "all" || route.mode == mode
            return correctMode && tokens.allSatisfy { (searchIndex[route.id] ?? "").contains($0) }
        }.sorted { lhs, rhs in
            let l = Self.normalized(lhs.shortName), r = Self.normalized(rhs.shortName)
            if !q.isEmpty, (l == q) != (r == q) { return l == q }
            if !q.isEmpty, l.hasPrefix(q) != r.hasPrefix(q) { return l.hasPrefix(q) }
            let order = lhs.shortName.localizedStandardCompare(rhs.shortName)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
        return Array(results.prefix(8))
    }
    nonisolated static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
    }

    func selectRoute(_ id: String) {
        guard routesByID[id] != nil else { statusMessage = "Esta linha ainda não está no catálogo instalado."; return }
        rememberRoute(id)
        if selectedPrimaryRouteID != id {
            selectedPrimaryRouteID = id
            selectedPatternID = patterns(for: id).first?.id
            selectedStopSequence = nil
        }
        persistRouteSelection()
        recalculateArrivals()
    }
    func selectPattern(_ id: String) {
        guard let pattern = patternsByID[id] else { return }
        rememberRoute(pattern.routeID)
        selectedPrimaryRouteID = pattern.routeID
        selectedPatternID = id
        selectedStopSequence = nil
        persistRouteSelection()
        recalculateArrivals()
    }
    func selectStop(sequence: Int) {
        guard selectedVisits.contains(where: { $0.sequence == sequence }) else { return }
        selectedStopSequence = sequence
        persistRouteSelection()
        recalculateArrivals()
    }
    func clearSelection() { removeAllRoutes() }

    func removeAllRoutes() {
        savedRouteIDs.removeAll()
        selectedRouteIDs.removeAll()
        selectedPrimaryRouteID = nil
        selectedPatternID = nil
        selectedStopSequence = nil
        arrivals = []
        persistRouteSelection()
    }
    func removeRoute(_ id: String) {
        savedRouteIDs.removeAll { $0 == id }
        selectedRouteIDs.remove(id)
        if selectedPrimaryRouteID == id {
            selectedPrimaryRouteID = savedRouteIDs.first
            selectedPatternID = selectedPrimaryRouteID.flatMap { patterns(for: $0).first?.id }
            selectedStopSequence = nil
        }
        persistRouteSelection()
        recalculateArrivals()
    }
    func toggleRoute(_ id: String) {
        if selectedRouteIDs.contains(id) { removeRoute(id) } else { selectRoute(id) }
    }
    private func rememberRoute(_ id: String) {
        if !savedRouteIDs.contains(id) { savedRouteIDs.append(id) }
        selectedRouteIDs.insert(id)
    }
    private func persistRouteSelection() {
        restoredStopID = selectedStop?.id
        let saved = SavedRouteSelection(routeIDs: savedRouteIDs, primaryRouteID: selectedPrimaryRouteID,
                                        patternID: selectedPatternID, stopSequence: selectedStopSequence,
                                        stopID: restoredStopID)
        if let data = try? JSONEncoder().encode(saved) { preferences.set(data, forKey: "savedRoutes.v1") }
    }
    private func recalculateArrivals(at now: Date = Date()) {
        guard let patternID = selectedPatternID, let sequence = selectedStopSequence else { arrivals = []; return }
        arrivals = engine?.arrivals(patternID: patternID, stopSequence: sequence, vehicles: vehicles, now: now) ?? []
    }

    func addFavorite(name: String, group: String) {
        guard let pattern = selectedPattern, let seq = selectedStopSequence,
              let visit = pattern.stops.first(where: { $0.sequence == seq }), let route = selectedRoute else {
            statusMessage = "Escolha a linha, o sentido e o ponto antes de salvar."; return
        }
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let groupName = group.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = favorites.firstIndex(where: { $0.routeID == route.id && $0.patternID == pattern.id && $0.stopSequence == seq }) {
            favorites[existing].name = title.isEmpty ? "\(route.shortName) · \(pattern.headsign)" : String(title.prefix(80))
            favorites[existing].group = groupName.isEmpty ? "Meus pontos" : String(groupName.prefix(40))
        } else {
            favorites.append(FavoriteJourney(id: UUID(), name: title.isEmpty ? "\(route.shortName) · \(pattern.headsign)" : String(title.prefix(80)), group: groupName.isEmpty ? "Meus pontos" : String(groupName.prefix(40)), routeID: route.id, patternID: pattern.id, stopID: visit.stopID, stopSequence: seq, createdAt: Date()))
        }
        persistFavorites()
    }
    func removeFavorite(_ id: UUID) { favorites.removeAll { $0.id == id }; persistFavorites() }
    func openFavorite(_ favorite: FavoriteJourney) {
        guard let pattern = patternsByID[favorite.patternID], pattern.routeID == favorite.routeID,
              pattern.stops.contains(where: { $0.sequence == favorite.stopSequence && $0.stopID == favorite.stopID }) else {
            statusMessage = "O trajeto deste favorito mudou. Busque a linha e confirme seu ponto novamente."; return
        }
        rememberRoute(favorite.routeID)
        selectedPrimaryRouteID = favorite.routeID
        selectedPatternID = favorite.patternID
        selectedStopSequence = favorite.stopSequence
        persistRouteSelection()
        recalculateArrivals()
    }
    private func persistFavorites() {
        if let data = try? JSONEncoder().encode(favorites) { preferences.set(data, forKey: "favorites.v1") }
    }
    func visibleVehicles() -> [TransitVehicle] {
        guard !selectedRouteIDs.isEmpty else { return [] }
        return vehicles.filter { selectedRouteIDs.contains($0.routeID) && (showStaleVehicles || $0.isFresh()) }
    }
    func nearestStops(to point: GeoPoint, limit: Int = 12) -> [TransitStop] {
        guard point.isValid else { return [] }
        return (catalog?.stops ?? []).map { ($0, TransitGeometry.distance(point, $0.coordinate)) }
            .filter { $0.1 <= 1500 }.sorted { $0.1 < $1.1 }.prefix(max(0, limit)).map(\.0)
    }
    private func loadLastPositions() {
        let url = cacheDirectory.appendingPathComponent("positions.json")
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([TransitVehicle].self, from: data) {
            // Receipt times are not persisted: timestamp-less cached coordinates cannot be dated safely.
            vehicles = Self.retainedVehicles(saved, sources: [], now: Date())
            if !vehicles.isEmpty { statusMessage = "Últimas posições salvas · buscando atualização…" }
        }
    }
    private func saveLastPositions() {
        guard let data = try? JSONEncoder().encode(vehicles.filter { $0.timestamp != nil }) else { return }
        try? data.write(to: cacheDirectory.appendingPathComponent("positions.json"), options: .atomic)
    }

    #if DEBUG
    private func prepareDemo() {
        var fixtures: [(route: TransitRoute, pattern: TransitPattern, baseProgress: Double, points: [GeoPoint])] = []
        var mapAnchor: GeoPoint?
        for shortName in ["369", "397", "SR397"] {
            guard let route = catalog?.routes.first(where: { $0.shortName == shortName }),
                  let pattern = patterns(for: route.id).first,
                  let visit = pattern.stops.dropFirst(5).first(where: { $0.distanceReliable && $0.distance > 1600 }) else { continue }
            let points = TransitGeometry.decodePolyline(pattern.polyline)
            guard points.count >= 2 else { continue }
            var baseProgress = visit.distance - 700
            if let anchor = mapAnchor {
                guard let projected = TransitGeometry.project(anchor, onto: points), projected.distance <= 1000 else { continue }
                baseProgress = projected.progress + Double(fixtures.count) * 150
            } else {
                mapAnchor = Self.point(at: baseProgress, on: points).0
            }
            fixtures.append((route, pattern, baseProgress, points))
        }
        guard fixtures.count == 3 else {
            statusMessage = "DEMONSTRAÇÃO · catálogo de teste incompleto"; return
        }
        let now = Date()
        for offset in [-60.0, -30.0, 0.0] {
            var batch: [TransitVehicle] = []
            for fixture in fixtures {
                for i in 0..<3 {
                    // Each line uses its own official shape. Offset variants slightly so markers do not coincide.
                    // The original 369 motion window is unchanged for deterministic arrival tests.
                    let progress = max(20, fixture.baseProgress - Double(i) * 320 + offset * 6)
                    let sample = Self.point(at: progress, on: fixture.points)
                    let identifier = "DEMO-\(fixture.route.shortName)-\(i)"
                    batch.append(TransitVehicle(id: "onibus:" + identifier, vehicleID: identifier,
                        label: "Teste \(fixture.route.shortName) · \(i + 1)", source: "onibus", routeID: fixture.route.id,
                        tripID: catalog?.tripPatterns.first(where: { $0.value == fixture.pattern.id })?.key, direction: fixture.pattern.direction,
                        latitude: sample.0.latitude, longitude: sample.0.longitude, bearing: sample.1, speed: 6, timestamp: now.addingTimeInterval(offset)))
                }
            }
            engine?.ingest(batch, now: now.addingTimeInterval(offset))
            if offset == 0 { vehicles = batch }
        }
        sourceStates = [SourceStatus(id: "onibus", name: "Ônibus · teste", lastSuccess: now, vehicleCount: vehicles.count, error: nil, feedTimestamp: now), SourceStatus(id: "brt", name: "BRT · teste", lastSuccess: now, vehicleCount: 0, error: nil, feedTimestamp: now)]
        recalculateArrivals()
        statusMessage = "DEMONSTRAÇÃO · posições simuladas para teste"
    }
    private static func point(at distance: Double, on points: [GeoPoint]) -> (GeoPoint, Double) {
        guard let first = points.first else { return (GeoPoint(latitude: -22.9, longitude: -43.2), 0) }
        var remaining = distance
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i]
            let length = TransitGeometry.distance(a, b)
            if remaining <= length, length > 0 {
                let t = remaining / length
                return (GeoPoint(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t), TransitGeometry.bearing(a, b))
            }
            remaining -= length
        }
        return (points.last ?? first, 0)
    }
    #endif
}

private struct SavedRouteSelection: Codable {
    let routeIDs: [String]
    let primaryRouteID: String?
    let patternID: String?
    let stopSequence: Int?
    let stopID: String?
}

private struct FetchOutcome: Sendable {
    let source: String
    let batch: RealtimeBatch?
    let message: String?
}
private enum StoreFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}
