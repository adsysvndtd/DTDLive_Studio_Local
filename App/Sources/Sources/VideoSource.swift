import AVFoundation
import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case camera, srt, rtmpPull, rtsp, file
    var id: String { rawValue }
    var label: String {
        switch self {
        case .camera: return "Camera / UVC"
        case .srt: return "SRT"
        case .rtmpPull: return "RTMP (play)"
        case .rtsp: return "RTSP (IP camera)"
        case .file: return "Video file"
        }
    }
}

enum SourceStatus: Equatable { case idle, connecting, live, error(String) }

/// An input on the switcher. Each source owns a FrameStore the compositor samples.
@MainActor
protocol VideoSource: AnyObject, Identifiable where ID == UUID {
    var id: UUID { get }
    var name: String { get set }
    var kind: SourceKind { get }
    var frames: FrameStore { get }
    var status: SourceStatus { get }
    func start() async
    func stop() async
}
