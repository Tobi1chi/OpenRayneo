# 安全策略 / Security Policy

[简体中文](#简体中文) · [English](#english)

---

<a id="简体中文"></a>

## 简体中文

### 安全设计与边界

OpenRayneo 涉及蓝牙设备控制、麦克风录音、本机 HTTP/Agent API 及加密配置，遵循以下安全基线：

1. **本机接口默认仅限回环**：
   - macOS Bridge（`127.0.0.1:8765`）默认仅监听回环地址，除 `/health` 外均要求常量时间校验 Bearer Token，并校验 `Host` 头防御 DNS Rebinding。
   - Android 本机 Agent 服务（`127.0.0.1:8766`）默认仅监听回环地址，所有路由均要求 Bearer Token 鉴权并拒绝带 `Origin` 头的浏览器跨站请求（无未鉴权健康检查路由）。
2. **用户数据留在本地**：录音文件、声纹参考、Android Keystore 密钥与 macOS Keychain 凭据均保存在用户本机，除非用户显式配置外部模型接口或局域网同步，否则不会上传。
3. **禁止泄露凭据**：切勿在 Issue、PR 或日志截图中暴露真实 Bearer Token、模型 API Key、签名密钥库（`.jks` / `.lineage`）或个人敏感录音。

### 漏洞披露方式

**请勿直接在公开 GitHub Issue 中披露未修复的安全漏洞。**

请优先通过以下方式私下反馈：

1. **GitHub 私有漏洞报告（推荐）**：在仓库 **Security** 标签页点击 **Report a vulnerability** 提交。
2. 如暂无法使用私有报告通道，可先提一条不含漏洞细节的简短 Issue 联系维护者获取私密联系方式。

提交时请尽量附带：受影响的组件与版本、复现步骤、潜在影响及修复建议。维护者通常会在 **72 小时内**响应并协同修复与公开披露。

---

<a id="english"></a>

## English

### Security Design & Boundaries

OpenRayneo handles sensitive local capabilities—Bluetooth device control, microphone audio, local HTTP/Agent APIs, and encrypted settings. Our baseline security guarantees are:

1. **Loopback-only local APIs by default**:
   - The macOS bridge (`127.0.0.1:8765`) binds to loopback only, requires constant-time Bearer token authentication on all non-`/health` routes, and validates `Host` headers to mitigate DNS rebinding.
   - The Android local Agent server (`127.0.0.1:8766`) binds to loopback only, requires Bearer token authentication on all routes (no unauthenticated health route), and rejects requests carrying an `Origin` header.
2. **Local-only sensitive data**: User recordings, voiceprint references, Android Keystore keys, and macOS Keychain credentials stay on the user's device and are never uploaded by OpenRayneo unless the user explicitly configures an external endpoint or LAN record sync.
3. **No secrets in source control**: Release signing keystores (`.jks`), v3 rotation lineages, Keychain passwords, and API tokens must never be committed or posted in issues/PRs.

### Reporting a Vulnerability

**Please do not report security vulnerabilities through public GitHub issues.**

Instead, please report them privately using one of the following methods:

1. **GitHub Private Vulnerability Reporting** (Preferred): Open the **Security** tab of `Tobi1chi/OpenRayneo` and select **Report a vulnerability**.
2. **If Private Reporting is unavailable**: Open a brief issue without sensitive details asking the maintainer for a private contact channel.

Please include:
- Affected component (macOS Bridge, CoreAudio driver, Android app, Local HTTP API, or Record Sync) and version.
- Steps to reproduce or proof-of-concept.
- Potential impact and any suggested remediation.

We aim to acknowledge security reports within **72 hours** and coordinate disclosure once a fix is ready.
