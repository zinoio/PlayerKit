import Foundation

/// Contiguous circular byte buffer for interleaved Float32 PCM samples.
///
/// Designed to sit between the audio decode thread (`enqueueDirect`) and the
/// CoreAudio Pull-mode `AudioUnit` render callback (`audioUnitRenderCallback`).
/// Callers serialize access with an external lock; both `write` and `read` do
/// at most two `memcpy`s and zero heap allocations in steady state.
final class PCMRingBuffer {
    private var storage: UnsafeMutableRawPointer
    private(set) var capacity: Int
    private var head: Int = 0
    private var tail: Int = 0
    private(set) var count: Int = 0

    /// Hard upper bound to prevent unbounded memory growth (~40s @ 48kHz 2ch f32).
    private let maxCapacity: Int

    var readableBytes: Int { count }
    var writableBytes: Int { capacity - count }

    init(capacity: Int = 2 * 1024 * 1024, maxCapacity: Int = 16 * 1024 * 1024) {
        let cap = max(4096, capacity)
        self.capacity = cap
        self.maxCapacity = max(cap, maxCapacity)
        self.storage = UnsafeMutableRawPointer.allocate(byteCount: cap, alignment: 16)
    }

    deinit {
        storage.deallocate()
    }

    /// Ensure backing storage holds at least `minBytes` without losing existing data.
    func ensureCapacity(_ minBytes: Int) {
        let target = min(maxCapacity, max(minBytes, capacity))
        guard target > capacity else { return }
        let newStorage = UnsafeMutableRawPointer.allocate(byteCount: target, alignment: 16)
        if count > 0 {
            let first = min(count, capacity - head)
            newStorage.copyMemory(from: storage.advanced(by: head), byteCount: first)
            let second = count - first
            if second > 0 {
                newStorage.advanced(by: first).copyMemory(from: storage, byteCount: second)
            }
        }
        storage.deallocate()
        storage = newStorage
        capacity = target
        head = 0
        tail = count
    }

    /// Append bytes from `data`. Grows up to `maxCapacity` if needed; returns bytes written.
    @discardableResult
    func write(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        return data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return write(base, count: raw.count)
        }
    }

    /// Append `n` bytes from `src`. Grows up to `maxCapacity` if needed; returns bytes written.
    @discardableResult
    func write(_ src: UnsafeRawPointer, count n: Int) -> Int {
        guard n > 0 else { return 0 }
        if n > writableBytes && capacity < maxCapacity {
            let needed = count + n
            let doubled = max(needed, capacity * 2)
            ensureCapacity(doubled)
        }
        let toWrite = min(n, writableBytes)
        guard toWrite > 0 else { return 0 }
        let first = min(toWrite, capacity - tail)
        storage.advanced(by: tail).copyMemory(from: src, byteCount: first)
        let second = toWrite - first
        if second > 0 {
            storage.copyMemory(from: src.advanced(by: first), byteCount: second)
        }
        tail = (tail + toWrite) % capacity
        count += toWrite
        return toWrite
    }

    /// Read up to `n` bytes into `dst`. Returns bytes actually read.
    @discardableResult
    func read(into dst: UnsafeMutableRawPointer, count n: Int) -> Int {
        let toRead = min(n, count)
        guard toRead > 0 else { return 0 }
        let first = min(toRead, capacity - head)
        dst.copyMemory(from: storage.advanced(by: head), byteCount: first)
        let second = toRead - first
        if second > 0 {
            dst.advanced(by: first).copyMemory(from: storage, byteCount: second)
        }
        head = (head + toRead) % capacity
        count -= toRead
        return toRead
    }

    /// Discard all buffered bytes without freeing backing storage.
    func reset() {
        head = 0
        tail = 0
        count = 0
    }
}
