import SwiftUI

struct GridView: View {
    @Environment(AppState.self) private var state

    private static let spacing: CGFloat = 8
    private static let aspectRatio: CGFloat = 16.0 / 9.0

    var body: some View {
        GeometryReader { proxy in
            switch state.layout {
            case .grid: gridLayout(size: proxy.size)
            case .stacked: stackedLayout(size: proxy.size)
            case .columns: columnsLayout(size: proxy.size)
            }
        }
    }

    private func gridLayout(size: CGSize) -> some View {
        let columns = Self.columnCount(width: size.width, tiles: state.tileOrder.count)
        return ScrollView {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns),
                spacing: Self.spacing
            ) {
                ForEach(state.tileOrder, id: \.self) { sourceID in
                    tile(sourceID)
                        .aspectRatio(Self.aspectRatio, contentMode: .fit)
                }
            }
            .padding(Self.spacing)
        }
    }

    /// The tile width is set from the window width rather than left to
    /// `aspectRatio`, which has no definite width to work from inside a
    /// vertical `ScrollView`.
    private func stackedLayout(size: CGSize) -> some View {
        let width = max(size.width - Self.spacing * 2, 1)
        return ScrollView {
            LazyVStack(spacing: Self.spacing) {
                ForEach(state.tileOrder, id: \.self) { sourceID in
                    tile(sourceID)
                        .frame(width: width, height: (width / Self.aspectRatio).rounded())
                }
            }
            .padding(Self.spacing)
        }
    }

    private func columnsLayout(size: CGSize) -> some View {
        let count = max(state.tileOrder.count, 1)
        let gaps = Self.spacing * CGFloat(count - 1) + Self.spacing * 2
        let byWidth = max(size.width - gaps, 1) / CGFloat(count) / Self.aspectRatio
        let height = min(byWidth, max(size.height - Self.spacing * 2, 1))
        return HStack(spacing: Self.spacing) {
            ForEach(state.tileOrder, id: \.self) { sourceID in
                tile(sourceID)
                    .frame(width: (height * Self.aspectRatio).rounded(), height: height.rounded())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func tile(_ sourceID: String) -> some View {
        if let controller = state.controllers[sourceID] {
            TileView(controller: controller)
                .contentShape(.rect)
                .onTapGesture(count: 2) { state.focus(sourceID: sourceID) }
        }
    }

    static func columnCount(width: CGFloat, tiles: Int) -> Int {
        guard tiles > 0 else { return 1 }
        let byWidth = width > 1200 ? 3 : (width > 720 ? 2 : 1)
        return min(byWidth, tiles)
    }
}
