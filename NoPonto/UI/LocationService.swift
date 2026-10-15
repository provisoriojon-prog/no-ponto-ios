import CoreLocation
import MapKit
import SwiftUI

final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var heading: CLHeading?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var reducedAccuracy = false
    @Published private(set) var message: String?
    @Published private(set) var walkingRoute: MKRoute?
    @Published private(set) var walkingDestination: String?
    @Published private(set) var isRouting = false
    @Published private(set) var routeError: String?
    private let manager = CLLocationManager()
    private var requested = false
    private var active = true
    private var directions: MKDirections?
    private var locationExpiry: DispatchWorkItem?
    private var lastFixExpired = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        // A passenger can stand still at a stop: movement filtering must not
        // suppress fresh fixes and make the 60-second safety expiry misleading.
        // Updates are stopped whenever the app is inactive.
        manager.distanceFilter = kCLDistanceFilterNone
        manager.headingFilter = 8
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    var currentLocation: CLLocation? {
        guard active, authorization == .authorizedWhenInUse || authorization == .authorizedAlways,
              let location, Self.isFresh(location) else { return nil }
        return location
    }

    var currentHeading: CLHeading? {
        guard currentLocation != nil, let heading,
              heading.headingAccuracy >= 0, abs(heading.timestamp.timeIntervalSinceNow) <= 60 else { return nil }
        return heading
    }

    var point: GeoPoint? {
        guard let location = currentLocation else { return nil }
        return GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var accuracyText: String {
        if isDenied { return "Localização desativada" }
        if lastFixExpired { return "Posição expirada · atualize a localização" }
        guard let location else { return "Sem posição recente · toque em localizar" }
        guard Self.isFresh(location) else { return "Posição expirada · atualize a localização" }
        return "Precisão de cerca de \(Int(location.horizontalAccuracy.rounded())) m"
    }

    func requestLocation() {
        requested = true
        message = nil
        discardExpiredLocation()
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if isDenied {
            clearLocation()
            message = "Ative Localização nos Ajustes do iPhone para encontrar pontos perto de você."
        }
        else { beginUpdates() }
    }

    func setActive(_ value: Bool) {
        active = value
        if value && requested {
            discardExpiredLocation()
            beginUpdates()
        } else {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            clearLocation()
        }
    }

    private func beginUpdates() {
        guard active, requested, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if isDenied {
            manager.stopUpdatingLocation()
            manager.stopUpdatingHeading()
            clearLocation()
            message = "Localização desativada. Você pode buscar uma linha e escolher seu ponto no mapa."
            return
        }
        beginUpdates()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard active, !isDenied, let value = locations.last, Self.isFresh(value) else {
            discardExpiredLocation()
            return
        }
        location = value
        lastFixExpired = false
        message = nil
        scheduleExpiry(for: value)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = active && !isDenied && newHeading.headingAccuracy >= 0 ? newHeading : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if isDenied || (error as? CLError)?.code == .denied {
            clearLocation()
            message = "Localização desativada. Você pode buscar uma linha e escolher seu ponto no mapa."
        } else if currentLocation == nil {
            clearLocation()
            message = "Não foi possível obter uma posição recente. Escolha o ponto manualmente ou tente novamente."
        } else {
            message = "Localização temporariamente indisponível. A última posição ainda é recente e será descartada ao expirar."
        }
    }

    @MainActor func walk(to stop: TransitStop) async {
        guard let location = currentLocation else {
            clearWalkingRoute()
            requestLocation()
            routeError = "É necessária uma posição recente. Aguarde a localização e toque novamente para calcular a caminhada."
            return
        }
        directions?.cancel()
        walkingRoute = nil
        walkingDestination = stop.id
        routeError = nil
        isRouting = true
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: location.coordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: stop.latitude, longitude: stop.longitude)))
        request.transportType = .walking
        let operation = MKDirections(request: request)
        directions = operation
        do {
            let response = try await operation.calculate()
            guard directions === operation else { return }
            guard currentLocation != nil else {
                clearWalkingRoute()
                routeError = "A posição expirou durante o cálculo. Atualize a localização e tente novamente."
                return
            }
            walkingRoute = response.routes.first
            if walkingRoute == nil { routeError = "Caminhada indisponível para este ponto." }
        } catch {
            guard directions === operation else { return }
            routeError = "Não foi possível calcular a caminhada. Verifique sua conexão e tente novamente."
        }
        isRouting = false
    }

    func clearWalkingRoute() {
        directions?.cancel()
        directions = nil
        walkingRoute = nil
        walkingDestination = nil
        isRouting = false
        routeError = nil
    }

    static func isFresh(_ location: CLLocation, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(location.timestamp)
        return location.horizontalAccuracy >= 0 && CLLocationCoordinate2DIsValid(location.coordinate) && age >= -5 && age <= 60
    }

    private func discardExpiredLocation() {
        if let location, !Self.isFresh(location) {
            clearLocation()
            lastFixExpired = true
        }
    }

    private func clearLocation() {
        locationExpiry?.cancel()
        locationExpiry = nil
        location = nil
        heading = nil
        lastFixExpired = false
        clearWalkingRoute()
    }

    private func scheduleExpiry(for fix: CLLocation) {
        locationExpiry?.cancel()
        // One expiry per fix, cancelled when a newer fix arrives; no background polling.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.location?.timestamp == fix.timestamp else { return }
            self.clearLocation()
            self.lastFixExpired = true
            self.message = "Posição expirada. Toque em localizar para atualizar; você pode escolher o ponto manualmente."
        }
        locationExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, 60 - Date().timeIntervalSince(fix.timestamp)), execute: work)
    }
}
