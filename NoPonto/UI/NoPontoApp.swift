import SwiftUI

@main
struct NoPontoApp: App {
    @StateObject private var store = TransitStore()
    @StateObject private var location = LocationService()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            TransitHomeView()
                .environmentObject(store)
                .environmentObject(location)
                .tint(TransitStyle.teal)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { await store.start() }
                .onChange(of: scenePhase) { _, phase in
                    store.setActive(phase == .active)
                    location.setActive(phase == .active)
                }
        }
    }
}

private enum TransitSheet: String, Identifiable {
    case search, line, favorites, settings, nearby, stop, savedRoutes
    var id: String { rawValue }
}

struct TransitHomeView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    @State private var sheet: TransitSheet?
    @State private var mapFocus: MapFocus?
    @State private var followsHeading = false
    @State private var awaitingLocation = false
    @State private var locationFeedbackRequested = false
    @State private var locationAlert: String?
    @State private var inspectedStop: TransitStop?
    @State private var showsContext = false

    private var displayedPatterns: [TransitPattern] {
        var patterns: [TransitPattern] = []
        for route in store.savedRoutes {
            var directions = Set<Int>()
            for pattern in store.patterns(for: route.id) where directions.insert(pattern.direction).inserted {
                patterns.append(pattern)
            }
        }
        if let selected = store.selectedPattern, !patterns.contains(where: { $0.id == selected.id }) {
            patterns.append(selected)
        }
        return patterns
    }

    private var displayedStops: [TransitStop] {
        var seen = Set<String>()
        return displayedPatterns.flatMap(\.stops).compactMap { visit in
            guard seen.insert(visit.stopID).inserted else { return nil }
            return store.stop(visit.stopID)
        }
    }

    var body: some View {
        ZStack {
            TransitMap(routes: store.catalog?.routes ?? [], patterns: displayedPatterns,
                       focusedPatternID: store.selectedPatternID, stops: displayedStops,
                       selectedStopID: store.selectedStop?.id, vehicles: store.visibleVehicles(),
                       showStops: store.showStops, location: location.currentLocation,
                       walkingRoute: location.walkingRoute, focus: mapFocus,
                       followHeading: followsHeading, onStop: inspectStop, onVehicle: inspectRoute)
                .ignoresSafeArea().accessibilityIdentifier("transit-map")
            VStack {
                HStack { Spacer(); settingsMenu }
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if !store.savedRoutes.isEmpty { savedRouteStack }
                    Spacer(minLength: 24)
                    mapButtons
                }
            }.padding(.horizontal, 16).padding(.top, 7).padding(.bottom, 34)
            if showsContext {
                contextualCard.padding(.horizontal, 78)
                    .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 164)
            }
            if store.isDemoMode && !store.savedRoutes.isEmpty {
                Text("DEMONSTRAÇÃO").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
                    .accessibilityIdentifier("demo-banner")
            }
        }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                sheetContent(destination)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseSheetButton { sheet = nil } } }
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .presentationDetents(destination == .line || destination == .settings ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .alert("Localização", isPresented: Binding(get: { locationAlert != nil }, set: { if !$0 { locationAlert = nil } })) {
            Button("OK") { locationAlert = nil }
        } message: { Text(locationAlert ?? "") }
        .onReceive(location.$location) { value in
            guard awaitingLocation, let value else { return }
            awaitingLocation = false
            locationFeedbackRequested = false
            mapFocus = MapFocus(point: GeoPoint(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude))
        }
        .onReceive(location.$message) { message in
            guard locationFeedbackRequested, let message else { return }
            locationFeedbackRequested = false
            awaitingLocation = false
            locationAlert = message
        }
    }

    private var settingsMenu: some View {
        Menu {
            Button("Mapa e preferências", systemImage: "slider.horizontal.3") { sheet = .settings }
            Button("Favoritos de embarque", systemImage: "bookmark") { sheet = .favorites }
                .accessibilityIdentifier("favorites-button")
            Button("Pontos próximos", systemImage: "mappin.and.ellipse") { location.requestLocation(); sheet = .nearby }
            Button("Linhas salvas", systemImage: "list.bullet") { sheet = .savedRoutes }
            Button(followsHeading ? "Parar orientação pela bússola" : "Orientar pela bússola", systemImage: "location.north.line") {
                locationFeedbackRequested = true
                location.requestLocation()
                followsHeading.toggle()
            }
        } label: {
            Image(systemName: "gearshape.fill").font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary).frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
        }.accessibilityLabel("Opções").accessibilityIdentifier("settings-menu")
    }

    private var mapButtons: some View {
        VStack(spacing: 12) {
            RoundMapButton(symbol: "location.fill", label: "Minha localização") { recenter() }
                .accessibilityIdentifier("my-location-button")
            Button {
                store.searchText = ""
                showsContext = false
                sheet = .search
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white).frame(width: 58, height: 58)
                    .background(TransitStyle.teal, in: Circle())
                    .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
            }.accessibilityLabel("Buscar linha").accessibilityIdentifier("search-button")
                .accessibilityValue(store.isLoading ? "carregando" : "pronto")
        }
    }

    private var savedRouteStack: some View {
        VStack(spacing: 7) {
            Menu {
                Button("Gerenciar linhas", systemImage: "list.bullet") { sheet = .savedRoutes }
                Button("Favoritos de embarque", systemImage: "bookmark") { sheet = .favorites }
                Button("Remover todas", systemImage: "trash", role: .destructive) { removeAllRoutes() }
                    .accessibilityIdentifier("remove-all-routes")
            } label: {
                Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary).frame(width: 38, height: 38)
                    .background(.regularMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            }.accessibilityLabel("Opções das linhas salvas").accessibilityIdentifier("saved-routes-menu")
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(store.savedRoutes) { route in savedRouteButton(route) }
                }.padding(3)
            }.frame(width: 54, height: min(CGFloat(store.savedRoutes.count) * 53 + 6, 270))
        }
    }

    private func savedRouteButton(_ route: TransitRoute) -> some View {
        Button {
            if store.selectedRoute?.id == route.id && showsContext && inspectedStop == nil { sheet = .line }
            else { inspectRoute(route.id) }
        } label: {
            Text(route.shortName).font(.system(size: route.shortName.count > 4 ? 11 : 14, weight: .bold))
                .minimumScaleFactor(0.65).lineLimit(1).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(TransitStyle.routeColor(route), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(store.selectedRoute?.id == route.id ? 0.95 : 0.6), lineWidth: store.selectedRoute?.id == route.id ? 2.5 : 1.5))
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain).accessibilityLabel("Linha \(route.shortName)")
        .accessibilityIdentifier("saved-route-\(route.id)")
        .contextMenu {
            Button("Ver linha e pontos", systemImage: "bus") { store.selectRoute(route.id); sheet = .line }
            Button("Remover linha", systemImage: "trash", role: .destructive) {
                store.removeRoute(route.id)
                showsContext = false
            }
        }
    }

    private var contextualCard: some View {
        HStack(spacing: 8) {
            Button { sheet = inspectedStop == nil ? .line : .stop } label: {
                HStack(spacing: 9) {
                    Image(systemName: inspectedStop == nil ? "bus.fill" : "mappin.circle.fill").foregroundStyle(TransitStyle.teal)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contextTitle).font(.subheadline.bold()).lineLimit(1)
                        Text(contextSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("line-detail-button")
            Button { showsContext = false } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 32)
            }.foregroundStyle(.secondary).accessibilityLabel("Fechar informação")
        }.padding(.leading, 13).padding(.trailing, 6).padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.13), radius: 9, y: 3)
            .accessibilityIdentifier("contextual-arrival")
    }

    private var contextTitle: String { inspectedStop?.name ?? "Linha \(store.selectedRoute?.shortName ?? "")" }
    private var contextSubtitle: String {
        if inspectedStop != nil { return "Linhas neste ponto" }
        if store.selectedStop != nil, let next = store.arrivals.first, next.secondsLower != nil {
            return "\(arrivalTimeLabel(next))\(next.confidence == .limited ? " · aprox." : "")"
        }
        return store.selectedPattern?.headsign ?? "Ver pontos e sentido"
    }

    @ViewBuilder private func sheetContent(_ destination: TransitSheet) -> some View {
        switch destination {
        case .search: RouteSearchView { routeID in
            store.selectRoute(routeID)
            followsHeading = false
            showsContext = false
            inspectedStop = nil
            sheet = nil
        }
        case .line: LineDetailView { stop in mapFocus = MapFocus(point: stop.coordinate); sheet = nil; showsContext = true }
        case .favorites: FavoritesView { favorite in store.openFavorite(favorite); sheet = nil; showsContext = false }
        case .settings: TransitSettingsView()
        case .nearby: NearbyStopsView { stop in inspectedStop = stop; sheet = .stop }
        case .savedRoutes: savedRoutesManager
        case .stop:
            if let inspectedStop { StopDetailView(stop: inspectedStop) { pattern, visit in
                store.selectRoute(pattern.routeID)
                store.selectPattern(pattern.id)
                store.selectStop(sequence: visit.sequence)
                self.inspectedStop = nil
                sheet = nil
                showsContext = true
            } }
        }
    }

    private var savedRoutesManager: some View {
        List {
            ForEach(store.savedRoutes) { route in
                Button { store.selectRoute(route.id); sheet = .line } label: {
                    HStack(spacing: 12) {
                        RouteBadge(route: route, compact: true)
                        Text(route.longName).font(.subheadline).foregroundStyle(.primary)
                    }
                }.swipeActions {
                    Button("Remover", role: .destructive) { store.removeRoute(route.id); showsContext = false }
                }
            }
            if !store.savedRoutes.isEmpty {
                Button("Remover todas", role: .destructive) { removeAllRoutes(); sheet = nil }
                    .accessibilityIdentifier("remove-all-routes")
            }
        }.overlay { if store.savedRoutes.isEmpty { Text("Nenhuma linha salva").foregroundStyle(.secondary) } }
            .navigationTitle("Linhas salvas").navigationBarTitleDisplayMode(.inline)
    }

    private func inspectRoute(_ routeID: String) {
        guard store.route(routeID) != nil else { return }
        store.selectRoute(routeID)
        followsHeading = false
        inspectedStop = nil
        showsContext = true
    }

    private func inspectStop(_ stopID: String) {
        let visits = store.selectedPattern?.stops.filter { $0.stopID == stopID } ?? []
        if visits.count == 1, let visit = visits.first {
            store.selectStop(sequence: visit.sequence)
            inspectedStop = nil
        } else { inspectedStop = store.stop(stopID) }
        showsContext = inspectedStop != nil || store.selectedRoute != nil
    }

    private func removeAllRoutes() {
        store.removeAllRoutes()
        location.clearWalkingRoute()
        inspectedStop = nil
        showsContext = false
    }

    private func recenter() {
        followsHeading = false
        locationFeedbackRequested = true
        location.requestLocation()
        if let point = location.point {
            locationFeedbackRequested = false
            mapFocus = MapFocus(point: point)
        } else { awaitingLocation = true }
    }
}
