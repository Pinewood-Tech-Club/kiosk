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
    /// The slot of the item that's out for editing, which the dashed placeholder follows.
    private(set) var editing: Tile?

    func update(_ tiles: [Tile], editing: Tile?) {
        if tiles != self.tiles { self.tiles = tiles }
        if editing != self.editing { self.editing = editing }
    }
}

/// The order sheet's progress, published by the stage every frame it moves (see `SheetGeometry`).
@Observable
@MainActor
final class SheetModel {
    private(set) var progress: CGFloat = 0

    func update(_ progress: CGFloat) {
        if progress != self.progress { self.progress = progress }
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
        .opacity(SheetGeometry(progress: app.stage.sheetModel.progress).trayOpacity)
        .allowsHitTesting(false)
    }
}
