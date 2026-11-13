// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import XCTest
@testable import OpenRayneoCore

final class OpenRayneoCoreTests: XCTestCase {
    private static func hexData(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let byte = UInt8(hex[index..<next], radix: 16)!
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    private static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func testGoldenProtocolVectors() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/protocol-vectors.json")
        let raw = try Data(contentsOf: fixtureURL)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])

        let crcCases = try XCTUnwrap(root["crc16_xmodem"] as? [[String: Any]])
        for entry in crcCases {
            let hex = try XCTUnwrap(entry["hex"] as? String)
            let expected = UInt16(try XCTUnwrap(entry["crc16"] as? Int))
            XCTAssertEqual(ProtocolCodec.crc16XModem(Self.hexData(hex)), expected)
        }

        let frames = try XCTUnwrap(root["frames"] as? [String: Any])

        let notifSpec = try XCTUnwrap(frames["notification"] as? [String: Any])
        let notifFrame = try ProtocolCodec.notificationFrame(sequence: 7, body: ["appId": "com.test", "content": "Hi"])
        XCTAssertEqual(Self.hexString(notifFrame), notifSpec["hex"] as? String)

        let dispSpec = try XCTUnwrap(frames["display"] as? [String: Any])
        let dispFrame = try ProtocolCodec.displayFrame(protocolID: 0x17, sequence: 42, type: 5, body: ["sid": "abc", "status": 1])
        XCTAssertEqual(Self.hexString(dispFrame), dispSpec["hex"] as? String)

        let pairSpec = try XCTUnwrap(frames["pairing"] as? [String: Any])
        let pairFrame = try ProtocolCodec.pairingFrame(
            sequence: 3,
            command: 24,
            fields: [(16, Data([1, 2, 3, 4])), (17, Data([0xaa, 0xbb]))]
        )
        XCTAssertEqual(Self.hexString(pairFrame), pairSpec["hex"] as? String)
        let decodedPairFrame = try XCTUnwrap(ProtocolCodec.decodeFrame(pairFrame))
        let parsedPair = try XCTUnwrap(ProtocolCodec.pairingCommand(decodedPairFrame.payload))
        XCTAssertEqual(parsedPair.0, 24)
        XCTAssertEqual(parsedPair.2[16], Data([1, 2, 3, 4]))
        XCTAssertEqual(parsedPair.2[17], Data([0xaa, 0xbb]))

        let ackSpec = try XCTUnwrap(frames["acknowledgement"] as? [String: Any])
        let ackFrame = ProtocolCodec.acknowledgementFrame(protocolID: 0x17, sequence: 42)
        XCTAssertEqual(Self.hexString(ackFrame), ackSpec["hex"] as? String)
        let decodedAck = try XCTUnwrap(ProtocolCodec.decodeFrame(ackFrame))
        XCTAssertTrue(decodedAck.isAcknowledgement)
        XCTAssertFalse(decodedAck.requiresAcknowledgement)
        XCTAssertNil(ProtocolCodec.decodeRemoteFrame(ackFrame))

        let extSpec = try XCTUnwrap(frames["extended_flags"] as? [String: Any])
        let extRaw = Self.hexData(try XCTUnwrap(extSpec["hex"] as? String))
        let decodedExt = try XCTUnwrap(ProtocolCodec.decodeFrame(extRaw))
        XCTAssertEqual(decodedExt.protocolID, 0x13)
        XCTAssertEqual(decodedExt.sequence, 258)
        XCTAssertEqual(decodedExt.flags, 67)
        XCTAssertTrue(decodedExt.requiresAcknowledgement)
        let extMessage = try XCTUnwrap(ProtocolCodec.decodeRemoteMessage(from: decodedExt))
        XCTAssertEqual(extMessage.action, 2)
        XCTAssertEqual(extMessage.messageType, 8)
        XCTAssertEqual(extMessage.json?["sid"] as? String, "abc")

        let recoverySpec = try XCTUnwrap(root["stream_recovery"] as? [String: Any])
        let streamBytes = Self.hexData(try XCTUnwrap(recoverySpec["hex"] as? String))
        let expectedStream = try XCTUnwrap(recoverySpec["expected_frames"] as? [[String: Any]])
        let decoder = ProtocolStreamDecoder()
        var recovered: [ProtocolFrame] = []
        for byte in streamBytes {
            recovered.append(contentsOf: decoder.append(Data([byte])))
        }
        XCTAssertEqual(recovered.count, expectedStream.count)
        for (actual, spec) in zip(recovered, expectedStream) {
            XCTAssertEqual(Int(actual.protocolID), spec["protocol"] as? Int)
            XCTAssertEqual(Int(actual.sequence), spec["sequence"] as? Int)
            XCTAssertEqual(Int(actual.flags), spec["flags"] as? Int)
            XCTAssertEqual(actual.isAcknowledgement, spec["acknowledgement"] as? Bool)
        }
    }

    func testNonZeroStartIndexSlices() throws {
        let frame = try ProtocolCodec.displayFrame(protocolID: 0x13, sequence: 9, type: 7, body: ["sid": "s1"])
        var prefixed = Data([0xde, 0xad, 0xbe, 0xef, 0x00])
        prefixed.append(frame)
        let slice = prefixed[5..<prefixed.count]
        XCTAssertEqual(slice.startIndex, 5)
        let message = try XCTUnwrap(ProtocolCodec.decodeRemoteFrame(slice))
        XCTAssertEqual(message.protocolID, 0x13)
        XCTAssertEqual(message.sequence, 9)
        XCTAssertEqual(message.messageType, 7)
        XCTAssertEqual(message.json?["sid"] as? String, "s1")
    }

    func testNavigationGridInvariants() {
        for direction in NavigationDirection.allCases {
            for meters in [0, 85, 9999, 25_000] {
                let rows = NavigationFrame.rows(direction: direction, meters: meters)
                XCTAssertEqual(rows.count, 5)
                for row in rows {
                    XCTAssertEqual(row.count, 20)
                }
                let firstPayload = NavigationFrame.payload(direction: direction, meters: meters, compensateFirstCell: false)
                let nextPayload = NavigationFrame.payload(direction: direction, meters: meters, compensateFirstCell: true)
                let firstText = firstPayload["text"] as? String ?? ""
                let nextText = nextPayload["text"] as? String ?? ""
                XCTAssertEqual(nextText, "\u{3000}" + firstText)
            }
        }
    }

    func testWAVSampleQuantizationSafety() {
        XCTAssertEqual(WAVRecording.quantizeSample(.nan), 0)
        XCTAssertEqual(WAVRecording.quantizeSample(.infinity), 0)
        XCTAssertEqual(WAVRecording.quantizeSample(-.infinity), 0)
        XCTAssertEqual(WAVRecording.quantizeSample(.greatestFiniteMagnitude), Int16.max)
        XCTAssertEqual(WAVRecording.quantizeSample(-.greatestFiniteMagnitude), Int16.min)
        XCTAssertEqual(WAVRecording.quantizeSample(0.0), 0)
        XCTAssertEqual(WAVRecording.quantizeSample(0.5), 16_384)
        XCTAssertEqual(WAVRecording.quantizeSample(-1.0), Int16.min)
        XCTAssertEqual(WAVRecording.quantizeSample(1.0), Int16.max)
    }

    func testTextVideoTargetViewport() {
        XCTAssertEqual(
            TextVideo.targetViewport(sourceWidth: 1920, sourceHeight: 1080, preserveAspectRatio: false),
            CGRect(x: 0, y: 0, width: 52, height: 28)
        )
        XCTAssertEqual(
            TextVideo.targetViewport(sourceWidth: 1920, sourceHeight: 1080, preserveAspectRatio: true),
            CGRect(x: 13, y: 0, width: 25, height: 28)
        )
        XCTAssertEqual(
            TextVideo.targetViewport(sourceWidth: 640, sourceHeight: 480, preserveAspectRatio: true),
            CGRect(x: 16, y: 0, width: 19, height: 28)
        )
        XCTAssertEqual(
            TextVideo.targetViewport(sourceWidth: 400, sourceHeight: 100, preserveAspectRatio: true),
            CGRect(x: 0, y: 1, width: 52, height: 26)
        )
    }

    func testHTTPServerRequestParsingAndSecurity() throws {
        // Query string stripping & case-insensitive headers
        let rawGet = Data("GET /v1/device?verbose=1 HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nAuthorization: Bearer tok123\r\n\r\n".utf8)
        let parsedGet = try XCTUnwrap(LocalHTTPServer.parseRequestBuffer(rawGet))
        XCTAssertEqual(parsedGet.method, "GET")
        XCTAssertEqual(parsedGet.path, "/v1/device")
        XCTAssertEqual(parsedGet.rawTarget, "/v1/device?verbose=1")
        XCTAssertEqual(parsedGet.headers["host"], "127.0.0.1:8765")

        // Partial large body (near 1 MB) must return nil instead of trapping out-of-bounds!
        let largeLength = 999_900
        let headerPrefix = Data("POST /v1/teleprompter HTTP/1.1\r\nHost: localhost:8765\r\nContent-Length: \(largeLength)\r\n\r\n".utf8)
        var partialLarge = headerPrefix
        partialLarge.append(Data(repeating: 0x61, count: 60_000))
        XCTAssertNil(try LocalHTTPServer.parseRequestBuffer(partialLarge))

        var completeLarge = headerPrefix
        completeLarge.append(Data(repeating: 0x61, count: largeLength))
        let parsedLarge = try XCTUnwrap(LocalHTTPServer.parseRequestBuffer(completeLarge))
        XCTAssertEqual(parsedLarge.body.count, largeLength)

        // Body > 1 MB rejected with 413
        let tooLarge = Data("POST /v1/teleprompter HTTP/1.1\r\nContent-Length: 1000001\r\n\r\n".utf8)
        XCTAssertThrowsError(try LocalHTTPServer.parseRequestBuffer(tooLarge)) { error in
            XCTAssertEqual((error as? BridgeError)?.status, 413)
        }

        // Headers > 32 KiB rejected with 431
        let hugeHeader = Data(("GET /health HTTP/1.1\r\nX-Junk: " + String(repeating: "a", count: 33_000)).utf8)
        XCTAssertThrowsError(try LocalHTTPServer.parseRequestBuffer(hugeHeader)) { error in
            XCTAssertEqual((error as? BridgeError)?.status, 431)
        }

        // Host header validation
        XCTAssertTrue(LocalHTTPServer.isAllowedHostHeader(nil))
        XCTAssertTrue(LocalHTTPServer.isAllowedHostHeader("127.0.0.1:8765"))
        XCTAssertTrue(LocalHTTPServer.isAllowedHostHeader("localhost:8765"))
        XCTAssertTrue(LocalHTTPServer.isAllowedHostHeader("[::1]:8765"))
        XCTAssertFalse(LocalHTTPServer.isAllowedHostHeader("evil.example.com:8765"))
        XCTAssertFalse(LocalHTTPServer.isAllowedHostHeader("127.0.0.1:bad"))

        // Constant-time bearer check
        XCTAssertTrue(LocalHTTPServer.isValidBearerHeader("Bearer secret-token", expectedToken: "secret-token"))
        XCTAssertFalse(LocalHTTPServer.isValidBearerHeader("Bearer secret-toke", expectedToken: "secret-token"))
        XCTAssertFalse(LocalHTTPServer.isValidBearerHeader("Bearer secret-token-extra", expectedToken: "secret-token"))
        XCTAssertFalse(LocalHTTPServer.isValidBearerHeader("Basic secret-token", expectedToken: "secret-token"))
        XCTAssertFalse(LocalHTTPServer.isValidBearerHeader(nil, expectedToken: "secret-token"))
    }
}
