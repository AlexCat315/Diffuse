internal import GhosttyVt
internal import Foundation
internal import GuavaUIRuntime

/// Where a Kitty graphics placement sits in the viewport. Pixel values use the
/// cell size last reported to the engine.
struct TerminalImagePlacement: Equatable, Sendable {
    var imageID: UInt32
    /// Changes whenever the image's pixels change (retransmission, animation).
    var generation: UInt64
    var column: Int
    var row: Int
    var width: Int
    var height: Int
    /// Visible part of the image, in image pixels.
    var source: (x: Int, y: Int, width: Int, height: Int)
    var imageSize: (width: Int, height: Int)
    /// Negative z draws under text (`z<0` in the protocol).
    var isBelowText: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.imageID == rhs.imageID && lhs.generation == rhs.generation && lhs.column == rhs.column
            && lhs.row == rhs.row && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.source == rhs.source && lhs.imageSize == rhs.imageSize && lhs.isBelowText == rhs.isBelowText
    }
}

extension TerminalEngine {
    /// Kitty graphics are off until a storage limit is set. File and shared
    /// memory transmission stay disabled: only inline data is accepted.
    func enableImages() {
        PNGDecoder.install()
        var limit: UInt64 = 256 * 1024 * 1024
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
    }

    /// Visible placements, in protocol z order.
    func imagePlacements() -> [TerminalImagePlacement] {
        guard let graphics = kittyGraphics else { return [] }
        var iterator: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS, let iterator else { return [] }
        defer { ghostty_kitty_graphics_placement_iterator_free(iterator) }
        var handle: GhosttyKittyGraphicsPlacementIterator? = iterator
        guard ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, &handle) == GHOSTTY_SUCCESS
        else { return [] }

        var placements: [(z: Int32, placement: TerminalImagePlacement)] = []
        while ghostty_kitty_graphics_placement_next(iterator) {
            var imageID: UInt32 = 0, z: Int32 = 0
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)
            ghostty_kitty_graphics_placement_get(iterator, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z)
            guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
            var info = sized(GhosttyKittyGraphicsPlacementRenderInfo())
            guard ghostty_kitty_graphics_placement_render_info(iterator, image, terminal, &info) == GHOSTTY_SUCCESS,
                  info.viewport_visible, info.pixel_width > 0, info.pixel_height > 0 else { continue }
            var generation: UInt64 = 0, width: UInt32 = 0, height: UInt32 = 0
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation)
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
            ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
            placements.append((z, TerminalImagePlacement(
                imageID: imageID, generation: generation,
                column: Int(info.viewport_col), row: Int(info.viewport_row),
                width: Int(info.pixel_width), height: Int(info.pixel_height),
                source: (Int(info.source_x), Int(info.source_y), Int(info.source_width), Int(info.source_height)),
                imageSize: (Int(width), Int(height)), isBelowText: z < 0)))
        }
        return placements.enumerated().sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }.map(\.element.placement)
    }

    /// The image's current pixels as straight-alpha RGBA8.
    func imagePixels(_ imageID: UInt32) -> DecodedImage? {
        guard let graphics = kittyGraphics, let image = ghostty_kitty_graphics_image(graphics, imageID) else { return nil }
        var width: UInt32 = 0, height: UInt32 = 0, length = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var data: UnsafePointer<UInt8>?
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &length)
        guard ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &data) == GHOSTTY_SUCCESS,
              let data, width > 0, height > 0 else { return nil }
        let pixels = Int(width) * Int(height)
        let channels: Int
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB: channels = 3
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY_ALPHA: channels = 2
        case GHOSTTY_KITTY_IMAGE_FORMAT_GRAY: channels = 1
        default: channels = 4
        }
        guard length >= pixels * channels else { return nil }
        let source = UnsafeBufferPointer(start: data, count: pixels * channels)
        var rgba = [UInt8](repeating: 255, count: pixels * 4)
        for index in 0..<pixels {
            let input = index * channels, output = index * 4
            switch channels {
            case 4: rgba[output] = source[input]; rgba[output + 1] = source[input + 1]
                rgba[output + 2] = source[input + 2]; rgba[output + 3] = source[input + 3]
            case 3: rgba[output] = source[input]; rgba[output + 1] = source[input + 1]; rgba[output + 2] = source[input + 2]
            case 2: rgba[output] = source[input]; rgba[output + 1] = source[input]; rgba[output + 2] = source[input]
                rgba[output + 3] = source[input + 1]
            default: rgba[output] = source[input]; rgba[output + 1] = source[input]; rgba[output + 2] = source[input]
            }
        }
        return DecodedImage(pixels: rgba, width: Int(width), height: Int(height))
    }

    private var kittyGraphics: GhosttyKittyGraphics? {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS else { return nil }
        return graphics
    }
}

/// Process-wide PNG decoding for Kitty `f=100` images (a Ghostty sys hook).
private enum PNGDecoder {
    private static let installed: Void = {
        let decode: GhosttySysDecodePngFn = { _, allocator, data, length, out in
            guard let data, let out, length > 0,
                  let image = try? ImageDecoder.decode(data: Data(bytes: data, count: length)),
                  image.pixels.count == image.width * image.height * 4,
                  let buffer = ghostty_alloc(allocator, image.pixels.count) else { return false }
            image.pixels.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: $0.count) }
            out.pointee.width = UInt32(image.width)
            out.pointee.height = UInt32(image.height)
            out.pointee.data = buffer
            out.pointee.data_len = image.pixels.count
            return true
        }
        ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decode, to: UnsafeRawPointer.self))
    }()

    static func install() { _ = installed }
}
