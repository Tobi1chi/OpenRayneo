// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

public struct BridgeError: Error, LocalizedError {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }
}

struct ProtocolFrame: Equatable {
    let protocolID: UInt8
    let sequence: UInt16
    let flags: UInt8
    let payload: Data
    let isAcknowledgement: Bool

    var requiresAcknowledgement: Bool {
        !isAcknowledgement && (flags & 0x01) != 0
    }
}

struct RemoteMessage {
    let protocolID: UInt8
    let sequence: UInt16
    let flags: UInt8
    let receivedAt: Date
    let protobuf: Data
    let action: UInt64?
    let messageType: UInt64?
    let json: [String: Any]?
    let audioData: Data?
}

enum ProtocolCodec {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var result = Data()
        while value >= 0x80 {
            result.append(UInt8(value & 0x7f) | 0x80)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }

    static func field(_ number: UInt64, varint value: UInt64) -> Data {
        var result = varint((number << 3) | 0)
        result.append(varint(value))
        return result
    }

    static func field(_ number: UInt64, bytes value: Data) -> Data {
        var result = varint((number << 3) | 2)
        result.append(varint(UInt64(value.count)))
        result.append(value)
        return result
    }

    static func field(_ number: UInt64, string value: String) -> Data {
        field(number, bytes: Data(value.utf8))
    }

    static func jsonData(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    static func teleprompterFrame(sequence: UInt16, type: UInt64, action: UInt64, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: action)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: try jsonData(body)))
        protobuf.append(field(4, bytes: Data()))
        return try frame(protocolID: 0x14, sequence: sequence, protobuf: protobuf)
    }

    static func notificationFrame(sequence: UInt16, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: 2))
        protobuf.append(field(3, bytes: try jsonData(body)))
        protobuf.append(field(4, bytes: Data()))
        return try frame(protocolID: 0x15, sequence: sequence, protobuf: protobuf)
    }

    static func displayFrame(protocolID: UInt8, sequence: UInt16, type: UInt64, body: [String: Any]) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: try jsonData(body)))
        return try frame(protocolID: protocolID, sequence: sequence, protobuf: protobuf)
    }

    static func fileTransferFrame(protobuf: Data) throws -> Data {
        try frame(protocolID: 0x11, sequence: 0, protobuf: protobuf)
    }

    static func pairingFrame(sequence: UInt16, command: UInt8, fields: [(UInt8, Data)]) throws -> Data {
        var tlvs = Data()
        for (tag, value) in fields {
            tlvs.append(tag)
            tlvs.appendBE(UInt16(value.count))
            tlvs.append(value)
        }
        var payload = Data([command])
        payload.appendBE(UInt16(tlvs.count))
        payload.append(tlvs)
        return try frame(protocolID: 0x10, sequence: sequence, protobuf: payload)
    }

    static func acknowledgementFrame(protocolID: UInt8, sequence: UInt16) -> Data {
        var body = Data()
        body.appendBE(sequence)
        body.append(0)
        body.append(protocolID)

        var result = Data([0x55, 0xaa])
        result.appendBE(UInt16(body.count))
        result.append(body)
        result.appendBE(crc16XModem(body))
        return result
    }

    static func pairingCommand(_ payload: Data) -> (UInt8, Data, [UInt8: Data])? {
        guard payload.count >= 3 else { return nil }
        let base = payload.startIndex
        let command = payload[base]
        let length = Int(payload[base + 1]) << 8 | Int(payload[base + 2])
        guard length == payload.count - 3 else { return nil }
        let body = payload.subdata(in: (base + 3)..<(base + payload.count))
        // Device info and authentication use TLVs; status commands carry raw bytes.
        guard [17, 24, 25].contains(command) else { return (command, body, [:]) }
        var tlvs: [UInt8: Data] = [:]
        var offset = 0
        while offset < body.count {
            guard offset + 3 <= body.count else { return nil }
            let tag = body[body.startIndex + offset]
            let size = Int(body[body.startIndex + offset + 1]) << 8 | Int(body[body.startIndex + offset + 2])
            offset += 3
            guard offset + size <= body.count else { return nil }
            tlvs[tag] = body.subdata(in: (body.startIndex + offset)..<(body.startIndex + offset + size))
            offset += size
        }
        return (command, body, tlvs)
    }

    static func frame(protocolID: UInt8, sequence: UInt16, protobuf: Data, acknowledgement: Bool = false) throws -> Data {
        guard protobuf.count <= Int(UInt16.max) - 4 else {
            throw BridgeError(status: 413, message: "Protocol payload exceeds 65531 bytes")
        }
        var body = Data()
        body.appendBE(sequence)
        body.append(0)
        body.append(protocolID)
        body.append(protobuf)

        var result = acknowledgement ? Data([0x55, 0xaa]) : Data([0xaa, 0x55])
        result.appendBE(UInt16(body.count))
        result.append(body)
        result.appendBE(crc16XModem(body))
        return result
    }

    static func crc16XModem(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) == 0 ? crc << 1 : (crc << 1) ^ 0x1021
            }
        }
        return crc
    }

    static func fnv1a32(_ data: Data) -> String {
        var value: UInt32 = 0x811c9dc5
        for byte in data {
            value = (value ^ UInt32(byte)) &* 0x01000193
        }
        return String(format: "%08x", value)
    }

    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func decodeVarint(_ data: Data, at offset: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        let base = data.startIndex
        while offset < data.count && shift < 64 {
            let byte = data[base + offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func fields(_ data: Data) -> [(UInt64, UInt8, UInt64?, Data?)] {
        var result: [(UInt64, UInt8, UInt64?, Data?)] = []
        var offset = 0
        let base = data.startIndex
        while offset < data.count {
            guard let tag = decodeVarint(data, at: &offset) else { break }
            let number = tag >> 3
            let wire = UInt8(tag & 7)
            if wire == 0 {
                guard let value = decodeVarint(data, at: &offset) else { break }
                result.append((number, wire, value, nil))
            } else if wire == 2 {
                guard let length = decodeVarint(data, at: &offset), length <= UInt64(data.count - offset) else { break }
                let end = offset + Int(length)
                result.append((number, wire, nil, data.subdata(in: (base + offset)..<(base + end))))
                offset = end
            } else if wire == 1 {
                guard offset + 8 <= data.count else { break }
                offset += 8
            } else if wire == 5 {
                guard offset + 4 <= data.count else { break }
                offset += 4
            } else {
                break
            }
        }
        return result
    }

    static func protocolHeaderOffset(forFlags flags: UInt8) -> Int {
        3 + ((flags & 0x02) != 0 ? 1 : 0) + Int((flags >> 5) & 0x07)
    }

    static func decodeFrame(_ rawFrame: Data) -> ProtocolFrame? {
        guard rawFrame.count >= 10 else { return nil }
        let base = rawFrame.startIndex
        let b0 = rawFrame[base]
        let b1 = rawFrame[base + 1]
        let isData = (b0 == 0xaa && b1 == 0x55)
        let isAck = (b0 == 0x55 && b1 == 0xaa)
        guard isData || isAck else { return nil }
        let length = (Int(rawFrame[base + 2]) << 8) | Int(rawFrame[base + 3])
        guard length >= 4, rawFrame.count == 4 + length + 2 else { return nil }
        let body = rawFrame.subdata(in: (base + 4)..<(base + 4 + length))
        let storedChecksum = (UInt16(rawFrame[base + 4 + length]) << 8) | UInt16(rawFrame[base + 5 + length])
        guard crc16XModem(body) == storedChecksum else { return nil }
        let sequence = (UInt16(body[body.startIndex]) << 8) | UInt16(body[body.startIndex + 1])
        let flags = body[body.startIndex + 2]
        let offset = protocolHeaderOffset(forFlags: flags)
        guard offset < body.count else { return nil }
        let protocolID = body[body.startIndex + offset]
        let payload = body.subdata(in: (body.startIndex + offset + 1)..<body.endIndex)
        return ProtocolFrame(
            protocolID: protocolID,
            sequence: sequence,
            flags: flags,
            payload: payload,
            isAcknowledgement: isAck
        )
    }

    static func decodeRemoteMessage(from frame: ProtocolFrame, receivedAt: Date = Date()) -> RemoteMessage? {
        guard !frame.isAcknowledgement else { return nil }
        let protobuf = frame.payload
        let parsed = fields(protobuf)
        let action = parsed.first(where: { $0.0 == 1 && $0.1 == 0 })?.2
        let messageType = parsed.first(where: { $0.0 == 2 && $0.1 == 0 })?.2
        let jsonData = parsed.first(where: { $0.0 == 3 && $0.1 == 2 })?.3
        let json = jsonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let audioData = parsed.first(where: { $0.0 == 4 && $0.1 == 2 })?.3
        return RemoteMessage(
            protocolID: frame.protocolID,
            sequence: frame.sequence,
            flags: frame.flags,
            receivedAt: receivedAt,
            protobuf: protobuf,
            action: action,
            messageType: messageType,
            json: json,
            audioData: audioData
        )
    }

    static func decodeRemoteFrame(_ rawFrame: Data) -> RemoteMessage? {
        guard let frame = decodeFrame(rawFrame) else { return nil }
        return decodeRemoteMessage(from: frame)
    }

    static func firstFieldNumber(_ protobuf: Data) -> UInt64? {
        var offset = 0
        return decodeVarint(protobuf, at: &offset).map { $0 >> 3 }
    }

    static func nestedBytes(_ protobuf: Data, field number: UInt64) -> Data? {
        fields(protobuf).first(where: { $0.0 == number && $0.1 == 2 })?.3
    }

    static func varintValue(_ protobuf: Data, field number: UInt64) -> UInt64? {
        fields(protobuf).first(where: { $0.0 == number && $0.1 == 0 })?.2
    }

    static func stringValue(_ protobuf: Data, field number: UInt64) -> String? {
        nestedBytes(protobuf, field: number).flatMap { String(data: $0, encoding: .utf8) }
    }
}

final class ProtocolStreamDecoder {
    private static let maxFrameBytes = 65_541
    private static let maxBufferBytes = maxFrameBytes * 2
    private var pending = Data()

    func append(_ chunk: Data) -> [ProtocolFrame] {
        if !chunk.isEmpty {
            pending.append(chunk)
        }
        var decoded: [ProtocolFrame] = []
        while pending.count >= 4 {
            guard let startOffset = findMagicOffset() else {
                pending = Data(pending.suffix(1))
                break
            }
            if startOffset > 0 {
                pending = Data(pending.dropFirst(startOffset))
            }
            guard pending.count >= 4 else { break }
            let base = pending.startIndex
            let firstByte = pending[base]
            let length = (Int(pending[base + 2]) << 8) | Int(pending[base + 3])
            if length < 4 || (pending.count >= 7 && length <= ProtocolCodec.protocolHeaderOffset(forFlags: pending[base + 6])) {
                pending = Data(pending.dropFirst(1))
                continue
            }
            let totalLength = 4 + length + 2
            if pending.count < totalLength {
                if pending.count > Self.maxFrameBytes {
                    pending = Data(pending.dropFirst(1))
                    continue
                }
                break
            }
            let bodyStart = base + 4
            let bodyEnd = bodyStart + length
            let body = pending.subdata(in: bodyStart..<bodyEnd)
            let storedCRC = (UInt16(pending[bodyEnd]) << 8) | UInt16(pending[bodyEnd + 1])
            guard ProtocolCodec.crc16XModem(body) == storedCRC else {
                pending = Data(pending.dropFirst(1))
                continue
            }
            let sequence = (UInt16(body[body.startIndex]) << 8) | UInt16(body[body.startIndex + 1])
            let flags = body[body.startIndex + 2]
            let offset = ProtocolCodec.protocolHeaderOffset(forFlags: flags)
            guard offset < body.count else {
                pending = Data(pending.dropFirst(1))
                continue
            }
            let protocolID = body[body.startIndex + offset]
            let payload = body.subdata(in: (body.startIndex + offset + 1)..<body.endIndex)
            decoded.append(ProtocolFrame(
                protocolID: protocolID,
                sequence: sequence,
                flags: flags,
                payload: payload,
                isAcknowledgement: firstByte == 0x55
            ))
            pending = Data(pending.dropFirst(totalLength))
        }
        if pending.count > Self.maxBufferBytes {
            pending = Data(pending.suffix(Self.maxFrameBytes))
        }
        return decoded
    }

    func reset() {
        pending.removeAll(keepingCapacity: false)
    }

    private func findMagicOffset() -> Int? {
        let count = pending.count
        guard count >= 2 else { return nil }
        return pending.withUnsafeBytes { rawBuffer -> Int? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            for i in 0..<(count - 1) {
                let a = bytes[i]
                let b = bytes[i + 1]
                if (a == 0xaa && b == 0x55) || (a == 0x55 && b == 0xaa) {
                    return i
                }
            }
            return nil
        }
    }
}

extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
