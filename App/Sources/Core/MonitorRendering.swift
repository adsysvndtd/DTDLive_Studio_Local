import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Monitor pixels follow the visible view, including Retina and external displays.
/// No extra full-resolution preview render when the operator only needs a small tile.
enum MonitorRendering {
    static func renderSize(maximum: CGSize, targets: [CGSize]) -> CGSize? {
        guard maximum.width.isFinite, maximum.height.isFinite,
              maximum.width >= 2, maximum.height >= 2 else { return nil }
        let scale = targets.filter { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 }
            .map { min($0.width / maximum.width, $0.height / maximum.height) }.max() ?? 0
        guard scale > 0 else { return nil }
        let k = min(scale, 1)
        // Even YUV dimensions; never exceed program resolution or stretch the picture.
        return CGSize(width: min(floor(maximum.width / 2) * 2, max(2, ceil(maximum.width * k / 2) * 2)),
                      height: min(floor(maximum.height / 2) * 2, max(2, ceil(maximum.height * k / 2) * 2)))
    }

    /// Shared spatial resampling for monitors, program and layout windows.
    /// A near-1 resize must still happen: skipping it leaves seams at slot edges.
    static func resample(_ source: CIImage, scale: CGFloat) -> CIImage {
        guard scale.isFinite, scale > 0, scale != 1 else { return source }
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return filter.outputImage ?? source.transformed(by: .init(scaleX: scale, y: scale))
    }

    static func aspectFit(_ source: CIImage, in size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        let background = CIImage(color: .black).cropped(to: bounds)
        guard size.width > 0, size.height > 0, source.extent.width > 0, source.extent.height > 0 else { return background }
        let scale = min(size.width / source.extent.width, size.height / source.extent.height)
        let scaled = resample(source, scale: scale)
        return scaled.transformed(by: .init(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                           y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
            .composited(over: background).cropped(to: bounds)
    }
}
