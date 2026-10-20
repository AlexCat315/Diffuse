internal import GhosttyVt

/// A Kitty Unicode placeholder cell (U+10EEEE). Programs such as tmux-aware
/// image viewers print these instead of placing images by position: the
/// foreground color carries the image id, the underline color an optional
/// placement id, and combining diacritics the row, column and high id byte.
struct PlaceholderCell: Equatable, Sendable {
    static let codepoint: UInt32 = 0x10EEEE

    var column: Int
    var row: Int
    var imageIDLow: UInt32
    var placementID: UInt32
    var imageRow: Int?
    var imageColumn: Int?
    var imageIDHigh: UInt32?

    /// Parses the diacritics of a placeholder grapheme; `nil` for other text.
    init?(text: String, column: Int, row: Int, foreground: UInt32, underline: UInt32) {
        var scalars = text.unicodeScalars.makeIterator()
        guard scalars.next()?.value == Self.codepoint, foreground != 0 else { return nil }
        self.column = column
        self.row = row
        imageIDLow = foreground
        placementID = underline
        // Invalid diacritics count as missing, as in Kitty.
        imageRow = scalars.next().flatMap { Self.index($0.value) }
        imageColumn = scalars.next().flatMap { Self.index($0.value) }
        imageIDHigh = scalars.next().flatMap { Self.index($0.value) }.flatMap { $0 <= 255 ? UInt32($0) : nil }
    }

    static func index(_ codepoint: UInt32) -> Int? {
        var low = 0, high = placeholderDiacritics.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if placeholderDiacritics[middle] == codepoint { return middle }
            if placeholderDiacritics[middle] < codepoint { low = middle + 1 } else { high = middle - 1 }
        }
        return nil
    }
}

/// A run of placeholder cells showing one horizontal strip of an image.
struct PlaceholderRun: Equatable {
    var column: Int
    var row: Int
    var imageID: UInt32
    var placementID: UInt32
    var imageColumn: Int
    var imageRow: Int
    var width: Int

    /// Groups placeholder cells into runs, row by row. A cell continues the
    /// run when it shows the same image and its omitted diacritics are
    /// implied by the cell to its left.
    static func runs(_ cells: [PlaceholderCell]) -> [PlaceholderRun] {
        var result: [PlaceholderRun] = []
        var current: (run: PlaceholderRun, high: UInt32?)?
        func finish() { if let current { result.append(current.run) }; current = nil }
        for cell in cells.sorted(by: { ($0.row, $0.column) < ($1.row, $1.column) }) {
            if var open = current, open.run.row == cell.row, open.run.column + open.run.width == cell.column,
               open.run.imageID & 0xFF_FFFF == cell.imageIDLow, open.run.placementID == cell.placementID,
               cell.imageRow == nil || cell.imageRow == open.run.imageRow,
               cell.imageColumn == nil || cell.imageColumn == open.run.imageColumn + open.run.width,
               cell.imageIDHigh == nil || cell.imageIDHigh == open.high {
                open.run.width += 1
                current = open
                continue
            }
            finish()
            let high = cell.imageIDHigh
            current = (PlaceholderRun(column: cell.column, row: cell.row,
                                      imageID: cell.imageIDLow | ((high ?? 0) << 24), placementID: cell.placementID,
                                      imageColumn: cell.imageColumn ?? 0, imageRow: cell.imageRow ?? 0, width: 1), high)
        }
        finish()
        return result
    }

    /// Where this strip of the image lands, fitting the whole image into the
    /// virtual placement's grid with its aspect ratio kept and centred.
    /// Mirrors Ghostty's `Placement.renderPlacement`.
    func placement(grid: (columns: Int, rows: Int), image: (width: Int, height: Int), generation: UInt64,
                   cell: (width: Int, height: Int)) -> TerminalImagePlacement? {
        let imageWidth = Double(image.width), imageHeight = Double(image.height)
        guard imageWidth > 0, imageHeight > 0, grid.columns > 0, grid.rows > 0 else { return nil }
        let gridWidth = Double(grid.columns * cell.width), gridHeight = Double(grid.rows * cell.height)

        var scale = 0.0, offsetX = 0.0, offsetY = 0.0
        if imageWidth * gridHeight > imageHeight * gridWidth {
            scale = gridWidth / imageWidth
            offsetY = (gridHeight - imageHeight * scale) / 2
        } else {
            scale = gridHeight / imageHeight
            offsetX = (gridWidth - imageWidth * scale) / 2
        }
        // The image padded to the grid's aspect ratio, in image pixels.
        let padX = offsetX / scale, padY = offsetY / scale
        let paddedWidth = imageWidth + padX * 2, paddedHeight = imageHeight + padY * 2

        var source = (x: paddedWidth * Double(imageColumn) / Double(grid.columns),
                      y: paddedHeight * Double(imageRow) / Double(grid.rows),
                      width: paddedWidth * Double(width) / Double(grid.columns),
                      height: paddedHeight / Double(grid.rows))
        var dest = (x: 0.0, y: 0.0, width: Double(width * cell.width), height: Double(cell.height))

        if source.y < padY {
            let inset = padY - source.y
            source.height -= inset; dest.y = inset; dest.height -= inset * scale; source.y = 0
            if source.height > imageHeight { source.height = imageHeight; dest.height = imageHeight * scale }
        } else if source.y + source.height > paddedHeight - padY {
            source.y -= padY
            source.height = paddedHeight - padY - source.y - padY
            dest.height = source.height * scale
        } else {
            source.y -= padY
        }
        if source.x < padX {
            let inset = padX - source.x
            source.width -= inset; dest.x = inset; dest.width -= inset * scale; source.x = 0
            if source.width > imageWidth { source.width = imageWidth; dest.width = imageWidth * scale }
        } else if source.x + source.width > paddedWidth - padX {
            source.x -= padX
            source.width = paddedWidth - padX - source.x - padX
            dest.width = source.width * scale
        } else {
            source.x -= padX
        }
        guard source.width > 0, source.height > 0 else { return nil }

        return TerminalImagePlacement(
            imageID: imageID, generation: generation, column: column, row: row,
            width: Int(dest.width.rounded()), height: Int(dest.height.rounded()),
            source: (Int(source.x.rounded()), Int(source.y.rounded()), Int(source.width.rounded()), Int(source.height.rounded())),
            imageSize: image, isBelowText: false,
            offset: (Int((dest.x * scale).rounded()), Int((dest.y * scale).rounded())))
    }
}

extension TerminalEngine {
    /// Image strips drawn by placeholder cells in the captured frame.
    func placeholderPlacements(_ cells: [PlaceholderCell]) -> [TerminalImagePlacement] {
        guard !cells.isEmpty, let graphics = kittyGraphics else { return [] }
        let targets = virtualPlacements(graphics)
        return PlaceholderRun.runs(cells).compactMap { run in
            // An explicit placement id must match; otherwise the image's first virtual placement.
            guard let target = targets.first(where: {
                      $0.imageID == run.imageID && (run.placementID == 0 || $0.placementID == run.placementID) }),
                  let image = ghostty_kitty_graphics_image(graphics, run.imageID) else { return nil }
            var width: UInt32 = 0, height: UInt32 = 0, generation: UInt64 = 0
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
            // Unspecified rows or columns fit the image at its natural size.
            let columns = target.columns > 0 ? target.columns : (Int(width) + cellSize.width - 1) / cellSize.width
            let rows = target.rows > 0 ? target.rows : (Int(height) + cellSize.height - 1) / cellSize.height
            return run.placement(grid: (columns, rows), image: (Int(width), Int(height)),
                                 generation: generation, cell: cellSize)
        }
    }

    private func virtualPlacements(_ graphics: GhosttyKittyGraphics) -> [(imageID: UInt32, placementID: UInt32, columns: Int, rows: Int)] {
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS, let iterator else { return [] }
        defer { ghostty_kitty_graphics_placement_iterator_free(iterator) }
        var handle: GhosttyKittyGraphicsPlacementIterator? = iterator
        guard ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &handle) == GHOSTTY_SUCCESS
        else { return [] }
        var result: [(UInt32, UInt32, Int, Int)] = []
        while ghostty_kitty_graphics_placement_next(iterator) {
            var isVirtual = false, imageID: UInt32 = 0, placementID: UInt32 = 0, columns: UInt32 = 0, rows: UInt32 = 0
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &isVirtual)
            guard isVirtual else { continue }
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_PLACEMENT_ID, &placementID)
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_COLUMNS, &columns)
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_ROWS, &rows)
            result.append((imageID, placementID, Int(columns), Int(rows)))
        }
        return result
    }
}
