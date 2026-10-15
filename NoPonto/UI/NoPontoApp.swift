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
    case search, line, favorites, settings, nearby, stop
    var id: String { rawValue }
}

struct TransitHomeView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    @State private var sheet: TransitSheet?
    @State private var mapFocus: MapFocus?
    @State private var followsHeading = false
    @State private var awaitingLocation = false
    @State private var inspectedStop: TransitStop?

    private var displayedStops: [TransitStop] {
        guard let pattern = store.selectedPattern else { return store.catalog?.stops ?? [] }
        var seen = Set<String>()
        return pattern.stops.compactMap { visit in
            guard seen.insert(visit.stopID).inserted else { return nil }
            return store.stop(visit.stopID)
        }
    }

    var body: some View {
        ZStack {
            TransitMap(routes: store.catalog?.routes ?? [], pattern: store.selectedPattern,
                       stops: displayedStops, selectedStopID: store.selectedStop?.id,
                       vehicles: store.visibleVehicles(), showStops: store.showStops,
                       location: location.currentLocation, walkingRoute: location.walkingRoute,
                       focus: mapFocus, followHeading: followsHeading,
                       onStop: inspectStop, onVehicle: selectRoute)
                .ignoresSafeArea()
                .accessibilityIdentifier("transit-map")
            VStack(spacing: 10) {
                topBar
                if store.isDemoMode { demoBanner }
                Spacer(minLength: 12)
                mapTools
                bottomPanel
            }.padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 8)
        }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                sheetContent(destination)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseSheetButton { sheet = nil } } }
                    .toolbarBackground(.visible, for: .navigationBar)
            }
            .presentationDetents(destination == .line ? [.large] : [.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onReceive(location.$location) { value in
            guard awaitingLocation, let value else { return }
            awaitingLocation = false
            mapFocus = MapFocus(point: GeoPoint(latitude: value.coordinate.latitude, longitude: value.coordinate.longitude))
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { sheet = .search } label: {
                HStack(spacing: 11) {
                    Image(systemName: "bus.fill").font(.title3).foregroundStyle(TransitStyle.teal)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No Ponto").font(.headline).foregroundStyle(.primary)
                        Text("Buscar linha ou destino").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "magnifyingglass").font(.title3).foregroundStyle(TransitStyle.teal)
                }.padding(14).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            }.buttonStyle(.plain).accessibilityIdentifier("search-button")
            Button { sheet = .favorites } label: {
                Image(systemName: "bookmark.fill").font(.title3).frame(width: 48, height: 55)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }.accessibilityLabel("Favoritos").accessibilityIdentifier("favorites-button")
        }.shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }

    private var demoBanner: some View {
        Label("DEMONSTRAÇÃO · dados de teste", systemImage: "testtube.2")
            .font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 7)
            .background(.yellow, in: Capsule()).foregroundStyle(.black)
            .accessibilityIdentifier("demo-banner")
    }

    private var mapTools: some View {
        HStack(alignment: .bottom) {
            if let message = location.message {
                Text(message).font(.caption).padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).frame(maxWidth: 245)
                    .accessibilityIdentifier("location-message")
            } else if let heading = location.currentHeading {
                Label("\(Int((heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading).rounded()))° · \(location.accuracyText)", systemImage: "location.north.line")
                    .font(.caption2).padding(10).background(.regularMaterial, in: Capsule())
            }
            Spacer(minLength: 8)
            VStack(spacing: 9) {
                RoundMapButton(symbol: "slider.horizontal.3", label: "Mapa e fontes de dados") { sheet = .settings }
                RoundMapButton(symbol: "mappin.and.ellipse", label: "Pontos próximos") { location.requestLocation(); sheet = .nearby }
                RoundMapButton(symbol: followsHeading ? "location.north.line.fill" : "location.north.line", label: "Orientar mapa pela bússola", selected: followsHeading) {
                    location.requestLocation()
                    followsHeading.toggle()
                }
                RoundMapButton(symbol: "location.fill", label: "Minha localização") { recenter() }
                    .accessibilityIdentifier("my-location-button")
            }
        }
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.selectedRouteIDs.isEmpty { routeChips }
            if let route = store.selectedRoute {
                Button { sheet = .line } label: {
                    HStack(alignment: .center, spacing: 12) {
                        RouteBadge(route: route)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.selectedPattern?.headsign ?? route.longName).font(.subheadline.bold()).lineLimit(2)
                            if let stop = store.selectedStop {
                                Text(stop.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else {
                                Text("Escolha seu ponto de embarque").font(.caption).foregroundStyle(TransitStyle.teal)
                            }
                        }
                        Spacer(minLength: 3)
                        Image(systemName: "chevron.up").font(.footnote.bold()).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("line-detail-button")
                if store.selectedStop != nil { compactArrival }
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "point.bottomleft.forward.to.point.topright.scurvepath").font(.title2).foregroundStyle(TransitStyle.teal)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Seu próximo ônibus, aqui.").font(.headline)
                        Text("Escolha uma linha e confirme o sentido.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button("Encontrar minha linha", systemImage: "magnifyingglass") { sheet = .search }
                    .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            }
            HStack(spacing: 6) {
                Circle().fill(store.sourceStates.contains(where: { $0.error == nil && $0.lastSuccess != nil }) ? TransitStyle.teal : Color.orange).frame(width: 6, height: 6)
                Text(store.statusMessage).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                Button { Task { await store.refresh() } } label: {
                    if store.isRefreshing { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "arrow.clockwise").font(.footnote.bold()) }
                }.frame(width: 30, height: 30).disabled(store.isRefreshing).accessibilityLabel("Atualizar posições")
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).strokeBorder(.primary.opacity(0.04)))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 5)
    }

    private var routeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(store.selectedRouteIDs.sorted(), id: \.self) { routeID in
                    if let route = store.route(routeID) {
                        HStack(spacing: 6) {
                            Button { store.selectRoute(routeID) } label: { Text(route.shortName).font(.caption.bold()) }
                            Button { store.toggleRoute(routeID) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 22, height: 24) }
                                .accessibilityLabel("Remover linha \(route.shortName)")
                        }.padding(.leading, 10).padding(.trailing, 3).padding(.vertical, 3)
                            .foregroundStyle(store.selectedRoute?.id == routeID ? .white : TransitStyle.routeColor(route))
                            .background(store.selectedRoute?.id == routeID ? TransitStyle.routeColor(route) : TransitStyle.routeColor(route).opacity(0.10), in: Capsule())
                    }
                }
                Button { sheet = .search } label: { Image(systemName: "plus").font(.caption.bold()).frame(width: 32, height: 32) }
                    .background(TransitStyle.teal.opacity(0.10), in: Circle()).accessibilityLabel("Adicionar outra linha")
            }
        }
    }

    private var compactArrival: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let next = store.arrivals.first, next.secondsLower != nil, next.secondsUpper != nil {
                Text(arrivalTimeLabel(next)).font(.title3.bold()).foregroundStyle(TransitStyle.teal)
                Text(next.confidence == .good ? "até seu ponto" : "previsão limitada").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("Aguardando previsão confiável", systemImage: "clock.badge.questionmark").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder private func sheetContent(_ destination: TransitSheet) -> some View {
        switch destination {
        case .search: RouteSearchView { routeID in selectRoute(routeID) }
        case .line: LineDetailView { stop in mapFocus = MapFocus(point: stop.coordinate); sheet = nil }
        case .favorites: FavoritesView { favorite in store.openFavorite(favorite); sheet = .line }
        case .settings: TransitSettingsView()
        case .nearby: NearbyStopsView { stop in inspectedStop = stop; sheet = .stop }
        case .stop:
            if let inspectedStop { StopDetailView(stop: inspectedStop) { pattern, visit in
                store.selectRoute(pattern.routeID)
                store.selectPattern(pattern.id)
                store.selectStop(sequence: visit.sequence)
                sheet = .line
            } }
        }
    }

    private func selectRoute(_ routeID: String) {
        guard store.route(routeID) != nil else { return }
        store.selectRoute(routeID)
        followsHeading = false
        sheet = .line
    }

    private func inspectStop(_ stopID: String) {
        let visits = store.selectedPattern?.stops.filter { $0.stopID == stopID } ?? []
        if visits.count == 1, let visit = visits.first {
            store.selectStop(sequence: visit.sequence)
            sheet = .line
        } else if let stop = store.stop(stopID) { inspectedStop = stop; sheet = .stop }
    }

    private func recenter() {
        followsHeading = false
        location.requestLocation()
        if let point = location.point { mapFocus = MapFocus(point: point) }
        else { awaitingLocation = true }
    }
}
