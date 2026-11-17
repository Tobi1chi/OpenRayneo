// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// Selects the official signer from the final request host, independently of its path.
enum OfficialAccountRequestSigning {
    private static let domesticAccountHosts: Set<String> = [
        "testaccount.rayneo.cn", "account.rayneo.cn", "testaccount-hw.rayneo.cn"
    ]
    private static let overseasAccountHosts: Set<String> = [
        "account.rayneo.com", "eu-account-xr-t.rayneo.com", "global-account.rayneo.com",
        "us-account.rayneo.com", "sg-account.rayneo.com", "eu-account.rayneo.com"
    ]

    static func usesAccountGateway(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return domesticAccountHosts.contains(host) || overseasAccountHosts.contains(host)
    }

    static func signingRegion(for url: URL, fallback: OfficialFirmwareRegion) -> OfficialFirmwareRegion {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return fallback }
        return host.hasSuffix(".rayneo.cn") ? .domestic : .overseas
    }

    static func headers(method: String, url: URL, body: Data? = nil, region: OfficialFirmwareRegion,
                        now: Date = Date(), nonce: String = UUID().uuidString,
                        deviceCode: String? = nil, requestID: String = UUID().uuidString,
                        appVersion: String = "1.0", environment: String = "android",
                        countryCode: String = "cn") -> [String: String] {
        let region = signingRegion(for: url, fallback: region)
        guard usesAccountGateway(url) else {
            return OfficialXRRequestSigning.headers(method: method, url: url, body: body,
                                                    region: region, now: now, nonce: nonce)
        }

        let identity = clientIdentity(for: region)
        let nonce = compactUUID(nonce)
        let timestamp = String(Int64(now.timeIntervalSince1970))
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let canonicalHeaders = "nonce:\(nonce);timestamp:\(timestamp);"
        let canonical = [method.uppercased(), components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
                         components.percentEncodedQuery ?? "", canonicalHeaders, digest(body ?? Data())]
            .joined(separator: "\n")
        let stringToSign = ["HMAC-SHA256", timestamp, digest(Data(canonical.utf8))].joined(separator: "\n")
        let signature = Data(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8),
            using: SymmetricKey(data: Data(identity.appKey.utf8)))).base64EncodedString()

        let environment = environment.lowercased()
        let device = (deviceCode ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let deviceID = environment + "_" + (device.isEmpty ? compactUUID(UUID().uuidString) : device)
        let version = appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1.0" : appVersion
        return ["nonce": nonce, "timestamp": timestamp, "signVersion": "1.0", "env": environment,
                "version": version, "appId": identity.appId, "region": normalizedCountryCode(countryCode),
                "deviceId": deviceID, "requestId": compactUUID(requestID),
                "X-Authorization": "HMAC-SHA256 Credential=\(identity.appId),SignedHeaders=nonce;timestamp;,Signature=\(signature)"]
    }

    static func normalizedCountryCode(_ value: String) -> String {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch code {
        case "chn": return "cn"
        case "sgp": return "sg"
        case "usa": return "us"
        default: return code
        }
    }

    private static func compactUUID(_ value: String) -> String {
        value.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func digest(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
    }

    private struct ClientIdentity {
        let appId: String
        let appKey: String
    }

    // Official APK account_gateway_sign.dart: 0x171ee08 and 0x171ed5c, production branch.
    private static func clientIdentity(for region: OfficialFirmwareRegion) -> ClientIdentity {
        switch region {
        case .domestic: return ClientIdentity(appId: "51241780538438326", appKey: "8febc6fc73cf6c1b6985eaa116c5d667a975c1b1618589d829de9a01ff8e6eaf")
        case .overseas: return ClientIdentity(appId: "30361770025373815", appKey: "618f2b682ffb23d81d6b3d1454e9c3746e2f21ed6dffa8af4999000ea46be5a9")
        }
    }
}
