# 贡献指南 / Contributing to OpenRayneo

[简体中文](#简体中文) · [English](#english)

---

<a id="简体中文"></a>

## 简体中文

非常欢迎为 **OpenRayneo** 贡献代码、多语言翻译、协议分析或真机测试反馈！

### 1. 项目边界与核心约定

提交改动前，请先了解以下仓库原则（完整开发约定见 [`AGENTS.md`](AGENTS.md)）：

- **严禁提交私有或专有文件**：不要提交官方 RayNeo APK、固件镜像、个人录音、签名证书（`.jks` / `.lineage`）、API Token 或个人内网证书。
- **架构事实以 `.arch/` 为准**：涉及大模块改动前，建议先看 [`.arch/ground_truth.md`](.arch/ground_truth.md) 与 [`.arch/dashboard.html`](.arch/dashboard.html)。不要手改 `.arch/graph.json`，需更新节点时通过 `arch-grower` CLI 操作。
- **界面配色由 Design Tokens 生成**：修改颜色请编辑 `assets/design-tokens/`，再运行 `uv run python scripts/generate-design-tokens.py` 重新生成 `DesignTokens.swift` 与 `DesignTokens.kt`，不要手改生成文件。
- **保持文档精简**：安装与排错步骤归入 [`docs/runbook.md`](docs/runbook.md)，协议细节归入 [`docs/protocol.md`](docs/protocol.md)，不新增逐轮实施报告或重复架构图。
- **避免单体大文件**：按职责拆分为内聚的模块文件（单文件建议控制在 ~600 行以内），不继续向 `main.swift` 等入口文件堆叠业务模块。
- **保护 Android 覆盖升级兼容**：请勿破坏 `signRelease` 的 APK v3 密钥轮换签名流程；在未通过 SherpaOnnx JNI 与 Filament 3D 真机验证前，请勿盲目开启 R8 混淆。

### 2. 本地构建与验证

提交 PR 前，请按改动范围运行对应检查：

- **CoreAudio 驱动（`Drivers/OpenRayneoAudio/`）**：
  ```sh
  clang -std=c11 -O2 -Wall -Wextra -Werror -pthread Tests/AudioDriverTests/test_audio_ring.c -o /tmp/test_audio_ring && /tmp/test_audio_ring
  sh scripts/build-audio-driver.sh
  ```
- **macOS（`Sources/`）**：
  ```sh
  sh scripts/prepare-mac-voice.sh
  swift build
  ```
- **Android（`android/`）**：
  ```sh
  cd android
  ./gradlew :app:testDebugUnitTest
  ./gradlew :app:assembleDebug
  ```
- **脚本检查（`scripts/`）**：
  ```sh
  sh -n scripts/build-audio-driver.sh scripts/package-audio-driver.sh
  ```

### 3. PR 与 Commit 规范

- **聚焦拆分**：跨端或跨模块的大改动请按职责拆成清晰的 Commit（如驱动 / macOS / Android / 多语言），方便 Review 与合入。
- **如实说明验证边界**：如果蓝牙传输、CoreAudio 音频路由、真机显示等改动尚未在实体 RayNeo iO 上复测，请在 PR 描述中明确标出。
- **Commit 风格**：推荐使用 Conventional Commits 前缀（如 `feat(android):`、`fix(mac):`、`feat(audio):`、`feat(i18n):`、`docs:`）。
- **社区共同作者署名**：吸收或基于他人方案改进时，请附上带数字 ID 的标准 `Co-authored-by: Name <ID+username@users.noreply.github.com>` 尾注，确保 Contributors 准确展示。
- **多语言同步**：新增用户可见文案时，请同时提供中英文（使用 `L(zh, en)` 辅助并保持 `values/strings.xml` 与 `values-zh/strings.xml` 同步）。

### 4. 提交 Bug 反馈

请优先使用仓库内置的 **Bug Report** 表单，补充系统版本、OpenRayneo 版本、眼镜型号/固件版本、是否同时连接官方 App 以及复现日志，这能大幅加快定位速度。

---

<a id="english"></a>

## English

Thank you for your interest in contributing to **OpenRayneo**! Whether you are fixing a Bluetooth edge case, expanding localization, improving CoreAudio/Android stability, or testing on new hardware/firmware, your help makes the project stronger.

### 1. Project Boundaries & Golden Rules

Before writing code, please keep these repository-wide rules in mind (see also [`AGENTS.md`](AGENTS.md)):

- **No proprietary or private artifacts**: Never commit official RayNeo APKs, firmware binaries, personal voice recordings, Keystore/JKS files, rotation lineages, API tokens, or certificates.
- **Architecture lives in `.arch/`**: Check [`.arch/ground_truth.md`](.arch/ground_truth.md) and [`.arch/dashboard.html`](.arch/dashboard.html) before proposing major structural changes. Do not hand-edit `.arch/graph.json`; use the `arch-grower` CLI if updating architecture nodes.
- **Design tokens are generated**: Edit color semantics only under `assets/design-tokens/`, then regenerate Swift & Kotlin files with `uv run python scripts/generate-design-tokens.py`.
- **Keep documentation lean**: Operational instructions belong in [`docs/runbook.md`](docs/runbook.md) and protocol details in [`docs/protocol.md`](docs/protocol.md). Avoid adding per-PR narrative reports or duplicate diagrams.
- **Avoid monolithic files**: Keep source files focused and cohesive (aim for <= ~600 lines per file); add new modules in dedicated files rather than growing `main.swift` or large controllers.
- **Preserve Android upgrade compatibility**: Do not alter the release signing pipeline (`signRelease` v3 rotation lineage) or enable R8/ProGuard minification without verifying SherpaOnnx JNI and Filament 3D classes on a physical device.

### 2. Development & Verification

Please run the checks relevant to the areas you touched before opening a Pull Request:

- **CoreAudio HAL driver (`Drivers/OpenRayneoAudio/`)**:
  ```sh
  clang -std=c11 -O2 -Wall -Wextra -Werror -pthread Tests/AudioDriverTests/test_audio_ring.c -o /tmp/test_audio_ring && /tmp/test_audio_ring
  sh scripts/build-audio-driver.sh
  ```
- **macOS (`Sources/`)**:
  ```sh
  sh scripts/prepare-mac-voice.sh
  swift build
  ```
- **Android (`android/`)**:
  ```sh
  cd android
  ./gradlew :app:testDebugUnitTest
  ./gradlew :app:assembleDebug
  ```
- **Shell / Python scripts (`scripts/`)**:
  ```sh
  sh -n scripts/build-audio-driver.sh scripts/package-audio-driver.sh
  ```

### 3. Pull Request Guidelines

- **Keep PRs focused**: Split unrelated changes (e.g., CoreAudio driver vs. Android UI vs. i18n) into separate commits or PRs so they are easy to review and cherry-pick.
- **Be explicit about hardware testing**: If a change touches Bluetooth transport, CoreAudio routing, or glasses display rendering and could only be tested in CI/emulator/Linux, clearly state that in the PR description.
- **Commit style**: Use concise Conventional Commit prefixes (`feat(android): ...`, `fix(mac): ...`, `feat(audio): ...`, `docs: ...`).
- **Co-author attribution**: When porting or building upon community work, include verified `Co-authored-by: Name <ID+username@users.noreply.github.com>` trailers so GitHub credits all contributors accurately.
- **Localization**: For user-facing text, use the bilingual `L(zh, en)` helper on macOS/Android and keep `android/app/src/main/res/values/strings.xml` and `values-zh/strings.xml` aligned.

### 4. Reporting Bugs

When filing a bug report, please use the **Bug Report** issue template and include your OS version, OpenRayneo version, glasses model/firmware version, whether the official RayNeo app is connected, and relevant diagnostic logs.
