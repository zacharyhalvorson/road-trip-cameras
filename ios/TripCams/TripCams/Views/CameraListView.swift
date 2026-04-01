//
//  CameraListView.swift
//  TripCams

import SwiftUI

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct CameraListView: View {
    @EnvironmentObject private var viewModel: TripViewModel
    var namespace: Namespace.ID?
    @Binding var scrollToCameraId: String?
    var isSheetExpanded: Bool
    var onCollapse: () -> Void

    // Tracks whether scroll is at or near top
    @State private var isAtTop = true
    @State private var restingOffset: CGFloat?

    private let collapseThreshold: CGFloat = 50

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Color.clear
                        .frame(height: 0)
                        .id("top")
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geo.frame(in: .named("cameraScroll")).minY
                                )
                            }
                        )

                    if viewModel.cameras.isEmpty && !viewModel.isLoadingCameras {
                        emptyState
                    } else if viewModel.isLoadingCameras && viewModel.cameras.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in
                            skeletonCard
                        }
                    } else {
                        ForEach(viewModel.clusters) { cluster in
                            ForEach(cluster.cameras) { camera in
                                if camera.id != viewModel.selectedCamera?.id {
                                    CameraCardView(camera: camera)
                                        .applyMatchedGeometry(id: camera.id, namespace: namespace)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            withAnimation(.heroSpring) {
                                                viewModel.selectedCamera = camera
                                            }
                                        }
                                        .id(camera.id)
                                    } else {
                                    Color.clear
                                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                        .id(camera.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 20)
            }
            .coordinateSpace(name: "cameraScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                guard isSheetExpanded else { return }
                if restingOffset == nil {
                    restingOffset = value
                }
                if let resting = restingOffset {
                    let atTop = value >= resting - 5
                    if isAtTop != atTop { isAtTop = atTop }
                }
            }
            .scrollDisabled(!isSheetExpanded)
            .simultaneousGesture(
                isSheetExpanded
                ? DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        if isAtTop && value.translation.height > collapseThreshold {
                            onCollapse()
                        }
                    }
                : nil
            )
            .onChange(of: scrollToCameraId) { _, targetId in
                guard let targetId else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(targetId, anchor: .top)
                }
                scrollToCameraId = nil
            }
            .onChange(of: isSheetExpanded) { _, expanded in
                if expanded {
                    restingOffset = nil
                } else {
                    // Wait for the sheet spring animation (~0.4s) before resetting scroll
                    // position — scrolling to top immediately causes a visible jump.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        proxy.scrollTo("top", anchor: .top)
                        isAtTop = true
                    }
                }
            }
        }
    }

    // MARK: - Skeleton Card

    private var skeletonCard: some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color(.tertiarySystemFill))
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ShimmerView()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera")
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))

            Text("No cameras found")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Select a route using the picker above to see highway cameras.")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }
}
