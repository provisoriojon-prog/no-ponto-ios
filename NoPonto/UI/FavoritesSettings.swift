import SwiftUI
import UIKit

struct SaveFavoriteView: View {
    @EnvironmentObject private var store: TransitStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var group = "Ida"
    @State private var customGroup = ""
    let onSaved: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Dê um nome para este embarque") {
                    TextField("Ex.: Trabalho de manhã", text: $name).accessibilityIdentifier("favorite-name-field")
                    Picker("Grupo", selection: $group) {
                        Text("Ida").tag("Ida")
                        Text("Volta").tag("Volta")
                        Text("Outro").tag("custom")
                    }.pickerStyle(.segmented)
                    if group == "custom" { TextField("Nome do grupo", text: $customGroup) }
                }
                Section("Será salvo") {
                    if let route = store.selectedRoute { LabeledContent("Linha", value: route.shortName) }
                    LabeledContent("Destino", value: store.selectedPattern?.headsign ?? "—")
                    LabeledContent("Ponto", value: store.selectedStop?.name ?? "—")
                }
                Section {
                    Button {
                        store.addFavorite(name: name.trimmingCharacters(in: .whitespacesAndNewlines), group: resolvedGroup)
                        onSaved()
                        dismiss()
                    } label: {
                        Label("Salvar favorito", systemImage: "bookmark.fill").frame(maxWidth: .infinity)
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.selectedStop == nil || resolvedGroup.isEmpty)
                    .accessibilityIdentifier("confirm-favorite-button")
                } footer: {
                    Text("Linha, sentido, percurso e ponto ficam guardados neste iPhone.")
                }
            }
            .navigationTitle("Salvar embarque").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { CloseSheetButton { dismiss() } } }
            .onAppear { if name.isEmpty { name = "\(store.selectedRoute?.shortName ?? "Linha") · \(store.selectedPattern?.headsign ?? "Meu ponto")" } }
        }
    }

    private var resolvedGroup: String { (group == "custom" ? customGroup : group).trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct FavoritesView: View {
    @EnvironmentObject private var store: TransitStore
    let onOpen: (FavoriteJourney) -> Void
    private var groups: [String] { Array(Set(store.favorites.map(\.group))).sorted() }
    var body: some View {
        Group {
            if store.favorites.isEmpty {
                EmptyTransitState(symbol: "bookmark", title: "Seus embarques de todo dia", message: "Abra uma linha, escolha sentido e ponto, e toque em Salvar. Seus favoritos aparecem aqui, separados em Ida, Volta ou seus próprios grupos.")
            } else {
                List {
                    ForEach(groups, id: \.self) { group in
                        Section(group) {
                            ForEach(store.favorites.filter { $0.group == group }) { favorite in
                                favoriteRow(favorite)
                            }
                        }
                    }
                    Section {
                        Text("Deslize um favorito para a esquerda para removê-lo.").font(.caption).foregroundStyle(.secondary)
                    }
                }.listStyle(.insetGrouped)
            }
        }.navigationTitle("Seus favoritos").navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("favorites-list")
    }

    private func valid(_ favorite: FavoriteJourney) -> Bool {
        guard let pattern = store.catalog?.patterns.first(where: { $0.id == favorite.patternID && $0.routeID == favorite.routeID }) else { return false }
        return pattern.stops.contains { $0.stopID == favorite.stopID && $0.sequence == favorite.stopSequence }
    }

    private func favoriteRow(_ favorite: FavoriteJourney) -> some View {
        let available = valid(favorite)
        return Button { if available { onOpen(favorite) } } label: {
            HStack(alignment: .top, spacing: 12) {
                if let route = store.route(favorite.routeID) { RouteBadge(route: route, compact: true) }
                else { Image(systemName: "bookmark.slash").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 5) {
                    Text(favorite.name).font(.subheadline.bold()).foregroundStyle(.primary)
                    Text(store.stop(favorite.stopID)?.name ?? "Ponto indisponível").font(.caption).foregroundStyle(.secondary)
                    if !available { Text("O catálogo mudou. Escolha e salve o ponto novamente.").font(.caption).foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
                Image(systemName: available ? "chevron.right" : "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }.padding(.vertical, 7).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("favorite-\(favorite.id.uuidString)")
            .swipeActions { Button("Remover", role: .destructive) { store.removeFavorite(favorite.id) } }
    }
}

struct TransitSettingsView: View {
    @EnvironmentObject private var store: TransitStore
    @EnvironmentObject private var location: LocationService
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        Form {
            Section("Seu mapa") {
                Toggle("Mostrar pontos e estações", isOn: $store.showStops)
                Toggle("Mostrar veículos com sinal antigo", isOn: $store.showStaleVehicles)
                Picker("Aparência", selection: $appearance) {
                    Text("Automática").tag("system")
                    Text("Clara").tag("light")
                    Text("Escura").tag("dark")
                }
            }
            Section {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ForEach(store.sourceStates) { source in SourceHealthRow(source: source, now: context.date) }
                }
                Button("Atualizar posições agora", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    .disabled(store.isRefreshing)
                Text("Atualizações enquanto o app está aberto. Um servidor funcionando não garante que todos os veículos estejam transmitindo.")
                    .font(.caption).foregroundStyle(.secondary)
                if store.unknownRouteCount > 0 {
                    Text("\(store.unknownRouteCount) identificadores de linha ao vivo ainda sem correspondência no catálogo. Esses veículos aparecem com ? e não recebem estimativas.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: { Text("Fontes ao vivo") }
            Section("Catálogo e cobertura") {
                LabeledContent("Linhas", value: "\(store.catalog?.routes.count ?? 0)")
                LabeledContent("Pontos e estações", value: "\(store.catalog?.stops.count ?? 0)")
                Text(store.catalogNotice).font(.caption).foregroundStyle(.secondary)
                Button {
                    Task { await store.updateCatalog(silent: false) }
                } label: {
                    HStack {
                        Label("Verificar atualização do catálogo", systemImage: "arrow.down.circle")
                        Spacer()
                        if store.isUpdatingCatalog { ProgressView().controlSize(.small) }
                    }
                }.disabled(store.isUpdatingCatalog)
                Text("Ônibus municipais e BRT do Rio de Janeiro. Linhas intermunicipais de outras cidades não fazem parte desta cobertura.").font(.caption).foregroundStyle(.secondary)
                if let catalog = store.catalog {
                    LabeledContent("Vigência", value: "\(catalog.validFrom) a \(catalog.validUntil)").font(.caption)
                }
            }
            Section("Sua localização") {
                Text(location.accuracyText).font(.subheadline)
                if location.reducedAccuracy { Text("Localização aproximada ativada. Para distinguir pontos próximos, permita localização precisa nos Ajustes.").font(.caption).foregroundStyle(.orange) }
                Button(location.isDenied ? "Abrir Ajustes do iPhone" : "Usar minha localização", systemImage: "location") {
                    if location.isDenied, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    else { location.requestLocation() }
                }
                Text("Confirme sempre o ponto e o destino. A precisão do GPS e da bússola varia; o app não determina com certeza em qual calçada você está.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Sem anúncios. Sem cadastro.") {
                Text("Favoritos ficam neste aparelho. A localização orienta o mapa e os pontos próximos. Ao calcular uma caminhada, origem e destino são enviados ao Apple Maps. Mapas e fontes públicas precisam de internet.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Sem conexão, o catálogo e os favoritos continuam disponíveis. Posições guardadas mantêm a data do sinal e não são apresentadas como movimento ao vivo.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Créditos e dados") {
                Link("SMTR · Catálogo GTFS", destination: URL(string: "https://dados.mobilidade.rio/gtfs/schedule")!)
                Link("DATA.RIO · Dados públicos", destination: URL(string: "https://www.data.rio/")!)
                Text("Mapa e rotas a pé: Apple Maps. Dados de transporte: Prefeitura do Rio / SMTR. Aplicativo independente, sem vínculo com a Prefeitura ou com outros aplicativos de ônibus.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("No Ponto · \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Mapa e informações").navigationBarTitleDisplayMode(.inline)
    }
}

private struct SourceHealthRow: View {
    let source: SourceStatus
    let now: Date
    private var warnings: [String] { source.qualityWarnings(at: now) }
    private var healthy: Bool { source.error == nil && source.lastSuccess != nil && warnings.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(source.name, systemImage: healthy ? "dot.radiowaves.left.and.right" : "exclamationmark.circle")
                    .foregroundStyle(healthy ? TransitStyle.teal : .orange)
                Spacer()
                Text("\(source.vehicleCount) veículos").font(.caption).foregroundStyle(.secondary)
            }
            Text("Resposta válida recebida: \(sourceAgeLabel(source.lastSuccess, now: now))").font(.caption).foregroundStyle(.secondary)
            Text("Horário informado pela fonte: \(sourceAgeLabel(source.feedTimestamp, now: now))").font(.caption).foregroundStyle(.secondary)
            if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange) }
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
        }.padding(.vertical, 4)
    }
}
