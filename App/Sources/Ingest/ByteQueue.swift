/// Receive buffer for the RTMP / RTSP servers: zero-based like an array, but taking bytes off the front is
/// O(1). With `[UInt8].removeFirst` every parsed chunk / RTP packet shifted the whole rest of the buffer —
/// a 256 KB read of small packets meant tens of MB of copying, a hot CPU and dropped frames.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    subscript(i: Int) -> UInt8 { storage[head + i] }
    subscript(r: Range<Int>) -> ArraySlice<UInt8> { storage[(head + r.lowerBound)..<(head + r.upperBound)] }

    mutating func append<S: Sequence>(contentsOf s: S) where S.Element == UInt8 { storage.append(contentsOf: s) }

    mutating func removeFirst(_ n: Int) {
        head += max(0, min(n, count))
        if head == storage.count {
            storage.removeAll(keepingCapacity: true); head = 0
        } else if head >= 64 * 1024, head * 2 >= storage.count {
            storage.removeFirst(head); head = 0          // compact now and then, not on every packet
        }
    }

    mutating func removeAll() { storage.removeAll(); head = 0 }
}
