import CoreImage
import Foundation
@main struct Check {
 static func main() {
  func close(_ a: CGFloat, _ b: CGFloat) { precondition(abs(a-b) < 2, "\(a) vs \(b)") }
  let size = CGSize(width: 1920, height: 1080)
  precondition(MonitorRendering.renderSize(maximum: size, targets: []) == nil)
  precondition(MonitorRendering.renderSize(maximum: size, targets: [CGSize(width: 640, height: 360), size]) == size)
  let source = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 1280, height: 720))
  for k: CGFloat in [0.25, 0.5, 0.995, 1, 1.005, 1.5] {
   let image = MonitorRendering.resample(source, scale: k)
   close(image.extent.width, 1280*k); close(image.extent.height, 720*k)
  }
  let portrait = CIImage(color: .red).cropped(to: CGRect(x: 70, y: 90, width: 1080, height: 1920))
  precondition(MonitorRendering.aspectFit(portrait, in: size).extent == CGRect(origin: .zero, size: size))
  print("PASS: downscale/upscale, near-1 scale, Retina target sizing, portrait fit and nonzero origin")
 }
}
