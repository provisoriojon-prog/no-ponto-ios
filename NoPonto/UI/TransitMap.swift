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

// Tiny artwork keeps the map clear; taps still have a 44-point target.
private final class TransitAnnotationView: MKAnnotationView {
    var activate: (() -> Void)?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        let target = bounds.insetBy(dx: -max(0, (44 - bounds.width) / 2),
                                   dy: -max(0, (44 - bounds.height) / 2))
        return target.contains(point)
    }
    override func accessibilityActivate() -> Bool {
        guard let activate else { return false }
        activate()
        return true
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        activate = nil
    }
}

struct TransitMap: UIViewRepresentable {
    let routes: [TransitRoute]
    let patterns: [TransitPattern]
    let focusedPatternID: String?
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
    // Additional inset above the safe area. The home UI leaves this strip free.
    var bottomObstruction: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = location != nil
        map.showsCompass = false
        map.showsScale = false
        map.showsTraffic = false
        map.showsBuildings = false
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = false
        map.insetsLayoutMarginsFromSafeArea = true
        map.layoutMargins = UIEdgeInsets(top: 70, left: 12, bottom: bottomObstruction, right: 12)
        map.register(TransitAnnotationView.self, forAnnotationViewWithReuseIdentifier: "stop")
        map.register(TransitAnnotationView.self, forAnnotationViewWithReuseIdentifier: "bus")
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: -22.923, longitude: -43.400), span: MKCoordinateSpan(latitudeDelta: 0.35, longitudeDelta: 0.35)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        map.showsUserLocation = location != nil
        map.layoutMargins = UIEdgeInsets(top: 70, left: 12, bottom: max(0, bottomObstruction), right: 12)
        coordinator.updateCompass(map)
        coordinator.updateOverlays(map)
        if coordinator.lastFocusedPatternID != focusedPatternID {
            coordinator.lastFocusedPatternID = focusedPatternID
            if let id = focusedPatternID, let line = coordinator.routeOverlays[id], line.pointCount > 1 {
                map.setVisibleMapRect(line.boundingMapRect, edgePadding: UIEdgeInsets(top: 80, left: 42, bottom: max(100, bottomObstruction + 70), right: 42), animated: true)
            }
        }
        if focus?.id != coordinator.lastFocusID, let focus {
            coordinator.lastFocusID = focus.id
            let center = CLLocationCoordinate2D(latitude: focus.point.latitude, longitude: focus.point.longitude)
            map.setRegion(MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: focus.span, longitudeDelta: focus.span)), animated: true)
        }
        let canFollowHeading = followHeading && location != nil
        if canFollowHeading != coordinator.wasFollowingHeading {
            coordinator.wasFollowingHeading = canFollowHeading
            map.setUserTrackingMode(canFollowHeading ? .followWithHeading : .none, animated: true)
        }
        coordinator.updateAnnotations(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: TransitMap
        var lastFocusedPatternID: String?
        var lastFocusID: UUID?
        var wasFollowingHeading = false
        fileprivate var routeOverlays: [String: MKPolyline] = [:]
        private var overlayEncodings: [String: String] = [:]
        private var accuracyCircle: MKCircle?
        private var accuracyLocation: CLLocation?
        private var walkingPolyline: MKPolyline?
        private var annotations: [String: TransitAnnotation] = [:]
        private var routeLookup: [String: TransitRoute] = [:]
        private var lastRenderedHeading = 0.0

        init(parent: TransitMap) { self.parent = parent }

        func updateOverlays(_ map: MKMapView) {
            routeLookup = Dictionary(parent.routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let desired = Dictionary(parent.patterns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            for id in Array(routeOverlays.keys) where desired[id] == nil {
                if let line = routeOverlays.removeValue(forKey: id) { map.removeOverlay(line) }
                overlayEncodings.removeValue(forKey: id)
            }
            let ordered = desired.values.sorted {
                if ($0.id == parent.focusedPatternID) != ($1.id == parent.focusedPatternID) {
                    return $0.id != parent.focusedPatternID
                }
                return $0.id < $1.id
            }
            for pattern in ordered {
                if overlayEncodings[pattern.id] != pattern.polyline {
                    if let previous = routeOverlays.removeValue(forKey: pattern.id) { map.removeOverlay(previous) }
                    overlayEncodings[pattern.id] = pattern.polyline
                    let points = TransitGeometry.decodePolyline(pattern.polyline).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
                    if points.count > 1 {
                        let line = MKPolyline(coordinates: points, count: points.count)
                        line.title = pattern.id
                        line.subtitle = pattern.routeID
                        routeOverlays[pattern.id] = line
                        map.addOverlay(line, level: .aboveRoads)
                    }
                }
                if let line = routeOverlays[pattern.id], let renderer = map.renderer(for: line) as? MKPolylineRenderer {
                    style(renderer, line: line)
                }
            }
            if walkingPolyline !== parent.walkingRoute?.polyline {
                if let walkingPolyline { map.removeOverlay(walkingPolyline) }
                walkingPolyline = parent.walkingRoute?.polyline
                if let walkingPolyline { walkingPolyline.title = "walk"; map.addOverlay(walkingPolyline, level: .aboveRoads) }
            }
            if accuracyLocation?.timestamp != parent.location?.timestamp {
                if let accuracyCircle { map.removeOverlay(accuracyCircle) }
                accuracyCircle = nil
                accuracyLocation = parent.location
                if let location = parent.location, location.horizontalAccuracy > 0 {
                    let circle = MKCircle(center: location.coordinate, radius: location.horizontalAccuracy)
                    accuracyCircle = circle
                    map.addOverlay(circle, level: .aboveRoads)
                }
            }
        }

        func updateAnnotations(_ map: MKMapView) {
            var desired: [String: TransitAnnotation] = [:]
            let rect = map.visibleMapRect.insetBy(dx: -map.visibleMapRect.size.width * 0.10, dy: -map.visibleMapRect.size.height * 0.10)
            let widthMeters = map.visibleMapRect.size.width * MKMetersPerMapPointAtLatitude(map.centerCoordinate.latitude)
            // Stops appear at street scale, and only along the supplied saved lines.
            if parent.showStops && widthMeters <= 2_000 {
                let servedIDs = Set(parent.patterns.flatMap { $0.stops.map(\.stopID) })
                let center = MKMapPoint(map.centerCoordinate)
                let candidates = parent.stops.filter {
                    servedIDs.contains($0.id) && rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)))
                }.sorted {
                    if ($0.id == parent.selectedStopID) != ($1.id == parent.selectedStopID) { return $0.id == parent.selectedStopID }
                    let a = MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude))
                    let b = MKMapPoint(CLLocationCoordinate2D(latitude: $1.latitude, longitude: $1.longitude))
                    return hypot(a.x - center.x, a.y - center.y) < hypot(b.x - center.x, b.y - center.y)
                }
                for stop in candidates.prefix(120) {
                    let annotation = TransitAnnotation(key: "stop:" + stop.id, kind: .stop, point: stop.coordinate)
                    annotation.title = stop.name
                    annotation.stopID = stop.id
                    annotation.selected = stop.id == parent.selectedStopID
                    desired[annotation.key] = annotation
                }
            }
            let visibleBuses = parent.vehicles.filter {
                $0.coordinate.isValid && rect.contains(MKMapPoint(CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)))
            }.sorted {
                if $0.isFresh() != $1.isFresh() { return $0.isFresh() }
                return $0.id < $1.id
            }
            for bus in visibleBuses.prefix(250) {
                let annotation = TransitAnnotation(key: "bus:" + bus.id, kind: .bus, point: bus.coordinate)
                let route = routeLookup[bus.routeID]
                annotation.title = route?.shortName ?? "Linha não associada"
                annotation.subtitle = "\(route?.longName ?? "") · \(sourceAgeLabel(bus.timestamp))"
                annotation.routeID = bus.routeID
                annotation.bearing = bus.bearing
                annotation.stale = !bus.isFresh()
                desired[annotation.key] = annotation
            }
            for key in Array(annotations.keys) where desired[key] == nil {
                if let annotation = annotations.removeValue(forKey: key) { map.removeAnnotation(annotation) }
            }
            for key in desired.keys.sorted() {
                guard let incoming = desired[key] else { continue }
                if let existing = annotations[key] {
                    existing.coordinate = incoming.coordinate
                    existing.title = incoming.title
                    existing.subtitle = incoming.subtitle
                    existing.bearing = incoming.bearing
                    existing.stale = incoming.stale
                    existing.selected = incoming.selected
                    existing.routeID = incoming.routeID
                    existing.stopID = incoming.stopID
                    if let view = map.view(for: existing) { configure(view, annotation: existing, map: map) }
                } else {
                    annotations[key] = incoming
                    map.addAnnotation(incoming)
                }
            }
            lastRenderedHeading = map.camera.heading
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) { updateAnnotations(mapView) }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            updateCompass(mapView)
            guard abs(mapView.camera.heading - lastRenderedHeading) >= 3 else { return }
            lastRenderedHeading = mapView.camera.heading
            for annotation in annotations.values where annotation.kind == .bus {
                if let view = mapView.view(for: annotation) { configure(view, annotation: annotation, map: mapView) }
            }
        }

        func updateCompass(_ map: MKMapView) {
            let heading = map.camera.heading.truncatingRemainder(dividingBy: 360)
            map.showsCompass = min(abs(heading), abs(360 - heading)) > 1
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let point = annotation as? TransitAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: point.kind == .bus ? "bus" : "stop", for: point)
            configure(view, annotation: point, map: mapView)
            return view
        }

        private func configure(_ view: MKAnnotationView, annotation: TransitAnnotation, map: MKMapView) {
            view.canShowCallout = false
            view.clusteringIdentifier = nil
            view.collisionMode = .circle
            view.centerOffset = .zero
            view.rightCalloutAccessoryView = nil
            view.isAccessibilityElement = true
            view.accessibilityTraits = .button
            view.accessibilityIdentifier = "map-" + annotation.key
            (view as? TransitAnnotationView)?.activate = { [weak self] in
                self?.activate(annotation)
            }
            if annotation.kind == .stop {
                view.displayPriority = annotation.selected ? .defaultHigh : .defaultLow
                view.zPriority = annotation.selected ? .defaultSelected : .defaultUnselected
                view.selectedZPriority = .defaultSelected
                view.image = stopImage(selected: annotation.selected)
                view.accessibilityLabel = "Ponto \(annotation.title ?? "")"
                view.accessibilityHint = "Ver linhas e chegadas neste ponto"
            } else {
                view.displayPriority = .defaultHigh
                view.zPriority = .max
                view.selectedZPriority = .max
                let color = annotation.routeID.flatMap { routeLookup[$0] }.map { UIColor(TransitStyle.routeColor($0)) } ?? UIColor.secondaryLabel
                let bearing: Double? = annotation.bearing.flatMap { $0.isFinite ? $0 - map.camera.heading : nil }
                view.image = busImage(bearing: bearing, stale: annotation.stale, routeColor: color)
                view.accessibilityLabel = "Ônibus \(annotation.title ?? ""), \(annotation.subtitle ?? "")"
                view.accessibilityHint = "Ver próxima chegada desta linha"
            }
        }

        private func stopImage(selected: Bool) -> UIImage {
            let side: CGFloat = selected ? 10 : 6
            return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                let circle = UIBezierPath(ovalIn: CGRect(x: 0.75, y: 0.75, width: side - 1.5, height: side - 1.5))
                (selected ? UIColor(TransitStyle.teal) : UIColor(red: 0.43, green: 0.53, blue: 0.60, alpha: 0.85)).setFill()
                circle.fill()
                UIColor.systemBackground.withAlphaComponent(0.95).setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
                if selected {
                    UIColor.systemBackground.setFill()
                    UIBezierPath(ovalIn: CGRect(x: 3.5, y: 3.5, width: 3, height: 3)).fill()
                }
            }
        }

        private func busImage(bearing: Double?, stale: Bool, routeColor: UIColor) -> UIImage {
            UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
                let color = stale ? routeColor.withAlphaComponent(0.45) : routeColor
                if let bearing {
                    context.cgContext.saveGState()
                    context.cgContext.translateBy(x: 12, y: 12)
                    context.cgContext.rotate(by: CGFloat(bearing * .pi / 180))
                    let arrow = UIBezierPath()
                    arrow.move(to: CGPoint(x: 0, y: -12))
                    arrow.addLine(to: CGPoint(x: -4.5, y: -5))
                    arrow.addLine(to: CGPoint(x: 4.5, y: -5))
                    arrow.close()
                    color.setFill(); arrow.fill()
                    context.cgContext.restoreGState()
                }
                let circle = UIBezierPath(ovalIn: CGRect(x: 3.5, y: 3.5, width: 17, height: 17))
                color.setFill(); circle.fill()
                UIColor.white.setStroke(); circle.lineWidth = 1.5; circle.stroke()
                UIImage(systemName: "bus.fill")?.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: CGRect(x: 7.25, y: 6.75, width: 9.5, height: 10.5))
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let annotation = view.annotation as? TransitAnnotation else { return }
            mapView.deselectAnnotation(annotation, animated: false)
            activate(annotation)
        }

        private func activate(_ annotation: TransitAnnotation) {
            if let stopID = annotation.stopID { parent.onStop(stopID) }
            else if let routeID = annotation.routeID { parent.onVehicle(routeID) }
        }

        private func style(_ renderer: MKPolylineRenderer, line: MKPolyline) {
            if line.title == "walk" {
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.8)
                renderer.lineWidth = 3
                renderer.lineDashPattern = [3, 5]
            } else {
                let focused = line.title == parent.focusedPatternID
                let color = line.subtitle.flatMap { routeLookup[$0] }.map { UIColor(TransitStyle.routeColor($0)) } ?? UIColor(TransitStyle.teal)
                renderer.strokeColor = color.withAlphaComponent(focused ? 0.65 : 0.30)
                renderer.lineWidth = focused ? 3 : 2
                renderer.lineDashPattern = nil
            }
            renderer.lineCap = .round
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05)
                renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.2)
                renderer.lineWidth = 0.75
                return renderer
            }
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            style(renderer, line: line)
            return renderer
        }
    }
}
