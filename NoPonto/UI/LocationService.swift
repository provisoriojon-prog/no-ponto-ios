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

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 8
        manager.headingFilter = 8
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
    }

    var point: GeoPoint? {
        guard let location else { return nil }
        return GeoPoint(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var accuracyText: String {
        guard let location, location.horizontalAccuracy >= 0 else { return "Aguardando localização" }
        return "Precisão de cerca de \(Int(location.horizontalAccuracy.rounded())) m"
    }

    func requestLocation() {
        requested = true
        message = nil
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if isDenied { message = "Ative Localização nos Ajustes do iPhone para encontrar pontos perto de você." }
        else { beginUpdates() }
    }

    func setActive(_ value: Bool) {
        active = value
        if value && requested { beginUpdates() }
        else { manager.stopUpdatingLocation(); manager.stopUpdatingHeading() }
    }

    private func beginUpdates() {
        guard active, requested, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        reducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        if isDenied { message = "Localização desativada. Você pode buscar uma linha e escolher seu ponto no mapa." }
        beginUpdates()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let value = locations.last, value.horizontalAccuracy >= 0,
              abs(value.timestamp.timeIntervalSinceNow) < 60 else { return }
        location = value
        message = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        heading = newHeading.headingAccuracy >= 0 ? newHeading : nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        message = "Não foi possível obter sua posição agora. Escolha o ponto manualmente ou tente novamente."
    }

    @MainActor func walk(to stop: TransitStop) async {
        guard let location else {
            requestLocation()
            routeError = "Aguarde sua localização e toque novamente para calcular a caminhada."
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
}
