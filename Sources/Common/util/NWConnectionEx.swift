import Network
import Foundation

extension NWConnection {
    public func writeAtomic(_ msg: Codable, _ encoder: JSONEncoder = JSONEncoder()) async -> ((), error: NWError?) {
        let payload: Data
        do {
            payload = try encoder.encode(msg)
        } catch {
            return ((), .posix(.EINVAL))
        }
        guard payload.count <= maximumSocketFrameSize else { return ((), .posix(.EMSGSIZE)) }
        var data = withUnsafeBytes(of: UInt32(payload.count)) { Data($0) }
        check(data.count == 4)
        data.append(payload)
        return await withCheckedContinuation { cont in
            send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(returning: ((), error))
                } else {
                    cont.resume(returning: ((), nil))
                }
            })
        }
    }

    public func startBlocking() async -> ((), error: NWError?) {
        await withCheckedContinuation { cont in
            let isDone = IsDone()
            stateUpdateHandler = { state in
                Task {
                    let error: NWError?
                    switch state {
                        case .preparing, .setup: return
                        case .cancelled: error = .posix(.ECANCELED)
                        case .ready: error = nil
                        case .failed(let e), .waiting(let e): error = e
                        @unknown default: die("Unknown NWConnection.State: \(state)")
                    }
                    // Make sure to resume continuation only once
                    if await isDone.markAsDone().wasAlreadyDone {
                        return
                    }
                    self.stateUpdateHandler = nil
                    cont.resume(returning: ((), error))
                }
            }
            start(queue: .global())
        }
    }

    public func readTillError() async {
        while true {
            let isError = await withCheckedContinuation { cont in
                receive(minimumIncompleteLength: 1, maximumLength: Int.max) { data, context, isComplete, error in
                    cont.resume(returning: error != nil || data == nil || data?.count == 0)
                }
            }
            if isError { return }
        }
    }

    public func readNonAtomic() async -> Result<Data, NWError> {
        await readSocketFrame { size in
            await withCheckedContinuation { cont in
                self.receive(minimumIncompleteLength: 1, maximumLength: size) { data, _, isComplete, error in
                    if let error {
                        cont.resume(returning: .failure(error))
                    } else {
                        cont.resume(returning: .success(SocketReadChunk(data: data ?? Data(), isComplete: isComplete)))
                    }
                }
            }
        }
    }
}

// Bound allocation for the private local protocol, including CLI stdin and command output.
let maximumSocketFrameSize = 16 * 1024 * 1024

struct SocketReadChunk: Sendable {
    let data: Data
    let isComplete: Bool
}

/// Kept independent of NWConnection so fragmentation and clean EOF can be tested deterministically.
func readSocketFrame(
    receive: @Sendable (Int) async -> Result<SocketReadChunk, NWError>,
) async -> Result<Data, NWError> {
    func read(bytes size: Int) async -> Result<SocketReadChunk, NWError> {
        var data = Data()
        while data.count < size {
            switch await receive(size - data.count) {
                case .failure(let error): return .failure(error)
                case .success(let chunk):
                    data.append(chunk.data)
                    // A completed final chunk is valid if it filled the requested bytes.
                    if data.count == size { return .success(SocketReadChunk(data: data, isComplete: chunk.isComplete)) }
                    guard !chunk.isComplete, !chunk.data.isEmpty else { return .failure(.posix(.ECONNRESET)) }
            }
        }
        return .success(SocketReadChunk(data: data, isComplete: false))
    }

    switch await read(bytes: 4) {
        case .failure(let error): return .failure(error)
        case .success(let header):
            // Preserve the existing native-endian wire format; Data doesn't guarantee alignment.
            let count = Int(header.data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard count <= maximumSocketFrameSize else { return .failure(.posix(.EMSGSIZE)) }
            guard count == 0 || !header.isComplete else { return .failure(.posix(.ECONNRESET)) }
            return await read(bytes: count).map(\.data)
    }
}

private actor IsDone {
    private var isDone: Bool = false

    func markAsDone() -> (wasAlreadyDone: Bool, ()) {
        let old = isDone
        isDone = true
        return (old, ())
    }
}
