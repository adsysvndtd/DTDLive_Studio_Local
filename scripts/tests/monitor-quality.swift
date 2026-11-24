import Foundation
import CoreImage
import CoreVideo

@main
enum MonitorQualityChecks {
    static func main() throws {
        let fhd = CGSize(width: 1920, height: 1080)
        let retina = CGSize(width: 1440, height: 810)
        precondition(MonitorRendering.renderSize(maximum: fhd, targets: [retina]) == retina)
        precondition(MonitorRendering.renderSize(maximum: fhd, targets: [CGSize(width: 3840, height: 2160)]) == fhd)
        precondition(MonitorRendering.renderSize(maximum: CGSize(width: 3840, height: 2160), targets: [fhd]) == fhd)
        precondition(MonitorRendering.renderSize(maximum: fhd, targets: []) == nil)
        precondition(MonitorRendering.renderSize(maximum: fhd, targets: [.zero, CGSize(width: CGFloat.nan, height: 2)]) == nil)
        let portrait = MonitorRendering.renderSize(maximum: CGSize(width: 1080, height: 1920), targets: [CGSize(width: 800, height: 450)])!
        precondition(portrait == CGSize(width: 254, height: 450))

        let store = FrameStore(), phone = UUID(), external = UUID()
        store.setMonitorTarget(CGSize(width: 640, height: 360), for: phone)
        store.setMonitorTarget(retina, for: external)
        precondition(store.monitorRenderSize(maximum: fhd) == retina)
        store.setMonitorTarget(nil, for: external)
        precondition(store.monitorRenderSize(maximum: fhd) == CGSize(width: 640, height: 360))
        store.setMonitorTarget(nil, for: phone)
        precondition(store.monitorRenderSize(maximum: fhd) == nil)

        // Render actual pixels to verify aspect fit, image centring, and all four edge markers.
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let sourceBounds = CGRect(x: 0, y: 0, width: 320, height: 180)
        var source = CIImage(color: .green).cropped(to: sourceBounds)
        for rect in [CGRect(x: 0,y: 0,width: 20,height: 20), CGRect(x: 300,y: 0,width: 20,height: 20),
                     CGRect(x: 0,y: 160,width: 20,height: 20), CGRect(x: 300,y: 160,width: 20,height: 20)] {
            source = CIImage(color: .red).cropped(to: rect).composited(over: source)
        }
        source = source.transformed(by: .init(translationX: 37, y: -12))
        let result = MonitorRendering.aspectFit(source, in: CGSize(width: 160,height: 160))
        func pixel(_ x: Int,_ y: Int) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            ctx.render(result, toBitmap: &rgba, rowBytes: 4,
                       bounds: CGRect(x: x,y: y,width: 1,height: 1), format: .RGBA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
            return rgba
        }
        precondition(result.extent == CGRect(x: 0,y: 0,width: 160,height: 160))
        for (x,y) in [(5,40),(155,40),(5,120),(155,120)] {
            let p = pixel(x,y); precondition(p[0] > 200 && p[1] < 30)
        }
        let center = pixel(80,80), bar = pixel(80,5)
        precondition(center[1] > 200 && center[0] < 30)
        precondition(bar[0] < 5 && bar[1] < 5 && bar[2] < 5)
        print("PASS: monitor demand, Retina/external size, portrait aspect, teardown and rendered pixel checks")
    }
}
