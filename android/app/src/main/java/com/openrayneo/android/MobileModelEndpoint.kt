// Copyright 2026 Tobi1chi
// SPDX-License-Identifier: Apache-2.0
package com.openrayneo.android

import java.net.URI
import java.net.URISyntaxException

/** Matches the app's existing cleartext policy: only phone loopback can use HTTP. */
internal object MobileModelEndpoint {
    private val loopbackHosts = setOf("127.0.0.1", "localhost")

    fun isLocalAddress(address: String): Boolean {
        val uri = try { URI(address.trim()) } catch (_: URISyntaxException) { return false }
        return uri.scheme?.lowercase() in setOf("http", "https") &&
            uri.host?.lowercase() in loopbackHosts && uri.userInfo == null && uri.query == null && uri.fragment == null
    }

    fun isConfigured(address: String, model: String, apiKey: String): Boolean =
        address.isNotBlank() && model.isNotBlank() && (apiKey.isNotBlank() || isLocalAddress(address))

    fun resolve(address: String, apiKey: String): String {
        val base = address.trim().trimEnd('/')
        val uri = URI(base)
        require(uri.host != null && uri.userInfo == null && uri.query == null && uri.fragment == null) {
            "模型地址应为完整服务地址，且不包含密钥或查询参数"
        }
        require(uri.scheme?.lowercase() == "https" || uri.scheme?.lowercase() == "http" && isLocalAddress(base)) {
            "远端模型使用 HTTPS；手机本机服务可使用 http://127.0.0.1 或 http://localhost"
        }
        require(apiKey.isNotBlank() || isLocalAddress(base)) { "请填写远端模型服务的 API Key" }
        return if (base.endsWith("/chat/completions")) base else "$base/chat/completions"
    }
}
