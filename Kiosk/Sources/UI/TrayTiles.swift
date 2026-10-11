import Observation
import SwiftUI

/// The tray's item tiles, published by the stage whenever their positions change (scrolling, reordering), so
/// SwiftUI draws each tile exactly under its 3D mini.
@Observable
@MainActor
final class TrayTileModel {
    struct Tile: Identifiable, Equatable {
        let id: UUID
        var x: CGFloat
    }

    private(set) var tiles: [Tile] = []

    func update(_ tiles: [Tile]) {
        if tiles != self.tiles { self.tiles = tiles }
    }
}

/// Tiles matching the New item slot, one per item in the tray. Drawn beneath the stage and clipped like the minis.
struct TrayTiles: View {
    let app: AppModel

    var body: some View {
        let model = app.stage.trayTiles
        let area = TrayClip.itemsArea
        ZStack(alignment: .topLeading) {
            ForEach(model.tiles) { tile in
                RoundedRectangle(cornerRadius: Layout.trayTileRadius, style: .continuous)
                    .fill(Theme.ink.opacity(0.055))
                    .frame(width: Layout.trayTileSize.width, height: Layout.trayTileSize.height)
                    .position(x: tile.x - area.minX, y: Layout.trayCenterY - area.minY)
                    .animation(nil, value: tile.x)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        .frame(width: area.width, height: area.height)
        .clipShape(TrayClip.itemsShape)
        .position(x: area.midX, y: area.midY)
        .animation(.easeOut(duration: 0.28), value: model.tiles.map(\.id))
        .opacity(app.mode == .customize ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: app.mode == .customize)
        .allowsHitTesting(false)
    }
}
