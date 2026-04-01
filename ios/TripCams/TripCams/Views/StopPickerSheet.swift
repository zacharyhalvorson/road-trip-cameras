//
//  StopPickerSheet.swift
//  TripCams
//

import SwiftUI

struct StopPickerSheet: View {
    @EnvironmentObject private var viewModel: TripViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var searchQuery = ""
    @State private var geocodeResults: [GeocodingService.GeocodedPlace] = []
    @State private var isSearching = false

    private let geocoder = GeocodingService.shared

    private var fieldLabel: String {
        viewModel.activeDropdown == .from ? "Origin" : "Destination"
    }

    var body: some View {
        NavigationStack {
            List {
                if !geocodeResults.isEmpty {
                    Section {
                        ForEach(geocodeResults) { place in
                            Button { selectGeocodedPlace(place) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundStyle(Color.tripGreen)

                                    Text(place.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    if !place.region.isEmpty {
                                        regionBadge(place.region)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Search Results")
                    }
                }

                ForEach(viewModel.routes.sorted(by: { $0.key < $1.key }), id: \.key) { routeId, route in
                    Section {
                        ForEach(route.stops) { stop in
                            Button { selectStop(stop, routeId: routeId) } label: {
                                HStack(spacing: 12) {
                                    Text(stop.name)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)

                                    Spacer()

                                    regionBadge(stop.region)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    } header: {
                        Text(route.name)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select \(fieldLabel)")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, prompt: "Search city or address")
            .onSubmit(of: .search) {
                performSearch()
            }
            .onChange(of: searchQuery) {
                if searchQuery.isEmpty {
                    geocodeResults = []
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: - Region Badge

    private func regionBadge(_ region: String) -> some View {
        Text(region.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(Color.regionBadge(region))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.regionBadge(region).opacity(0.12), in: Capsule())
    }

    // MARK: - Selection

    private func selectStop(_ stop: RouteStop, routeId: String) {
        let field = viewModel.activeDropdown
        if field == .from {
            viewModel.fromStop = stop
        } else {
            viewModel.toStop = stop
        }
        viewModel.activeDropdown = .none

        if let from = viewModel.fromStop, let to = viewModel.toStop {
            viewModel.selectRoute(routeId: routeId, from: from, to: to)
        }
    }

    private func selectGeocodedPlace(_ place: GeocodingService.GeocodedPlace) {
        let stop = RouteStop(
            id: place.id,
            name: place.displayName,
            region: place.region,
            lat: place.lat,
            lon: place.lon
        )
        let field = viewModel.activeDropdown
        if field == .from {
            viewModel.fromStop = stop
        } else {
            viewModel.toStop = stop
        }
        viewModel.activeDropdown = .none

        if let from = viewModel.fromStop, let to = viewModel.toStop {
            viewModel.selectCustomRoute(
                from: Waypoint(lat: from.lat, lon: from.lon),
                to: Waypoint(lat: to.lat, lon: to.lon)
            )
        }
    }

    // MARK: - Search

    private func performSearch() {
        let text = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        Task {
            geocodeResults = await geocoder.search(query: text)
            isSearching = false
        }
    }
}
