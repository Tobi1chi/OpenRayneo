// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

struct BridgeError: Error {
    let status: Int
    let message: String
}

struct RemoteMessage {
    let protocolID: UInt8
    let sequence: UInt16
    let receivedAt: Date
    let protobuf: Data
    let version: UInt64?
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

    static func teleprompterFrame(sequence: UInt16, type: UInt64, action _: UInt64, body: [String: Any]) throws -> Data {
        // TransportMessage field 1 is the envelope version. Direction is JSON action.
        var protobuf = field(1, varint: 1)
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

    static func rawBusinessFrame(protocolID: UInt8, sequence: UInt16, payload: Data) throws -> Data {
        try frame(protocolID: protocolID, sequence: sequence, protobuf: payload)
    }

    static func acknowledgement(protocolID: UInt8, sequence: UInt16) throws -> Data {
        try frame(protocolID: protocolID, sequence: sequence, protobuf: Data(), magic: 0x55aa)
    }

    static func transportFrame(protocolID: UInt8, sequence: UInt16, type: UInt64, message: Data = Data(), data: Data = Data()) throws -> Data {
        var protobuf = field(1, varint: 1)
        protobuf.append(field(2, varint: type))
        protobuf.append(field(3, bytes: message))
        protobuf.append(field(4, bytes: data))
        return try frame(protocolID: protocolID, sequence: sequence, protobuf: protobuf)
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

    static func appVisibilityFrame(sequence: UInt16, foreground: Bool) throws -> Data {
        // GlassesAppVisibilityNotifier 0x271153c: raw command 31, body length 1.
        try frame(protocolID: 0x10, sequence: sequence, protobuf: Data([0x1f, 0, 1, foreground ? 2 : 1]))
    }

    static func pairingCommand(_ payload: Data) -> (UInt8, Data, [UInt8: Data])? {
        guard payload.count >= 3 else { return nil }
        let command = payload[0]
        let length = Int(payload[1]) << 8 | Int(payload[2])
        guard length == payload.count - 3 else { return nil }
        let body = payload.subdata(in: 3..<payload.count)
        // Device info and authentication use TLVs; status commands carry raw bytes.
        guard [17, 24, 25].contains(command) else { return (command, body, [:]) }
        var tlvs: [UInt8: Data] = [:]
        var offset = 0
        while offset < body.count {
            guard offset + 3 <= body.count else { return nil }
            let tag = body[offset]
            let size = Int(body[offset + 1]) << 8 | Int(body[offset + 2])
            offset += 3
            guard offset + size <= body.count else { return nil }
            tlvs[tag] = body.subdata(in: offset..<(offset + size))
            offset += size
        }
        return (command, body, tlvs)
    }

    private static func frame(protocolID: UInt8, sequence: UInt16, protobuf: Data, magic: UInt16 = 0xaa55) throws -> Data {
        guard protobuf.count <= Int(UInt16.max) - 4 else {
            throw BridgeError(status: 413, message: "Protocol payload exceeds 65531 bytes")
        }
        var body = Data()
        body.appendBE(sequence)
        body.append(0)
        body.append(protocolID)
        body.append(protobuf)

        var result = Data()
        result.appendBE(magic)
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

    static func decodeVarint(_ data: Data, at start: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while start < data.count && shift < 64 {
            let byte = data[start]
            start += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    static func fields(_ data: Data) -> [(UInt64, UInt8, UInt64?, Data?)] {
        var result: [(UInt64, UInt8, UInt64?, Data?)] = []
        var offset = 0
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
                result.append((number, wire, nil, data.subdata(in: offset..<end)))
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

    static func decodeRemoteFrame(_ frame: Data) -> RemoteMessage? {
        guard frame.count >= 10, frame[0] == 0xaa, frame[1] == 0x55 else { return nil }
        let length = Int(frame[2]) << 8 | Int(frame[3])
        guard frame.count == 4 + length + 2 else { return nil }
        let body = frame.subdata(in: 4..<(4 + length))
        let storedChecksum = (UInt16(frame[4 + length]) << 8) | UInt16(frame[5 + length])
        guard crc16XModem(body) == storedChecksum, body.count >= 4 else { return nil }
        let headerLength = 4 + (body[2] & 2 == 0 ? 0 : 1) + Int(body[2] >> 5)
        guard body.count >= headerLength else { return nil }
        let protocolID = body[headerLength - 1]
        let protobuf = body.subdata(in: headerLength..<body.count)
        if [0x06, 0x19].contains(protocolID), let json = try? JSONSerialization.jsonObject(with: protobuf) as? [String: Any] {
            return RemoteMessage(protocolID: protocolID, sequence: UInt16(body[0]) << 8 | UInt16(body[1]), receivedAt: Date(),
                protobuf: protobuf, version: nil, messageType: protocolID == 6 ? (json["type"] as? NSNumber)?.uint64Value : 1, json: json, audioData: nil)
        }
        let parsed = fields(protobuf)
        let version = parsed.first(where: { $0.0 == 1 && $0.1 == 0 })?.2
        let messageType = parsed.first(where: { $0.0 == 2 && $0.1 == 0 })?.2
        let jsonData = parsed.first(where: { $0.0 == 3 && $0.1 == 2 })?.3
        let json = jsonData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let audioData = parsed.first(where: { $0.0 == 4 && $0.1 == 2 })?.3
        return RemoteMessage(protocolID: protocolID, sequence: UInt16(body[0]) << 8 | UInt16(body[1]), receivedAt: Date(), protobuf: protobuf, version: version, messageType: messageType, json: json, audioData: audioData)
    }

    static func containsCompleteValidFrame(in buffer: Data, startingAfter firstOffset: Int = 1) -> Bool {
        let count = buffer.count
        guard count >= firstOffset + 10 else { return false }
        let base = buffer.startIndex
        var offset = firstOffset
        while offset + 10 <= count {
            let b0 = buffer[base + offset]
            let b1 = buffer[base + offset + 1]
            let isData = (b0 == 0xaa && b1 == 0x55)
            let isAck = (b0 == 0x55 && b1 == 0xaa)
            if isData || isAck {
                let length = Int(buffer[base + offset + 2]) << 8 | Int(buffer[base + offset + 3])
                let frameLength = 4 + length + 2
                if length >= 4 && offset + frameLength <= count {
                    if isAck {
                        if length == 4 {
                            let body = buffer.subdata(in: (base + offset + 4)..<(base + offset + 8))
                            let stored = (UInt16(buffer[base + offset + 8]) << 8) | UInt16(buffer[base + offset + 9])
                            if crc16XModem(body) == stored { return true }
                        }
                    } else {
                        let candidate = buffer.subdata(in: (base + offset)..<(base + offset + frameLength))
                        if decodeRemoteFrame(candidate) != nil { return true }
                    }
                }
            }
            offset += 1
        }
        return false
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

private extension Data {
    mutating func appendBE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

}

