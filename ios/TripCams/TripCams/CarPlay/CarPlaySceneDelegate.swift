//
//  CarPlaySceneDelegate.swift
//  TripCams
//

import CarPlay
import MapKit
import UIKit

@MainActor
class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    var interfaceController: CPInterfaceController?
    private var carWindow: UIWindow?
    private var mapViewController: CarPlayMapViewController?
    private var mapTemplate: CPMapTemplate?
    private var viewModel: TripViewModel? { TripViewModel.shared }
    private var refreshTask: Task<Void, Never>?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        // Set up map view controller on the CarPlay window
        let mapVC = CarPlayMapViewController()
        self.mapViewController = mapVC

        let window = templateApplicationScene.carWindow
        window.rootViewController = mapVC
        window.makeKeyAndVisible()
        self.carWindow = window

        // Create map template with bar buttons
        let mapTemplate = CPMapTemplate()
        self.mapTemplate = mapTemplate

        // Leading: camera list button
        let cameraButton = CPBarButton(image: UIImage(systemName: "camera.fill")!) { [weak self] _ in
            self?.showCameraList()
        }
        mapTemplate.leadingNavigationBarButtons = [cameraButton]

        // Trailing: route selection button
        let routeButton = CPBarButton(image: UIImage(systemName: "point.topleft.down.to.point.bottomright.curvepath")!) { [weak self] _ in
            self?.showRouteSelection()
        }
        mapTemplate.trailingNavigationBarButtons = [routeButton]

        interfaceController.setRootTemplate(mapTemplate, animated: true, completion: nil)

        // Sync current state to the map
        syncMapState()
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                   didDisconnect interfaceController: CPInterfaceController) {
        self.interfaceController = nil
        self.carWindow = nil
        self.mapViewController = nil
        self.mapTemplate = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - State Sync

    private func syncMapState() {
        guard let viewModel = viewModel, let mapVC = mapViewController else { return }

        // Initial sync
        if !viewModel.routeGeometry.isEmpty {
            mapVC.updateRoute(geometry: viewModel.routeGeometry)
            mapVC.fitToRoute(geometry: viewModel.routeGeometry, animated: false)
        }
        if !viewModel.clusters.isEmpty {
            mapVC.updateMarkers(clusters: viewModel.clusters)
        }

        // Periodic refresh to pick up view model changes from the phone app
        refreshTask = Task { [weak self] in
            var lastGeometryCount = viewModel.routeGeometry.count
            var lastClusterCount = viewModel.clusters.count
            var lastFirstWaypoint = viewModel.routeGeometry.first

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                guard let self = self, let vm = self.viewModel, let mvc = self.mapViewController else { break }

                let geoCount = vm.routeGeometry.count
                let cCount = vm.clusters.count
                let firstWaypoint = vm.routeGeometry.first

                if geoCount != lastGeometryCount || firstWaypoint != lastFirstWaypoint {
                    lastGeometryCount = geoCount
                    lastFirstWaypoint = firstWaypoint
                    mvc.updateRoute(geometry: vm.routeGeometry)
                    mvc.fitToRoute(geometry: vm.routeGeometry)
                }

                if cCount != lastClusterCount {
                    lastClusterCount = cCount
                    mvc.updateMarkers(clusters: vm.clusters)
                }
            }
        }
    }

    // MARK: - Camera List

    private func showCameraList() {
        guard let viewModel = viewModel else { return }

        if viewModel.clusters.isEmpty {
            let emptyItem = CPListItem(text: "No cameras loaded", detailText: "Select a route first")
            let template = CPListTemplate(title: "Cameras", sections: [CPListSection(items: [emptyItem])])
            interfaceController?.pushTemplate(template, animated: true, completion: nil)
            return
        }

        let items: [CPListItem] = viewModel.clusters.prefix(12).map { cluster in
            let count = cluster.cameras.count
            let detail = count > 1 ? "\(count) cameras" : cluster.primaryCamera.highway
            let item = CPListItem(text: cluster.name, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.showClusterDetail(cluster: cluster)
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: "Cameras", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Cluster Detail

    private func showClusterDetail(cluster: CameraCluster) {
        // Zoom map to cluster location
        mapViewController?.mapView.setRegion(
            MKCoordinateRegion(
                center: cluster.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ),
            animated: true
        )

        if cluster.cameras.count == 1 {
            showCameraDetail(camera: cluster.primaryCamera)
            return
        }

        let items: [CPListItem] = cluster.cameras.map { camera in
            let item = CPListItem(text: camera.name, detailText: "\(camera.highway) \(camera.direction)")
            item.handler = { [weak self] _, completion in
                self?.showCameraDetail(camera: camera)
                completion()
            }
            return item
        }

        let template = CPListTemplate(title: cluster.name, sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    // MARK: - Camera Detail

    private func showCameraDetail(camera: Camera) {
        // Zoom map to camera location
        mapViewController?.mapView.setRegion(
            MKCoordinateRegion(
                center: camera.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ),
            animated: true
        )

        var items: [CPInformationItem] = [
            CPInformationItem(title: "Highway", detail: camera.highway),
            CPInformationItem(title: "Direction", detail: camera.direction),
            CPInformationItem(title: "Region", detail: camera.region),
        ]

        if let temp = camera.temperature {
            items.append(CPInformationItem(title: "Temperature", detail: "\(Int(temp))\u{00B0}C"))
        }

        let template = CPInformationTemplate(title: camera.name, layout: .leading, items: items, actions: [])
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

                    // Update map with new route and markers
                    self.mapViewController?.updateRoute(geometry: viewModel.routeGeometry)
                    self.mapViewController?.updateMarkers(clusters: viewModel.clusters)
                    self.mapViewController?.fitToRoute(geometry: viewModel.routeGeometry)

                    // Pop back to map
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
}
