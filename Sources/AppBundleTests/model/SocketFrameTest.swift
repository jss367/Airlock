@testable import Common
import Foundation
import Network
import XCTest

final class SocketFrameTest: XCTestCase {
    func testFragmentedHeaderAndPayload() async throws {
        let header = frameHeader(5)
        let receiver = ScriptedReceiver([
            .success(.init(data: Data(header.prefix(1)), isComplete: false)),
            .success(.init(data: Data(header.dropFirst()), isComplete: false)),
            .success(.init(data: Data("he".utf8), isComplete: false)),
            .success(.init(data: Data("llo".utf8), isComplete: true)),
        ])
        let result = await readSocketFrame { await receiver.receive($0) }
        XCTAssertEqual(try result.get(), Data("hello".utf8))
        let requests = await receiver.requests
        XCTAssertEqual(requests, [4, 3, 5, 3])
    }

    func testTruncatedHeaderAndPayloadFailWithoutAnotherReceive() async {
        let cases: [[SocketReadChunk]] = [
            [.init(data: Data(), isComplete: true)],
            [.init(data: Data([1, 0]), isComplete: true)],
            [.init(data: frameHeader(5), isComplete: true)],
            [.init(data: frameHeader(5), isComplete: false), .init(data: Data("hi".utf8), isComplete: true)],
            [.init(data: frameHeader(5), isComplete: false), .init(data: Data(), isComplete: false)],
        ]
        for chunks in cases {
            let receiver = ScriptedReceiver(chunks.map { .success($0) })
            let result = await readSocketFrame { await receiver.receive($0) }
            guard case .failure(.posix(.ECONNRESET)) = result else {
                XCTFail("Expected EOF failure, got \(result)")
                continue
            }
            let requests = await receiver.requests
            XCTAssertEqual(requests.count, chunks.count)
        }
    }

    func testOversizedFrameIsRejectedBeforeReadingPayload() async {
        for size in [UInt32(maximumSocketFrameSize + 1), UInt32.max] {
            let receiver = ScriptedReceiver([.success(.init(data: frameHeader(size), isComplete: false))])
            let result = await readSocketFrame { await receiver.receive($0) }
            guard case .failure(.posix(.EMSGSIZE)) = result else { return XCTFail("Expected frame size error") }
            let requests = await receiver.requests
            XCTAssertEqual(requests, [4])
        }
    }

    func testZeroLengthFrameNeedsNoPayloadRead() async throws {
        let receiver = ScriptedReceiver([.success(.init(data: frameHeader(0), isComplete: true))])
        let result = await readSocketFrame { await receiver.receive($0) }
        XCTAssertEqual(try result.get(), Data())
        let requests = await receiver.requests
        XCTAssertEqual(requests, [4])
    }

    func testTransportErrorIsPreserved() async {
        let receiver = ScriptedReceiver([.failure(.posix(.ECANCELED))])
        let result = await readSocketFrame { await receiver.receive($0) }
        guard case .failure(.posix(.ECANCELED)) = result else { return XCTFail("Expected original transport error") }
    }

    func testOversizedOutboundFrameFailsBeforeSending() async {
        let connection = NWConnection(host: "localhost", port: 1, using: .tcp)
        let result = await connection.writeAtomic(String(repeating: "x", count: maximumSocketFrameSize))
        guard case .posix(.EMSGSIZE)? = result.error else { return XCTFail("Expected outgoing frame size error") }
    }

    func testEncodingFailureIsReturnedInsteadOfCrashing() async {
        let connection = NWConnection(host: "localhost", port: 1, using: .tcp)
        let result = await connection.writeAtomic(Double.nan)
        guard case .posix(.EINVAL)? = result.error else { return XCTFail("Expected encoding error") }
    }

    func testFrameAtSizeLimitIsAccepted() async throws {
        let payload = Data(repeating: 0x61, count: maximumSocketFrameSize)
        let receiver = ScriptedReceiver([
            .success(.init(data: frameHeader(UInt32(payload.count)), isComplete: false)),
            .success(.init(data: payload, isComplete: true)),
        ])
        let result = await readSocketFrame { await receiver.receive($0) }
        XCTAssertEqual(try result.get(), payload)
    }

    private func frameHeader(_ size: UInt32) -> Data { withUnsafeBytes(of: size) { Data($0) } }
}

private actor ScriptedReceiver {
    private var chunks: [Result<SocketReadChunk, NWError>]
    private(set) var requests: [Int] = []

    init(_ chunks: [Result<SocketReadChunk, NWError>]) { self.chunks = chunks }

    func receive(_ size: Int) -> Result<SocketReadChunk, NWError> {
        requests.append(size)
        // An unexpected extra read fails deterministically instead of hanging the test.
        guard !chunks.isEmpty else { return .failure(.posix(.EINVAL)) }
        return chunks.removeFirst()
    }
}
