import SwiftUI
import MapKit

struct MapFocus: Equatable {
    let id = UUID()
    let point: GeoPoint
    var span: Double = 0.008
}

private final class TransitAnnotation: NSObject, MKAnnotation {
    enum Kind { case stop, bus }
    let key: String
    let kind: Kind
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var title: String?
    var subtitle: String?
    var bearing: Double?
    var stale = false
    var selected = false
    var stopID: String?
    var routeID: String?
    init(key: String, kind: Kind, point: GeoPoint) {
        self.key = key
        self.kind = kind
        self.coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
    }
}

struct TransitMap: UIViewRepresentable {
    let routes: [TransitRoute]
    let pattern: TransitPattern?
    let stops: [TransitStop]
    let selectedStopID: String?
    let vehicles: [TransitVehicle]
    let showStops: Bool
    let location: CLLocation?
    let walkingRoute: MKRoute?
    let focus: MapFocus?
    let followHeading: Bool
    let onStop: (String) -> Void
    let onVehicle: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // Location permission is requested only by an explicit UI action.
        map.showsUserLocation = location != nil
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.register(MKAnnotationView.self, forAnnotationViewWithReuseIdentifier: "bus")
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -22.923, longitude: -43.400), span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        map.showsUserLocation = location != nil
        coordinator.updateOverlays(map)
        if coordinator.lastPatternID != pattern?.id {
            coordinator.lastPatternID = pattern?.id
            if let polyline = coordinator.transitPolyline, polyline.pointCount > 1 {
                map.setVisibleMapRect(polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 180, left: 40, bottom: 270, right: 40), animated: true)
            }
        }
        if focus?.id != coordinator.lastFocusID, let focus {
            coordinator.lastFocusID = focus.id
            let center = CLLocationCoordinate2D(latitude: focus.point.latitude, longitude: focus.point.longitude)
            map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: focus.span, longitudeDelta: focus.span)), animated: true)
        }
        if followHeading != coordinator.wasFollowingHeading {
            coordinator.wasFollowingHeading = followHeading
            map.setUserTrackingMode(followHeading ? .followWithHeading : .none, animated: true)
        }
        coordinator.updateAnnotations(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TransitMap
        var lastPatternID: String?
        var lastFocusID: UUID?
        var wasFollowingHeading = false
        var transitPolyline: MKPolyline?
        private var lastPolyline: String?
        private var accuracyCircle: MKCircle?
        private var walkingPolyline: MKPolyline?
        private var annotations: [String: TransitAnnotation] = [:]
        private var routeLookup: [String: TransitRoute] = [:]

        init(parent: TransitMap) { self.parent = parent }

        func updateOverlays(_ map: MKMapView) {
            if lastPolyline != parent.pattern?.polyline {
                if let transitPolyline { map.removeOverlay(transitPolyline) }
                lastPolyline = parent.pattern?.polyline
                transitPolyline = nil
                if let encoded = lastPolyline {
                    let points = TransitGeometry.decodePolyline(encoded).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    if !points.isEmpty {
                        let line = MKPolyline(coordinates: points, count: points.count)
                        line.title = "route"
                        transitPolyline = line
                        map.addOverlay(line, level: .aboveRoads)
                    }
                }
            }
            if walkingPolyline !== parent.walkingRoute?.polyline {
                if let walkingPolyline { map.removeOverlay(walkingPolyline) }
                walkingPolyline = parent.walkingRoute?.polyline
                if let walkingPolyline { walkingPolyline.title = "walk"; map.addOverlay(walkingPolyline, level: .aboveRoads) }
            }
            if let accuracyCircle { map.removeOverlay(accuracyCircle) }
            accuracyCircle = nil
            if let location = parent.location, location.horizontalAccuracy > 0 {
                let circle = MKCircle(center: location.coordinate, radius: location.horizontalAccuracy)
                accuracyCircle = circle
                map.addOverlay(circle, level: .aboveRoads)
            }
        }

        func updateAnnotations(_ map: MKMapView) {
            routeLookup = Dictionary(parent.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var desired: [String: TransitAnnotation] = [:]
            let rect = map.visibleMapRect.insetBy(dx: -map.visibleMapRect.size.width * 0.12, dy: -map.visibleMapRect.size.height * 0.12)
            if parent.showStops {
                let candidates = parent.stops.filter {
                    $0.id == parent.selectedStopID || rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)))
                }.sorted { ($0.id == parent.selectedStopID ? 0 : 1) < ($1.id == parent.selectedStopID ? 0 : 1) }
                for stop in candidates.prefix(160) {
                    let annotation = TransitAnnotation(key: "stop:" + stop.id, kind: .stop, point: stop.coordinate)
                    annotation.title = stop.name
                    annotation.subtitle = "Toque para escolher ponto e sentido"
                    annotation.stopID = stop.id
                    annotation.selected = stop.id == parent.selectedStopID
                    desired[annotation.key] = annotation
                }
            }
            let visibleBuses = parent.vehicles.filter {
                $0.coordinate.isValid && rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)))
            }.sorted { ($0.isFresh() ? 0 : 1) < ($1.isFresh() ? 0 : 1) }
            for bus in visibleBuses.prefix(250) {
                let annotation = TransitAnnotation(key: "bus:" + bus.id, kind: .bus, point: bus.coordinate)
                let route = routeLookup[bus.routeID]
                annotation.title = route?.shortName ?? "?"
                annotation.subtitle = "\(route?.longName ?? "Linha não associada") · \(sourceAgeLabel(bus.timestamp))"
                annotation.routeID = bus.routeID
                annotation.bearing = bus.bearing
                annotation.stale = !bus.isFresh()
                desired[annotation.key] = annotation
            }
            for (key, annotation) in annotations where desired[key] == nil {
                map.removeAnnotation(annotation)
                annotations.removeValue(forKey: key)
            }
            for (key, incoming) in desired {
                if let existing = annotations[key] {
                    existing.coordinate = incoming.coordinate
                    existing.title = incoming.title
                    existing.subtitle = incoming.subtitle
                    existing.bearing = incoming.bearing
                    existing.stale = incoming.stale
                    existing.selected = incoming.selected
                    if let view = map.view(for: existing) { configure(view, annotation: existing, map: map) }
                } else {
                    annotations[key] = incoming
                    map.addAnnotation(incoming)
                }
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { updateAnnotations(mapView) }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? TransitAnnotation else { return nil }
            let identifier = point.kind == .bus ? "bus" : "stop"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier, for: point)
            configure(view, annotation: point, map: mapView)
            return view
        }

        private func configure(_ view: MKAnnotationView, annotation: TransitAnnotation, map: MKMapView) {
            view.canShowCallout = true
            view.displayPriority = annotation.selected ? .required : .defaultLow
            view.accessibilityLabel = "\(annotation.kind == .stop ? "Ponto" : "Ônibus") \(annotation.title ?? "")"
            if annotation.kind == .stop, let marker = view as? MKMarkerAnnotationView {
                marker.glyphImage = UIImage(systemName: "bus.fill")
                marker.markerTintColor = annotation.selected ? UIColor(TransitStyle.teal) : UIColor.systemIndigo
                marker.titleVisibility = annotation.selected ? .visible : .adaptive
                marker.clusteringIdentifier = annotation.selected ? nil : "stops"
                marker.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            } else {
                view.clusteringIdentifier = nil
                let color = annotation.routeID.flatMap { routeLookup[$0] }.map { UIColor(TransitStyle.routeColor($0)) } ?? UIColor.secondaryLabel
                view.image = busImage(label: annotation.title ?? "?", bearing: annotation.bearing.map { $0 - map.camera.heading }, stale: annotation.stale, routeColor: color)
                view.centerOffset = CGPoint(x: 0, y: -8)
                view.rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
            }
        }

        private func busImage(label: String, bearing: Double?, stale: Bool, routeColor: UIColor) -> UIImage {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 62, height: 57))
            return renderer.image { context in
                let color = stale ? UIColor.secondaryLabel : routeColor
                if let bearing {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 31, y: 24)
                    context.cgContext.rotate(by: CGFloat(bearing * .pi / 180))
                    let arrow = UIBezierPath()
                    arrow.move(to: CGPoint(x: 0, y: -23))
                    arrow.addLine(to: CGPoint(x: -6, y: -15))
                    arrow.addLine(to: CGPoint(x: 6, y: -15))
                    arrow.close()
                    color.setFill(); arrow.fill()
                    context.cgContext.restoreGState()
                }
                let circle = UIBezierPath(ovalIn: CGRect(x: 17, y: 10, width: 28, height: 28))
                color.setFill(); circle.fill()
                UIColor.white.setStroke(); circle.lineWidth = 2; circle.stroke()
                UIImage(systemName: "bus.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 23, y: 16, width: 16, height: 16))
                let text = String(label.prefix(8)) as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.label]
                let size = text.size(withAttributes: attributes)
                let labelRect = CGRect(x: (62 - size.width) / 2 - 4, y: 38, width: size.width + 8, height: 17)
                UIColor.systemBackground.withAlphaComponent(0.95).setFill()
                UIBezierPath(roundedRect: labelRect, cornerRadius: 5).fill()
                text.draw(at: CGPoint(x: (62 - size.width) / 2, y: 39), withAttributes: attributes)
            }
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            guard let annotation = view.annotation as? TransitAnnotation else { return }
            if let stopID = annotation.stopID { parent.onStop(stopID) }
            else if let routeID = annotation.routeID { parent.onVehicle(routeID) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.25)
                renderer.lineWidth = 1
                return renderer
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            let routeColor = parent.pattern.flatMap { pattern in parent.routes.first { $0.id == pattern.routeID } }.map { UIColor(TransitStyle.routeColor($0)) } ?? UIColor(TransitStyle.teal)
            renderer.strokeColor = line.title == "walk" ? UIColor.systemBlue : routeColor
            renderer.lineWidth = line.title == "walk" ? 4 : 5
            renderer.lineCap = .round
            if line.title == "walk" { renderer.lineDashPattern = [4, 6] }
            return renderer
        }
    }
}
