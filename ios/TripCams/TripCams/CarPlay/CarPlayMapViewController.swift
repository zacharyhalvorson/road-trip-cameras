//
//  CarPlayMapViewController.swift
//  TripCams
//

import MapKit
import UIKit

@MainActor
class CarPlayMapViewController: UIViewController, MKMapViewDelegate {
    let mapView = MKMapView()
    private var routeOverlay: MKPolyline?

    override func viewDidLoad() {
        super.viewDidLoad()
        mapView.frame = view.bounds
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.delegate = self
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        view.addSubview(mapView)
    }

    // MARK: - Route

    func updateRoute(geometry: [Waypoint]) {
        if let old = routeOverlay {
            mapView.removeOverlay(old)
        }
        guard geometry.count >= 2 else { return }

        let coords = geometry.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        routeOverlay = polyline
        mapView.addOverlay(polyline, level: .aboveRoads)
    }

    // MARK: - Camera Markers

    func updateMarkers(clusters: [CameraCluster]) {
        let existing = mapView.annotations.filter { $0 is CarPlayCameraAnnotation }
        mapView.removeAnnotations(existing)

        for cluster in clusters {
            let annotation = CarPlayCameraAnnotation(cluster: cluster)
            mapView.addAnnotation(annotation)
        }
    }

    // MARK: - Fit to Route

    func fitToRoute(geometry: [Waypoint], animated: Bool = true) {
        guard !geometry.isEmpty else { return }
        let lats = geometry.map(\.lat)
        let lons = geometry.map(\.lon)
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else { return }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.3, 0.05),
            longitudeDelta: max((maxLon - minLon) * 1.3, 0.05)
        )
        mapView.setRegion(MKCoordinateRegion(center: center, span: span), animated: animated)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        if let polyline = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = UIColor(red: 0.176, green: 0.722, blue: 0.294, alpha: 1)
            renderer.lineWidth = 4
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard let cameraAnnotation = annotation as? CarPlayCameraAnnotation else { return nil }

        let id = "CameraMarker"
        let view = mapView.dequeueReusableAnnotationView(withIdentifier: id) ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
        view.annotation = annotation

        let count = cameraAnnotation.cluster.cameras.count
        let size: CGFloat = count > 1 ? 32 : 28
        let image = Self.markerImage(count: count, size: size)
        view.image = image
        view.centerOffset = CGPoint(x: 0, y: -size / 2)
        view.canShowCallout = false

        return view
    }

    // MARK: - Marker Rendering

    private static func markerImage(count: Int, size: CGFloat) -> UIImage {
        let totalHeight = size + 6
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: totalHeight))
        return renderer.image { ctx in
            let green = UIColor(red: 0.176, green: 0.722, blue: 0.294, alpha: 1)
            let fillColor = count > 1 ? green : .white
            let iconColor = count > 1 ? UIColor.white : green

            // Circle
            let circleRect = CGRect(x: 0, y: 0, width: size, height: size)

            // Shadow
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            fillColor.setFill()
            ctx.cgContext.fillEllipse(in: circleRect)
            ctx.cgContext.setShadow(offset: .zero, blur: 0)

            // Triangle pointer
            let triPath = UIBezierPath()
            triPath.move(to: CGPoint(x: size / 2 - 5, y: size - 2))
            triPath.addLine(to: CGPoint(x: size / 2, y: totalHeight))
            triPath.addLine(to: CGPoint(x: size / 2 + 5, y: size - 2))
            triPath.close()
            fillColor.setFill()
            triPath.fill()

            if count > 1 {
                // Count label
                let text = "\(count)" as NSString
                let font = UIFont.boldSystemFont(ofSize: size * 0.4)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: iconColor
                ]
                let textSize = text.size(withAttributes: attrs)
                let textOrigin = CGPoint(
                    x: (size - textSize.width) / 2,
                    y: (size - textSize.height) / 2
                )
                text.draw(at: textOrigin, withAttributes: attrs)
            } else {
                // Camera icon (SF Symbol rendered as image)
                let config = UIImage.SymbolConfiguration(pointSize: size * 0.38, weight: .medium)
                if let symbol = UIImage(systemName: "camera.fill", withConfiguration: config) {
                    let symbolSize = symbol.size
                    let origin = CGPoint(
                        x: (size - symbolSize.width) / 2,
                        y: (size - symbolSize.height) / 2
                    )
                    let tinted = symbol.withTintColor(iconColor, renderingMode: .alwaysOriginal)
                    tinted.draw(at: origin)
                }
            }
        }
    }
}

// MARK: - Annotation

class CarPlayCameraAnnotation: NSObject, MKAnnotation {
    let cluster: CameraCluster

    init(cluster: CameraCluster) {
        self.cluster = cluster
        super.init()
    }

    var coordinate: CLLocationCoordinate2D {
        cluster.coordinate
    }

    var title: String? {
        cluster.name
    }

    var subtitle: String? {
        let count = cluster.cameras.count
        return count > 1 ? "\(count) cameras" : cluster.primaryCamera.highway
    }
}
