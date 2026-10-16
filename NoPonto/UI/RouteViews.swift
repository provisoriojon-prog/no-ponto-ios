import SwiftUI
import MapKit

struct RouteSearchView: View {
    @EnvironmentObject private var store: TransitStore
    @FocusState private var searchFocused: Bool
    @ScaledMetric(relativeTo: .subheadline) private var rowHeight: CGFloat = 70
    let maxSuggestionsHeight: CGFloat
    let onSelect: (String) -> Void
    let onClose: () -> Void

    private var results: [TransitRoute] {
        guard canSuggest else { return [] }
        return Array(store.searchRoutes(store.searchText).prefix(8))
    }

    private var canSuggest: Bool {
        let digits = store.searchText.filter(\.isNumber).count
        return digits > 0 ? digits >= 2 : store.searchText.filter(\.isLetter).count >= 2
    }
    var body: some View {
        VStack(spacing: 8) {
            searchBar
            if canSuggest {
                suggestionsCard
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("route-search-overlay")
        .task { searchFocused = true }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Linha ou destino", text: $store.searchText)
                .font(.body).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityIdentifier("route-search-field")
            if !store.searchText.isEmpty {
                Button { store.searchText = ""; searchFocused = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 28, height: 40)
                }.buttonStyle(.plain).accessibilityLabel("Limpar busca")
                    .accessibilityIdentifier("clear-search-button")
            }
            Divider().frame(height: 23)
            Button { searchFocused = false; onClose() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.primary).frame(width: 40, height: 44)
            }.buttonStyle(.plain).accessibilityLabel("Fechar busca")
                .accessibilityIdentifier("close-search-button")
        }.padding(.leading, 16).padding(.trailing, 5).padding(.vertical, 5)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.14), radius: 9, y: 3)
    }

    private var suggestionsCard: some View {
        Group {
            if store.isLoading && store.catalog == nil {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if results.isEmpty {
                Text("Nenhuma linha encontrada").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(20)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(results) { route in
                            Button { searchFocused = false; onSelect(route.id) } label: {
                                RouteSearchRow(route: route)
                                    .padding(.horizontal, 14).frame(height: height(for: route))
                            }.buttonStyle(.plain).accessibilityIdentifier("route-row-\(route.id)")
                                .accessibilityLabel("\(route.isBRT ? "BRT" : "Linha") \(route.shortName), \(route.longName)")
                            if route.id != results.last?.id { Divider().padding(.leading, 14) }
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(maxSuggestionsHeight, results.reduce(0) { $0 + height(for: $1) } + CGFloat(max(0, results.count - 1))))
            }
        }
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.12), radius: 9, y: 3)
    }

    private func height(for route: TransitRoute) -> CGFloat { rowHeight + (route.isBRT ? 16 : 0) }
}

private struct RouteSearchRow: View {
    let route: TransitRoute
    var body: some View {
        HStack(spacing: 12) {
            RouteBadge(route: route, compact: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(route.longName).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                if route.isBRT { Text("BRT").font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 6).contentShape(Rectangle())
    }
}

struct LineDetailView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    @State private var showPatterns = false
    @State private var showStops = false
    @State private var showFavorite = false
    @State private var savedFavorite = false
    let onShowMap: (TransitStop) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let route = store.selectedRoute { routeHeader(route) }
                if let pattern = store.selectedPattern {
                    directionCard(pattern)
                    pointSection
                    arrivalsSection
                    walkingSection
                    InfoNote(symbol: "arrow.triangle.branch", text: "A seta do ônibus indica seu deslocamento. A bússola indica para onde seu celular aponta. Confirme o destino e o ponto: o GPS pode não distinguir as duas calçadas.")
                } else {
                    EmptyTransitState(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Percurso indisponível", message: "Esta linha está no catálogo, mas não tem sequência de pontos disponível. As posições podem continuar aparecendo no mapa.")
                }
            }.padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Sua linha").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPatterns) { PatternPickerView() }
        .sheet(isPresented: $showStops) { StopPickerView() }
        .sheet(isPresented: $showFavorite) { SaveFavoriteView { savedFavorite = true } }
        .onChange(of: store.selectedStop?.id) { _, _ in location.clearWalkingRoute() }
    }

    private func routeHeader(_ route: TransitRoute) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RouteBadge(route: route)
            VStack(alignment: .leading, spacing: 5) {
                Text(route.longName).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                Text(route.isBRT ? "BRT • Rio de Janeiro" : "Ônibus municipal • Rio de Janeiro").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func directionCard(_ pattern: TransitPattern) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("SENTIDO DO SEU EMBARQUE", systemImage: "arrow.right").font(.caption2.bold()).tracking(1).foregroundStyle(TransitStyle.teal)
            Text(pattern.headsign.isEmpty ? "Destino não informado" : pattern.headsign).font(.headline)
                .accessibilityIdentifier("selected-headsign")
            Text("\(pattern.stops.count) pontos neste percurso").font(.caption).foregroundStyle(.secondary)
            Button("Trocar sentido / percurso", systemImage: "arrow.left.arrow.right") { showPatterns = true }
                .font(.subheadline.bold()).accessibilityIdentifier("choose-pattern-button")
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(TransitStyle.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
    }

    private var pointSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Seu ponto").font(.headline)
                Spacer()
                Button(store.selectedStop == nil ? "Escolher" : "Trocar") { showStops = true }
                    .font(.subheadline.bold()).accessibilityIdentifier("choose-stop-button")
            }
            if let stop = store.selectedStop {
                VStack(alignment: .leading, spacing: 14) {
                    Label(stop.name, systemImage: "mappin.circle.fill").font(.subheadline.bold()).foregroundStyle(TransitStyle.teal)
                    if let point = location.point {
                        Text("\(distanceLabel(TransitGeometry.distance(point, stop.coordinate))) em linha reta de você")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Ver no mapa", systemImage: "map") { onShowMap(stop) }
                            .font(.subheadline).accessibilityIdentifier("show-stop-map-button")
                        Spacer()
                        Button(savedFavorite ? "Salvo" : "Salvar", systemImage: savedFavorite ? "bookmark.fill" : "bookmark") { showFavorite = true }
                            .font(.subheadline.bold()).accessibilityIdentifier("favorite-save-button")
                    }
                }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
            } else {
                Button { showStops = true } label: {
                    InfoNote(symbol: "hand.tap", text: "Escolha o ponto onde vai embarcar para ver os próximos ônibus nesse sentido.")
                }.buttonStyle(.plain)
            }
        }
    }

    private var arrivalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Próximos ônibus").font(.headline)
                Spacer()
                if store.isRefreshing { ProgressView().controlSize(.small) }
            }
            if store.selectedStop == nil {
                Text("As chegadas dependem do ponto e do sentido escolhidos.").font(.subheadline).foregroundStyle(.secondary)
            } else if store.arrivals.isEmpty {
                InfoNote(symbol: "clock.badge.questionmark", text: "Nenhum veículo com aproximação confirmada para este ponto agora. Isso não significa que a linha deixou de circular.", tint: .orange)
            } else {
                ForEach(Array(store.arrivals.prefix(3))) { arrival in ArrivalCard(arrival: arrival) }
            }
            Text("Previsões aproximadas, calculadas com dados públicos de GPS. Semáforos, trânsito e falhas de sinal podem mudar a chegada.")
                .font(.caption).foregroundStyle(.secondary)
        }.accessibilityIdentifier("arrivals-section")
    }

    @ViewBuilder private var walkingSection: some View {
        if let stop = store.selectedStop {
            VStack(alignment: .leading, spacing: 10) {
                Button { Task { await location.walk(to: stop) } } label: {
                    HStack {
                        Image(systemName: "figure.walk")
                        Text("Como chegar ao ponto").font(.subheadline.bold())
                        Spacer()
                        if location.isRouting { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.up.right") }
                    }.padding(15).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                }.buttonStyle(.plain).disabled(location.isRouting)
                if location.walkingDestination == stop.id, let route = location.walkingRoute {
                    Text("\(Int(ceil(route.expectedTravelTime / 60))) min a pé · \(distanceLabel(route.distance)) · Apple Maps")
                        .font(.subheadline.bold()).foregroundStyle(TransitStyle.teal)
                    Button("Mostrar caminhada no mapa") { onShowMap(stop) }.font(.subheadline)
                    ForEach(Array(route.steps.filter { !$0.instructions.isEmpty }.enumerated()), id: \.offset) { _, step in
                        Text(step.instructions).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = location.routeError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

func arrivalTimeLabel(_ arrival: ArrivalEstimate) -> String {
    guard let lower = arrival.secondsLower, let upper = arrival.secondsUpper else { return "Sem previsão" }
    if upper < 60 { return "Chegando" }
    let low = max(1, Int(floor(lower / 60)))
    let high = max(low, Int(ceil(upper / 60)))
    return low == high ? "\(low) min" : "\(low)–\(high) min"
}

private struct ArrivalCard: View {
    let arrival: ArrivalEstimate
    private var tint: Color { arrival.confidence == .good ? TransitStyle.teal : arrival.confidence == .limited ? .orange : .secondary }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(arrivalTimeLabel(arrival)).font(.title2.bold()).foregroundStyle(tint)
                Spacer()
                Text(arrival.confidence == .good ? "Movimento observado" : arrival.confidence == .limited ? "Precisão limitada" : "Dados insuficientes")
                    .font(.caption2.bold()).foregroundStyle(tint).multilineTextAlignment(.trailing)
            }
            Text(arrival.reason).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Veículo \(arrival.vehicleID.components(separatedBy: ":").last ?? arrival.vehicleID)")
                Spacer()
                if let age = arrival.positionAge { Text("GPS há \(Int(max(0, age))) s") }
                else { Text("GPS sem horário") }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(16).background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct PatternPickerView: View {
    @EnvironmentObject private var store: TransitStore
    @Environment(\.dismiss) private var dismiss
    private var patterns: [TransitPattern] { store.selectedRoute.map { store.patterns(for: $0.id) } ?? [] }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Escolha o destino indicado no ônibus. Percursos com o mesmo destino podem passar por pontos diferentes.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(Set(patterns.map(\.direction))).sorted(), id: \.self) { direction in
                    Section("Sentido \(direction + 1)") {
                        ForEach(Array(patterns.filter { $0.direction == direction }.enumerated()), id: \.element.id) { index, pattern in
                            Button {
                                store.selectPattern(pattern.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(pattern.headsign.isEmpty ? "Destino não informado" : pattern.headsign).font(.subheadline.bold()).foregroundStyle(.primary)
                                        Text("Percurso \(index + 1) · \(pattern.stops.count) pontos").font(.caption).foregroundStyle(.secondary)
                                        if let first = pattern.stops.first.flatMap({ store.stop($0.stopID) }), let last = pattern.stops.last.flatMap({ store.stop($0.stopID) }) {
                                            Text("\(first.name) → \(last.name)").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if pattern.id == store.selectedPatternID { Image(systemName: "checkmark.circle.fill").foregroundStyle(TransitStyle.teal) }
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("pattern-\(pattern.id)")
                                .accessibilityValue("sentido-\(pattern.direction)")
                        }
                    }
                }
            }.navigationTitle("Sentido e percurso").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseSheetButton { dismiss() } } }
        }
    }
}

struct StopPickerView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var visits: [StopVisit] {
        store.selectedVisits.filter { visit in
            query.isEmpty || (store.stop(visit.stopID)?.name.localizedStandardContains(query) ?? false)
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Em direção a \(store.selectedPattern?.headsign ?? "destino selecionado")").font(.subheadline.bold()).foregroundStyle(TransitStyle.teal)
                    Text("Confirme o nome e o lado da via antes de embarcar. A numeração abaixo segue a ordem do percurso.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Pontos na ordem do trajeto") {
                    ForEach(visits, id: \.sequence) { visit in
                        if let stop = store.stop(visit.stopID) {
                            Button {
                                store.selectStop(sequence: visit.sequence)
                                dismiss()
                            } label: {
                                HStack(spacing: 13) {
                                    Text("\(visit.sequence)").font(.caption.bold()).foregroundStyle(TransitStyle.teal).frame(width: 29)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(stop.name).font(.subheadline).foregroundStyle(.primary)
                                        if let point = location.point {
                                            Text("\(distanceLabel(TransitGeometry.distance(point, stop.coordinate))) em linha reta").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if visit.sequence == store.selectedStopSequence { Image(systemName: "checkmark.circle.fill").foregroundStyle(TransitStyle.teal) }
                                }.padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("stop-\(visit.sequence)")
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Buscar ponto neste percurso")
            .navigationTitle("Ponto de embarque").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseSheetButton { dismiss() } } }
        }
    }
}
