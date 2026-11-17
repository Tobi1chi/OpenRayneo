// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Combine
import CryptoKit
import Foundation
import LocalAuthentication
import Security

@MainActor
final class OfficialCloudDeviceRepository: ObservableObject {
    private struct Owner: Codable, Equatable {
        let identityEpoch: UUID?
        let accountID: String?
        let businessBaseURL: String?
        var preferenceKey: String { identityEpoch?.uuidString ?? [accountID ?? "", businessBaseURL ?? ""].joined(separator: "|") }
    }
    private struct Cache: Codable {
        let owner: Owner
        let records: [Record]
    }
    struct Record: Codable, Identifiable, Sendable {
        var localDeviceID: String
        var address: String
        var type: String?
        var name: String
        var sn: String
        var localMfiSerialNumber: String
        private var bondKey: String
        var isLocalPaired: Bool
        var cloudBindConfirmed: Bool

        var id: String { localDeviceID }

        init(localDeviceID: String, address: String, type: String?, name: String, sn: String = "",
             localMfiSerialNumber: String = "", bondKey: String = "", isLocalPaired: Bool,
             cloudBindConfirmed: Bool) {
            self.localDeviceID = localDeviceID; self.address = address; self.type = type; self.name = name
            self.sn = sn; self.localMfiSerialNumber = localMfiSerialNumber; self.bondKey = bondKey
            self.isLocalPaired = isLocalPaired; self.cloudBindConfirmed = cloudBindConfirmed
        }

        static func fromPairedGlasses(id: String, name: String, deviceType: String?) throws -> Record {
            guard let mac = normalizedMAC(id) else {
                throw OfficialCloudDeviceRepositoryFailure(message: "本地配对记录没有有效的 MAC 地址，未加入云同步资料。")
            }
            return Record(localDeviceID: nativeID(normalizedMAC: mac), address: canonicalAddress(normalizedMAC: mac),
                type: supportedType(deviceType), name: name, isLocalPaired: true, cloudBindConfirmed: false)
        }

        var outbound: OfficialCloudDevice {
            // These are the original bind caller's distinct mappings, despite their similar names.
            OfficialCloudDevice(sn: sn, deviceType: type, deviceName: name, mfiSerialNumber: localDeviceID,
                bondKey: bondKey, macAddr: address, glassesDeviceId: localMfiSerialNumber)
        }

        mutating func mergeCloudFields(sn: String?, name: String?, localMfiSerialNumber: String?, bondKey: String?) {
            if let value = Self.nonempty(sn) { self.sn = value }
            if let value = Self.nonempty(name) { self.name = value }
            if let value = Self.nonempty(localMfiSerialNumber) { self.localMfiSerialNumber = value }
            if let value = Self.nonempty(bondKey) { self.bondKey = value }
        }

        static func supportedType(_ value: String?) -> String? {
            guard let value = nonempty(value) else { return nil }
            if let number = Int(value), number == 6 || number == 7 { return String(number) }
            let name = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            switch name {
            case "venus": return "6"
            case "venusintl": return "7"
            default: return nil
            }
        }

        static func normalizedMAC(_ value: String) -> String? {
            let mac = value.lowercased().filter { $0 != ":" && $0 != "-" && !$0.isWhitespace }
            guard mac.count == 12, mac.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
            return mac
        }

        static func nativeID(normalizedMAC: String) -> String {
            // Protocol storage identity: HMAC-SHA256 with an empty key, first 16 bytes as 32 hex characters.
            HMAC<SHA256>.authenticationCode(for: Data(normalizedMAC.utf8), using: SymmetricKey(data: Data()))
                .prefix(16).map { String(format: "%02x", $0) }.joined()
        }

        static func canonicalAddress(normalizedMAC: String) -> String {
            let digits = Array(normalizedMAC.uppercased())
            return stride(from: 0, to: digits.count, by: 2).map { String(digits[$0...($0 + 1)]) }.joined(separator: ":")
        }

        private static func nonempty(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
    }

    @Published private(set) var records: [Record] = []
    @Published private(set) var loadError: String?
    private var owner = Owner(identityEpoch: nil, accountID: nil, businessBaseURL: nil)

    private static let keychainService = "com.openrayneo.bridge.official-devices"
    private static let keychainAccount = "cache"

    init() {
        do { try reload() }
        catch { loadError = error.localizedDescription }
    }

    func recordPairing(_ device: PairedGlasses) throws {
        try ensureLoaded()
        let paired = try Record.fromPairedGlasses(id: device.id, name: device.name, deviceType: device.deviceType)
        var updated = records
        if let index = matchingIndex(paired, in: updated) {
            updated[index].localDeviceID = paired.localDeviceID
            updated[index].address = paired.address
            if let type = paired.type { updated[index].type = type }
            updated[index].name = paired.name
            updated[index].isLocalPaired = true
            updated[index].cloudBindConfirmed = false
        } else { updated.append(paired) }
        try persist(updated)
        try allowAutomaticBinding(mac: paired.address)
    }

    func mergeCloud(_ rows: [OfficialCloudDevice]) throws {
        guard !rows.isEmpty else { return }
        try ensureLoaded()
        var updated = records
        var applied = false
        for row in rows {
            guard let rawMAC = row.macAddr, let mac = Record.normalizedMAC(rawMAC),
                  let type = Record.supportedType(row.deviceType) else { continue }
            var merged = Record(localDeviceID: Record.nativeID(normalizedMAC: mac),
                address: Record.canonicalAddress(normalizedMAC: mac), type: type, name: "",
                isLocalPaired: false, cloudBindConfirmed: true)
            let index = matchingIndex(merged, in: updated)
            if let index {
                let old = updated[index]
                merged = old
                merged.localDeviceID = Record.nativeID(normalizedMAC: mac)
                merged.address = Record.canonicalAddress(normalizedMAC: mac)
                merged.type = type
            }
            row.mergeCloudFields(into: &merged)
            merged.cloudBindConfirmed = true
            if let index { updated[index] = merged }
            else { updated.append(merged) }
            applied = true
        }
        guard applied else { return }
        try persist(updated)
    }

    func pending() -> [Record] {
        let suppressed = suppressedMACs(owner)
        return records.filter { !$0.cloudBindConfirmed && Record.supportedType($0.type) != nil &&
            !suppressed.contains(Record.normalizedMAC($0.address) ?? "") }
    }

    func suppressAutomaticBinding(mac: String, identity: OfficialFirmwareConfiguration? = nil) throws {
        try updateSuppression(mac: mac, suppressed: true, identity: identity)
    }
    func allowAutomaticBinding(mac: String, identity: OfficialFirmwareConfiguration? = nil) throws {
        try updateSuppression(mac: mac, suppressed: false, identity: identity)
    }

    private func suppressedMACs(_ scope: Owner) -> Set<String> {
        let values = UserDefaults.standard.dictionary(forKey: "officialDeviceManualBindingIntents") as? [String: [String]] ?? [:]
        return Set(values[scope.preferenceKey] ?? [])
    }

    private func updateSuppression(mac: String, suppressed: Bool, identity: OfficialFirmwareConfiguration?) throws {
        guard let mac = Record.normalizedMAC(mac) else {
            throw OfficialCloudDeviceRepositoryFailure(message: "设备 MAC 无效，未更新绑定同步状态。")
        }
        let scope: Owner
        if let identity {
            scope = Owner(identityEpoch: identity.identityEpoch, accountID: identity.accountID.isEmpty ? nil : identity.accountID,
                businessBaseURL: identity.baseURL.absoluteString)
        } else { scope = try currentOwner() }
        var values = UserDefaults.standard.dictionary(forKey: "officialDeviceManualBindingIntents") as? [String: [String]] ?? [:]
        var addresses = Set(values[scope.preferenceKey] ?? [])
        if suppressed { addresses.insert(mac) } else { addresses.remove(mac) }
        values[scope.preferenceKey] = addresses.sorted()
        UserDefaults.standard.set(values, forKey: "officialDeviceManualBindingIntents")
        UserDefaults.standard.synchronize()
    }

    func confirm(_ snapshot: Record) throws {
        try ensureLoaded()
        guard let index = matchingIndex(snapshot, in: records), records[index].name == snapshot.name else { return }
        var updated = records
        updated[index].cloudBindConfirmed = true
        try persist(updated)
    }

    @discardableResult
    func recordName(address: String, name: String) throws -> Bool {
        try ensureLoaded()
        guard let mac = Record.normalizedMAC(address),
              let index = records.firstIndex(where: { Record.normalizedMAC($0.address) == mac }),
              records[index].name != name else { return false }
        var updated = records
        updated[index].name = name; updated[index].cloudBindConfirmed = false
        try persist(updated)
        return true
    }

    func clear() throws {
        let current = try currentOwner()
        let status = SecItemDelete(Self.noninteractiveIdentity as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.failure(status) }
        records = []; loadError = nil; owner = current
    }

    func synchronizeIdentity() throws {
        if try currentOwner() != owner { try clear() }
    }

    func remove(mac: String) throws {
        try ensureLoaded()
        guard let normalized = Record.normalizedMAC(mac) else {
            throw OfficialCloudDeviceRepositoryFailure(message: "没有有效的 MAC 地址，未移除设备同步资料。")
        }
        try persist(records.filter { Record.normalizedMAC($0.address) != normalized })
    }

    func reload() throws {
        var query = Self.noninteractiveIdentity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        do {
            let current = try currentOwner()
            if status == errSecItemNotFound { records = []; loadError = nil; owner = current; return }
            guard status == errSecSuccess, let data = result as? Data else { throw Self.failure(status) }
            let loaded = try JSONDecoder().decode(Cache.self, from: data)
            guard loaded.owner == current else { try clear(); return }
            records = loaded.records; owner = current; loadError = nil
        } catch { loadError = error.localizedDescription; throw error }
    }

    private func ensureLoaded() throws {
        if loadError != nil { try reload() }
        try synchronizeIdentity()
    }

    private func matchingIndex(_ record: Record, in values: [Record]) -> Int? {
        values.firstIndex(where: { $0.localDeviceID == record.localDeviceID }) ??
            values.firstIndex(where: { Record.normalizedMAC($0.address) == Record.normalizedMAC(record.address) })
    }

    private func persist(_ updated: [Record]) throws {
        let data = try JSONEncoder().encode(Cache(owner: owner, records: updated))
        var status = SecItemUpdate(Self.noninteractiveIdentity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = Self.identity
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "OpenRayneo 官方设备同步资料"
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Self.failure(status) }
        records = updated; loadError = nil
    }

    private func currentOwner() throws -> Owner {
        let session = try OfficialAccountSessionStore.selectedSession()
        return Owner(identityEpoch: session?.identityEpoch, accountID: session?.accountID, businessBaseURL: session?.businessBaseURL)
    }

    private static var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
         kSecAttrAccount as String: keychainAccount, kSecAttrSynchronizable as String: false]
    }

    private static var noninteractiveIdentity: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        var query = identity
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    private static func failure(_ status: OSStatus) -> OfficialCloudDeviceRepositoryFailure {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "状态 \(status)"
        return OfficialCloudDeviceRepositoryFailure(message: "本机官方设备资料钥匙串操作失败：\(detail)")
    }
}

struct OfficialCloudDeviceRepositoryFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
