import SwiftUI

struct GridView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        GeometryReader { proxy in
            let columns = Self.columnCount(width: proxy.size.width, tiles: state.tileOrder.count)
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                    spacing: 8
                ) {
                    ForEach(state.tileOrder, id: \.self) { sourceID in
                        if let controller = state.controllers[sourceID] {
                            TileView(controller: controller)
                                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                .contentShape(.rect)
                                .onTapGesture(count: 2) { state.focus(sourceID: sourceID) }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    static func columnCount(width: CGFloat, tiles: Int) -> Int {
        guard tiles > 0 else { return 1 }
        let byWidth = width > 1200 ? 3 : (width > 720 ? 2 : 1)
        return min(byWidth, tiles)
    }
}
