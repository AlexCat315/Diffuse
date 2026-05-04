import COCIOBridge
import Foundation

public final class OCIOBridge: @unchecked Sendable {
    private var context: GuavaOCIOContext?

    public init?(configPath: String) {
        guard let ctx = guava_ocio_context_create(configPath) else { return nil }
        guard guava_ocio_context_is_valid(ctx) else {
            guava_ocio_context_destroy(ctx)
            return nil
        }
        self.context = ctx
    }

    deinit {
        if let context {
            guava_ocio_context_destroy(context)
        }
    }

    public var isAvailable: Bool { context != nil }

    public var colorSpaceNames: [String] {
        guard let ctx = context else { return [] }
        let count = guava_ocio_get_color_space_count(ctx)
        return (0..<count).compactMap { i in
            guard let name = guava_ocio_get_color_space_name(ctx, i) else { return nil }
            return String(cString: name)
        }
    }

    public func applyTransform(
        inputColorSpace: String,
        outputColorSpace: String,
        viewTransform: String? = nil,
        display: String? = nil,
        exposure: Float = 0,
        gamma: Float = 1,
        to pixels: inout [Float],
        width: Int32,
        height: Int32
    ) -> Bool {
        guard let ctx = context else { return false }
        let vt = viewTransform ?? ""
        let dsp = display ?? ""
        let inputCStr = (inputColorSpace as NSString).utf8String!
        let outputCStr = (outputColorSpace as NSString).utf8String!
        let vtCStr = (vt as NSString).utf8String!
        let dspCStr = (dsp as NSString).utf8String!
        var desc = GuavaOCIOTransformDesc(
            input_color_space: inputCStr,
            output_color_space: outputCStr,
            view_transform: vtCStr,
            display: dspCStr,
            exposure: exposure,
            gamma: gamma,
            use_gpu: false
        )
        return guava_ocio_apply_transform_rgba(ctx, &desc, &pixels, width, height)
    }
}
