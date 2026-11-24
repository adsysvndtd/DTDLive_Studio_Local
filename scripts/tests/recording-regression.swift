import Foundation

// Lightweight media/transport doubles. The runner inserts the production
// OutputSlot/Counter and AudioCaptureClock, rather than reimplementing their logic.
struct CMSampleBuffer: Sendable { var isKeyframe = true }
struct AVAudioCompressedBuffer: Sendable {}
struct AVAudioTime: Sendable {}
struct StreamDescription: Sendable {}
enum OutputStatus: Equatable { case idle, connecting, live, finishing, reconnecting(Int), error(String) }
struct OutputConfig: Sendable { let id = UUID() }
protocol OutputTarget: AnyObject, Sendable {
    var config: OutputConfig { get }
    func connect(_ d: StreamDescription) async throws
    func disconnect() async
    func isHealthy() async -> Bool
    func send(video: CMSampleBuffer) async
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async
    func pendingBytes() async -> Int
}
extension OutputTarget { func pendingBytes() async -> Int { 0 } }
func L(_ s: String) -> String { s }
func LF(_ s: String, _ args: String...) -> String { s }
struct OutputLog: Sendable {
    static let shared = OutputLog()
    func add(_ id: UUID, _ text: String) {}
}
enum StreamStats { static let bitrateKbps = 6000 }
actor RecordOutput: OutputTarget {
    nonisolated let config = OutputConfig()
    var connects = 0, closes = 0, videos = 0
    var opening = false
    var error: String?
    func connect(_ d: StreamDescription) async throws {
        opening = true; connects += 1
        try? await Task.sleep(nanoseconds: 10_000_000)
        opening = false
    }
    func disconnect() async { precondition(!opening); closes += 1 }
    func isHealthy() -> Bool { error == nil }
    func send(video: CMSampleBuffer) async { videos += 1 }
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async {}
    func fail(_ text: String) { error = text }
    func recordingError() -> String? { error }
}
actor NetworkTarget: OutputTarget {
    nonisolated let config = OutputConfig()
    var connects = 0, closes = 0
    var opening = false
    func connect(_ d: StreamDescription) async throws {
        opening = true; connects += 1
        try? await Task.sleep(nanoseconds: 50_000_000)
        opening = false
    }
    func disconnect() async { precondition(!opening); closes += 1 }
    func isHealthy() -> Bool { true }
    func send(video: CMSampleBuffer) async {}
    func send(audio: AVAudioCompressedBuffer, when: AVAudioTime) async {}
}
@main struct RecordingRegression {
    static func waitForLive(_ slot: OutputSlot) async throws {
        for _ in 0..<100 {
            if await slot.status == .live { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        preconditionFailure("Slot failed to become live")
    }
    static func main() async throws {
        let network = NetworkTarget()
        let slot = OutputSlot(target: network, requestKeyframe: {})
        await slot.start(StreamDescription())
        try await Task.sleep(nanoseconds: 5_000_000)
        async let stop1: Void = slot.stop()
        async let stop2: Void = slot.stop()
        _ = await (stop1, stop2)
        await slot.start(StreamDescription())
        let closes = await network.closes, connects = await network.connects
        precondition(closes == 1 && connects == 1)
        print("PASS: stop during connect; simultaneous stops; no restart of stopped slot")

        let record = RecordOutput()
        let rec = OutputSlot(target: record, requestKeyframe: {})
        await rec.start(StreamDescription())
        try await waitForLive(rec)
        for _ in 0..<40 { rec.enqueue(.video(CMSampleBuffer())) }
        async let r1: Void = rec.stop()
        async let r2: Void = rec.stop()
        _ = await (r1, r2)
        let videos = await record.videos, recCloses = await record.closes
        precondition(videos == 40 && recCloses == 1)
        print("PASS: all queued recording frames drained before one close")

        let failed = RecordOutput()
        let failureSlot = OutputSlot(target: failed, requestKeyframe: {})
        await failureSlot.start(StreamDescription())
        try await waitForLive(failureSlot)
        await failed.fail("disk full")
        try await Task.sleep(nanoseconds: 1_100_000_000)
        let failureStatus = await failureSlot.status
        let failureConnects = await failed.connects
        precondition(failureStatus == .error("disk full") && failureConnects == 1)
        print("PASS: recording failure remains terminal; no silent reconnect")

        var clock = AudioCaptureClock()
        precondition(!clock.accept(seconds: 100, frames: 1024, sampleRate: 48000))
        precondition(clock.nextPacket(sampleRate: 48000) == 100)
        precondition(!clock.accept(seconds: 100 + 1024.0/48000, frames: 1024, sampleRate: 48000))
        precondition(clock.accept(seconds: 500, frames: 1024, sampleRate: 48000))
        precondition(clock.nextPacket(sampleRate: 48000) == 500)
        precondition(clock.accept(seconds: 50, frames: 1024, sampleRate: 48000))
        precondition(clock.nextPacket(sampleRate: 48000) == 50)
        print("PASS: audio timeline re-anchors after capture gaps and backwards jumps")
    }
}
