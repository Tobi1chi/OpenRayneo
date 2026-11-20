# 运行指南

目标、模块和当前完成度统一见 [架构事实](../.arch/ground_truth.md) 与 [看板](../.arch/dashboard.html)。本页只维护可直接操作的安装、运行与恢复步骤。

## 当前版本

- 下载：[GitHub Release v1.2.0-beta.5](https://github.com/Tobi1chi/OpenRayneo/releases/tag/v1.2.0-beta.5)，含 Mac arm64 zip（1.2.0／21）、Android arm64 release APK（38）和 DSH 插件 `openrayneo-dsh-0.1.8.tgz`（也可在 `integrations/dsh-go` 用 `npm pack` 生成）。
- Android release 自 1.2.0-beta.5 之后改用 OpenRayneo 正式密钥，并以 APK v3 签名轮换（lineage）从原开发签名过渡：已装旧包的手机可直接覆盖升级、保留配置与记录；升级后旧开发签名的包（含 debug 构建）不能再覆盖，需先卸载。回退用更早的 GitHub Release（同样需卸载）。
- 本地开发构建按下方命令生成；仓库不提交安装包、模型下载物或私钥，阶段结束后清理 `.build/` 下的构建与候选包。

## 构建

Mac已使用Apple Silicon / macOS 15验证，需要Xcode Command Line Tools与Opus。模型和动态库由现有准备／打包脚本处理。

```sh
sh scripts/prepare-mac-voice.sh
swift build
OPENRAYNEO_APP_DIR="$PWD/.build/dev-candidate/OpenRayneoBridge.app" sh scripts/build-app.sh
open .build/dev-candidate/OpenRayneoBridge.app
```

界面颜色只在 `assets/design-tokens/` 修改（VS Code式语义token：`registry.json` 登记含义，明暗主题JSON给色值），随后运行 `uv run python scripts/generate-design-tokens.py` 重新生成 `DesignTokens.swift` 与 `DesignTokens.kt`；生成文件不手改。

实时3D眼镜使用 `assets/models/` 的同一模型：`scripts/build-app.sh` 把 `rayneo-io.usdz` 放入Mac App资源，Android构建把 `rayneo-io.glb` 同步进APK assets；替换模型时保留部件命名（左右镜腿、铰链、镜片、状态灯）。

打包使用现有脚本的签名、内嵌库与RPATH流程。读取已有声纹时使用正常签名的App；独立未授权helper可能触发钥匙串提示。分发包通过 `sh scripts/package-release.sh` 生成，发布与上传按相应任务授权执行。

Android需要JDK17、SDK Platform36 / Build-Tools36.0.0；使用 `ANDROID_HOME` 或不提交的 `android/local.properties` 指向本机SDK。

```sh
cd android
./gradlew :app:assembleDebug :app:assembleRelease :app:lintDebug -Popenrayneo.abis=arm64-v8a,x86_64 --console=plain
adb install -r app/build/outputs/apk/release/app-release.apk
adb shell am start -n com.openrayneo.android/.MainActivity
```

macOS的Homebrew JDK17可通过 `JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home` 选择。默认Gradle输出在下一次构建生成；固定交付件放 `outputs/candidates/<版本>/`。`assembleRelease` 产出未签名包后由 `signRelease` 调 `apksigner` 做 v3-only 签名（minSdk 33）：密钥 `~/.openrayneo-signing/openrayneo-release.jks`（别名 `openrayneo`）、轮换链 `~/.openrayneo-signing/rotation.lineage`，口令存 macOS 钥匙串服务 `openrayneo-android-release`。密钥与 lineage 务必离线备份，丢失后无法再发布可覆盖升级的包；`~/.android/debug.keystore` 仍需保留以便日后再次轮换。不在文档或源码写入密码。系统阻止ADB安装时，把APK推送到手机Download后由用户手动安装。

## 连接与恢复

1. 普通切换先在占用端断开眼镜，保留已有配对；Mac、手机和官方App同时争用会阻塞数据通道。
2. Mac在“设备连接”选择已有配对，连接并启用API；Android授予附近设备权限后选择目标。首次配对用应用配对流程并由用户确认系统提示。
3. 分别检查BLE认证、RFCOMM数据通道及页面／音频业务状态；Mac `/health` 的 `ok` 是服务状态，设备操作还需 `bleReady` 与 `rfcommConnected`。
4. `channel did not finish opening` 时保留诊断，清理本次失败连接；确认手机／其他App释放连接、眼镜已展开佩戴并亮屏，再连接一次。不要连续点击连接、常规恢复不要删配对或清应用数据。
5. API地址和token从当前“Agent工作台／设备连接”复制。GUI优先8765，端口占用可选备用端口，连接服务重启会换token；使用界面当前值。
6. 眼镜没有唤醒响应时先区分设备无响应与Mac没收到：读取native事件及连接状态，再核助手／语音唤醒／唤醒词实际回报。助手页面尚未退出时先回到表盘。GUI默认勾选或已发送指令不能代替设备读回。

Mac GUI退出会停止自己持有的后台服务；“重启连接服务”仅重启该worker，不重置眼镜或系统蓝牙。蓝牙bond损坏时才重新配对；细节见 [协议](protocol.md)。

## Agent与记录同步

语音响应、等待／提示、工具和工作流由本机外部Agent负责；OpenRayneo负责音频、基础转写、记录与官方通路回写。Mac工作台也可“仅启动记录与Agent服务”，不连接眼镜：

```sh
.build/debug/openrayneo-bridge --headless --local-services-only
```

| 入口 | 默认监听 | 凭据 |
| --- | --- | --- |
| Mac设备／Agent API | loopback `8765`，GUI可选备用端口 | 当前Mac token |
| Android本机Agent API | loopback `8766`，设置中启用 | 手机本机token |
| 手机与Mac记录同步 | 手机LAN `8767`，独立启用 | 专用sync token |

接口与会话参数见 [API技能](../.agents/skills/openrayneo-api/SKILL.md)。请求脚本使用 `OPENRAYNEO_API_URL` / `OPENRAYNEO_API_TOKEN` 的本机安全配置，勿打印凭据；`GET /health`无需token，其他路由使用Bearer。

手机在“设置 → DSH Go与外部Agent”启用本机入口；DSH选择“本机 / This phone”，先验证普通聊天。插件安装／工具见 [插件说明](../integrations/dsh-go/README.md)。tgz顶层为 `package/`，在手机DSH终端解压：

```sh
mkdir -p "$HOME/.dsh/dsh-go/plugins/openrayneo-dsh"
tar -xzf /sdcard/Download/openrayneo-dsh-0.1.8.tgz --strip-components=1 -C "$HOME/.dsh/dsh-go/plugins/openrayneo-dsh"
dsh plugin --profile web add "$HOME/.dsh/dsh-go/plugins/openrayneo-dsh"
```

首次安装执行add；更新使用原目录替换，再在DSH“引擎”页重启内核。连接动作存入`OPENRAYNEO_TOKEN`凭据服务。live原生唤醒跨wake复用对话，手机助手“新建对话”显式重开；录音／任务／wake身份各自独立。

相遇同步将手机专用地址和sync token填入Mac工作台，默认15秒补齐文字／人物／总结／派生，音频按需获取。Mac持久副本位于 `~/Library/Application Support/OpenRayneo/MemoryLibrary/PhoneReplica/`；离线派生回写与游标规则见 [同步契约](record-sync-contract.md)。

## 声音与录音

- 原生自动接听需要显式开启。双路默认ch1本人、ch2完整说话人；native／全天混合mono全量处理。手工登记默认选实时ch1，Mac与手机声纹库独立。“小雷小雷”唤醒轮默认在本机自动更新本人声纹（无档案时累计一致人声≥10秒、3段自动建档；已有档案只收≥0.50的片段，自动样本最多10个、不替换手动样本），Mac在“声音与说话人 → 本机声音档案”、手机在“语音与记忆配置”开关，人物卡可“清除自动样本”。
- Mac每次原生capture自动流式保存最近完整WAV，位置为 `~/Library/Application Support/OpenRayneo/NativeDiagnostics/`。`GET /v1/assistant/native/diagnostic`查询当前状态和`latest`，核对captureID、complete、frames和路径后使用；无需arm或等待窗口，保存不受ASR游标清理影响。
- 下次完整会话成功后，旧WAV移入Trash；异常轮不冒充完整，当前失败与上一有效latest分别给出。原生capture沿用既有时长设置，保存没有额外60秒截断。
- 实时双麦（AI助手“实时提示双麦”与“声音与说话人”眼镜收音）默认不落盘；在“录音开发者工具”打开“自动保存最近一轮实时双麦 WAV”后，下一次开始收音起保存到 `~/Library/Application Support/OpenRayneo/RealtimeDiagnostics/`，规则同上（丢包、解码错误或中断的一轮不覆盖上一份）。眼镜已连接时 `GET /v1/assistant-audio/diagnostic` 查询状态与`latest`，未连接时直接读该目录的`latest.json`。
- Mac“内容 → 声音与说话人”选择文件，先关闭ASR分析边界和身份；“本轮结果”可逐段回听。“导出结果”的`matchingDiagnostics`包含参考／query标量矩阵，原导出人物与文字字段保持。
- Mac“录音资料库”按天回看本机与手机副本记录，手机原音点“从手机获取”（需服务运行且已连接同步）；剪辑、标记、重转写和恢复在“录音开发者工具”页。
- 手机“记录 → 记录日程”打开已结束记录，“导出WAV”保留原通道；当前正在录制的那条先停止并等待收尾。文件名不用于判断native／实时／全天来源。
- 实际声纹仍有漏认与单人误分组，当前基准和下一步见 [未解决问题](../.arch/ground_truth.md#当前实现与未解决问题)。

## 数据与远端开发

手机加密记录与Keystore、Mac Application Support／Keychain均为用户数据，清构建产物时保留。原始APK／固件／反编译与当前诊断证据在已忽略的 `analysis/`，不作为发布资源。

部分开发证据在SSH别名 `ubuntu-rx7800xt` 的 `~/openrayneo-lab/`。远端工作使用 `ssh-control` 技能；保留原源码基线、模型、SDK和用户资料，临时排错代码阶段结束Trash，不将远端端口、密钥或个人记录抄进项目文档。
