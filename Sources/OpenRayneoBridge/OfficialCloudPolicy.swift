// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Beta uses local device protocols and user-selected providers, without vendor cloud resources.
enum OfficialCloudPolicy {
    static let enabled = false
    static let explanation = "此版本不使用雷鸟官方云服务。请使用本地功能或配置自己的模型 API。"

    static func requireEnabled() throws {
        guard enabled else { throw OfficialAccountFailure(message: explanation) }
    }

    static func isVendorHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["rayneo.cn", "rayneo.com", "ffalcon.com", "tcl.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
