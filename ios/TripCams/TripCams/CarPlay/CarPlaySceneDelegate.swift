//
//  CarPlaySceneDelegate.swift
//  TripCams
//

import CarPlay
import Combine
import MapKit
import UIKit

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var carWindow: UIWindow?
    private var mapViewController: CarPlayMapViewController?
    private var mapTemplate: CPMapTemplate?
    private var cameraListTemplate: CPListTemplate?
    private var viewModel: TripViewModel? { TripViewModel.shared }
    private var cancellables = Set<AnyCancellable>()

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let mapVC = CarPlayMapViewController()
        self.mapViewController = mapVC

        let window = templateApplicationScene.carWindow
        window.rootViewController = mapVC
        window.makeKeyAndVisible()
        self.carWindow = window

        let mapTemplate = CPMapTemplate()
        self.mapTemplate = mapTemplate

        let routeButton = CPBarButton(image: UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath")!) { [weak self] _ in
            self?.showRouteSelection()
        }
        mapTemplate.trailingNavigationBarButtons = [routeButton]

        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        observeViewModel()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        self.carWindow = nil
        self.mapViewController = nil
        self.mapTemplate = nil
        self.cameraListTemplate = nil
        cancellables.removeAll()
    }

    // MARK: - State Observation

    private func observeViewModel() {
        guard let viewModel = viewModel else { return }

        viewModel.$routeGeometry
            .receive(on: RunLoop.main)
            .sink { [weak self] geometry in
                guard let mvc = self?.mapViewController else { return }
                mvc.updateRoute(geometry: geometry)
                mvc.fitToRoute(geometry: geometry)
            }
            .store(in: &cancellables)

        viewModel.$clusters
            .removeDuplicates { prev, curr in
                guard prev.count == curr.count else { return false }
                return zip(prev, curr).allSatisfy { $0.id == $1.id }
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] clusters in
                self?.mapViewController?.updateMarkers(clusters: clusters)
                self?.updateCameraList(clusters: clusters)
            }
            .store(in: &cancellables)
    }

    // MARK: - Camera List (auto-shown on map template)

    private func updateCameraList(clusters: [CameraCluster]) {
        guard !clusters.isEmpty else {
            // Pop camera list if it was showing and cameras cleared
            if cameraListTemplate != nil {
                cameraListTemplate = nil
                interfaceController?.popToRootTemplate(animated: true, completion: nil)
            }
            return
        }

        let items: [CPListItem] = clusters.prefix(12).map { cluster in
            let camera = cluster.primaryCamera
            let detail = Self.detailText(for: cluster)

            let item = CPListItem(text: cluster.name, detailText: detail, image: Self.placeholder)
            item.handler = { [weak self] _, completion in
                self?.handleClusterTap(cluster: cluster)
                completion()
            }
            loadThumbnail(for: camera, into: item)
            return item
        }

        let section = CPListSection(items: items)

        if let existing = cameraListTemplate {
            existing.updateSections([section])
        } else {
            let template = CPListTemplate(title: "Cameras", sections: [section])
            cameraListTemplate = template
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
        }
    }

    // MARK: - Cluster Tap

    private func handleClusterTap(cluster: CameraCluster) {
        mapViewController?.zoomTo(coordinate: cluster.coordinate, spanDelta: 0.05)

        if cluster.cameras.count == 1 { return }

        let items: [CPListItem] = cluster.cameras.map { camera in
            let detail = [camera.highway, camera.direction].filter { !$0.isEmpty }.joined(separator: " · ")
            let item = CPListItem(text: camera.name, detailText: detail, image: Self.placeholder)
            item.handler = { [weak self] _, completion in
                self?.mapViewController?.zoomTo(coordinate: camera.coordinate, spanDelta: 0.02)
                completion()
            }
            loadThumbnail(for: camera, into: item)
            return item
        }

        let template = CPListTemplate(title: cluster.name, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Route Selection

    private func showRouteSelection() {
        guard let viewModel = viewModel else { return }

        var items: [CPListItem] = []
        for (routeId, route) in viewModel.routes {
            let item = CPListItem(text: route.name, detailText: "\(route.stops.count) stops")
            item.handler = { [weak self] _, completion in
                self?.showRouteStops(routeId: routeId, route: route)
                completion()
            }
            items.append(item)
        }

        let template = CPListTemplate(title: "Routes", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Route Stops

    private func showRouteStops(routeId: String, route: Route) {
        let items: [CPListItem] = route.stops.map { stop in
            let item = CPListItem(text: stop.name, detailText: stop.region)
            item.handler = { [weak self] _, completion in
                guard let self = self, let viewModel = self.viewModel else {
                    completion()
                    return
                }
                let lastStop = route.stops[route.stops.count - 1]
                Task { @MainActor in
                    viewModel.selectRoute(routeId: routeId, from: stop, to: lastStop)
                    await viewModel.loadCamerasForRoute()
                    self.cameraListTemplate = nil
                    self.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                }
                completion()
            }
            return item
        }

        let section = CPListSection(items: items)
        let template = CPListTemplate(title: route.name, sections: [section])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Helpers

    private static func detailText(for cluster: CameraCluster) -> String {
        let camera = cluster.primaryCamera
        if cluster.cameras.count > 1 {
            return ["\(cluster.cameras.count) cameras", camera.region].joined(separator: " · ")
        }
        return [camera.highway, camera.region].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - Image Loading

    private static let thumbnailSize = CGSize(width: 80, height: 45)
    private static let thumbnailCache = NSCache<NSURL, UIImage>()

    private static let placeholder: UIImage = {
        let renderer = UIGraphicsImageRenderer(size: thumbnailSize)
        return renderer.image { ctx in
            UIColor.tertiarySystemFill.setFill()
            ctx.fill(CGRect(origin: .zero, size: thumbnailSize))
        }
    }()

    private func loadThumbnail(for camera: Camera, into item: CPListItem) {
        let urlString = Self.cleanUrl(camera.thumbnailUrl ?? camera.imageUrl)
        guard let url = URL(string: urlString) else { return }

        if let cached = Self.thumbnailCache.object(forKey: url as NSURL) {
            item.setImage(cached)
            return
        }

        Task {
            guard let image = await Self.fetchThumbnail(from: url) else { return }
            Self.thumbnailCache.setObject(image, forKey: url as NSURL)
            item.setImage(image)
        }
    }

    private static func fetchThumbnail(from url: URL) async -> UIImage? {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let full = UIImage(data: data) else { return nil }
            return resizeToFill(full, size: thumbnailSize)
        } catch {
            return nil
        }
    }

    private static func resizeToFill(_ image: UIImage, size: CGSize) -> UIImage {
        let widthRatio = size.width / image.size.width
        let heightRatio = size.height / image.size.height
        let scale = Swift.max(widthRatio, heightRatio)
        let scaledSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (size.width - scaledSize.width) / 2, y: (size.height - scaledSize.height) / 2)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: origin, size: scaledSize))
        }
    }

    private static func cleanUrl(_ urlString: String) -> String {
        var url = urlString
        if url.contains("corsproxy.io/?") {
            url = url.components(separatedBy: "corsproxy.io/?").last ?? url
        }
        if url.contains("%3A") || url.contains("%2F") {
            url = url.removingPercentEncoding ?? url
        }
        return url
    }
}
