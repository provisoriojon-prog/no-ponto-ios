import SwiftUI

struct NearbyStopsView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    let onSelect: (TransitStop) -> Void

    var body: some View {
        Group {
            if let point = location.point {
                List {
                    Section {
                        InfoNote(symbol: "location.circle", text: "\(location.accuracyText). A distância abaixo é em linha reta. Confirme o lado da via e o destino antes de escolher o ponto.")
                    }
                    Section("Mais perto de você") {
                        ForEach(store.nearestStops(to: point, limit: 25)) { stop in
                            Button { onSelect(stop) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(TransitStyle.teal)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(stop.name).font(.subheadline).foregroundStyle(.primary)
                                        Text("\(distanceLabel(TransitGeometry.distance(point, stop.coordinate))) em linha reta").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }.padding(.vertical, 5)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                VStack(spacing: 20) {
                    EmptyTransitState(symbol: "location.slash", title: location.isDenied ? "Localização desativada" : "Encontrando sua posição", message: location.message ?? "Precisamos da sua localização para ordenar os pontos próximos. Você também pode escolher um ponto buscando uma linha.")
                    if !location.isDenied { Button("Tentar localizar novamente") { location.requestLocation() }.buttonStyle(.borderedProminent) }
                }
            }
        }.navigationTitle("Pontos próximos").navigationBarTitleDisplayMode(.inline)
    }
}

struct StopDetailView: View {
    @EnvironmentObject private var store: TransitStore
    let stop: TransitStop
    let onSelect: (TransitPattern, StopVisit) -> Void

    private var services: [(TransitPattern, StopVisit)] {
        (store.catalog?.patterns ?? []).flatMap { pattern in
            pattern.stops.filter { $0.stopID == stop.id }.map { (pattern, $0) }
        }
    }

    var body: some View {
        List {
            Section {
                Label(stop.name, systemImage: "mappin.circle.fill").font(.headline).foregroundStyle(TransitStyle.teal)
                Text("Escolha a linha e o destino do seu embarque. Percursos diferentes podem compartilhar este ponto.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Linhas neste ponto") {
                if services.isEmpty {
                    Text("Não há linhas associadas a este ponto no catálogo atual.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(Array(services.enumerated()), id: \.offset) { _, service in
                    if let route = store.route(service.0.routeID) {
                        Button { onSelect(service.0, service.1) } label: {
                            HStack(spacing: 12) {
                                RouteBadge(route: route, compact: true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(service.0.headsign).font(.subheadline.bold()).foregroundStyle(.primary)
                                    Text("\(service.0.stops.count) pontos no percurso · posição \(service.1.sequence)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }.padding(.vertical, 5)
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.navigationTitle("Este ponto").navigationBarTitleDisplayMode(.inline)
    }
}
