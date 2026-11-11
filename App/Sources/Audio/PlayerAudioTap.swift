@preconcurrency import AVFoundation
import MediaToolbox

/// Pulls decoded PCM out of an AVPlayerItem (MTAudioProcessingTap) so a movie's sound
/// goes into the program mixer like any other source. The tap silences the player's own
/// output, so nothing plays twice on the speaker.
final class PlayerAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (AVAudioPCMBuffer) -> Void

    /// Context reachable from the C callbacks via the tap's storage pointer.
    final class Context {
        var format: AVAudioFormat?
        let handler: Handler
        init(handler: @escaping Handler) { self.handler = handler }
    }

    private let context: Context

    init(handler: @escaping Handler) { context = Context(handler: handler) }

    /// Attaches to the item's first audio track. Safe to call once per item.
    func attach(to item: AVPlayerItem) async {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(context).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, asbd in
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                var d = asbd.pointee
                ctx.format = AVAudioFormat(streamDescription: &d)
            },
            unprepare: { tap in
                Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().format = nil
            },
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                let ctx = Unmanaged<Context>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let n = AVAudioFrameCount(framesOut.pointee)
                let abl = UnsafeMutableAudioBufferListPointer(bufferList)
                if let fmt = ctx.format, n > 0, let copy = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) {
                    copy.frameLength = n
                    let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for i in 0..<min(abl.count, dst.count) {
                        if let s = abl[i].mData, let d = dst[i].mData {
                            memcpy(d, s, Int(min(abl[i].mDataByteSize, dst[i].mDataByteSize)))
                        }
                    }
                    ctx.handler(copy)
                }
                // Silence the player's own output: the mixer plays this audio.
                for b in abl { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(context).release()
            return
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        await MainActor.run { item.audioMix = mix }
    }
}
