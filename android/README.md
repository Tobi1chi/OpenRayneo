# OpenRayneo Android

面向普通、无 Root 安卓手机，直接连接 RayNeo iO。需要 Android 13（API 33）或更高版本。0.1.3-dev 已在小米 13 完成首次完整蓝牙连接；0.2.0-dev 已验证手机与电脑 Codex 对话、SDK 导航显示。

当前 0.4.0-dev 按用户要求改为**高德 App 导航通知跟随**，已移除高德 SDK、Key 和定位权限。导航在高德 App 里启动，OpenRayneo 读取导航通知后将方向／距离／路名显示到眼镜。导航恢复 `0x13` 的 20×5 固定大箭头／距离／动作／8 格路名，先启动字幕音频会话，再配置布局；导航音频按 48 kHz 单声道 PCM 解码。问答仍使用 `0x17` 实时提示和双声道，切换模式会重建会话。手机显示音量，只在内存处理，不保存或上传，可在设备页暂停／恢复。字幕音频与固定网格并行仍待眼镜真机验收。

0.4.0-dev 引入纯协调器、类型化事件／效果和独立连接管理器。停止导航回到空闲，不再隐式开启实时提示；回答、外部页面让出和重连分别处理，迟到回调不能重新占屏。设备页可单独重启音频解码而保持页面。设计与验收见 [眼镜协调器](../docs/android-state-machine.md)。构建、Lint 和 39 项临时回归已通过，重构版真机验收待完成。

连接由前台服务持有，退出页面不会主动断开。保留可配置的手机模型、电脑 Codex 会话／审批／取消与诊断日志。尚未实现眼镜语音识别、本地 HTTP API、提词器、录音或系统虚拟麦克风；无线部署和长时间后台运行仍待验收。

使用与证据见 [高德通知导航](../docs/android-notifications.md)及 [手机配置与 Codex 连接](../docs/android-setup.md)。

## 构建与安装

需要 JDK 17、Android SDK Platform 36 和 Build-Tools 36.0.0。在 `android/local.properties` 设置本机 SDK 路径，或通过 `ANDROID_HOME` 指定；不要提交 `local.properties`。

```sh
cd android
./gradlew :app:assembleDebug :app:lintDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.openrayneo.android/.MainActivity
```

小米系统若返回 `INSTALL_FAILED_USER_RESTRICTED`，可改为手动安装：

```sh
adb push app/build/outputs/apk/debug/app-debug.apk /sdcard/Download/OpenRayneo-0.4.0-dev.apk
```

在手机文件管理器的“下载”目录打开 APK，根据系统提示完成安装。USB 调试授权与 APK 安装许可是不同的步骤。

首次启动允许“附近设备”权限。保持眼镜开机和唤醒，断开官方手机 App 与 Mac Bridge 的连接。优先扫描并选择眼镜的 BLE 广播设备。

0.1.3-dev 默认使用完整连接流程，不勾选“仅通过 BLE 验证通知”。该版本修正了此前误用日志抓取模块 SPP UUID 的问题，保留认证参数与 `pairValue=1` 以便比较真机结果。

BLE 地址与经典蓝牙地址可能不同，应用会读取身份特征并使用其中的经典蓝牙地址连接 SPP。广播包含经典地址时，先用公开的 `createBond()` 请求系统配对，等待 `BOND_BONDED` 后再开始 BLE 认证；否则读取身份后、连接 SPP 前完成配对。请在手机上确认系统配对提示，应用不会删除已有配对。

勾选 BLE 选项仅用于对照实验，跳过经典配对与 SPP。认证通过后允许尝试通知，但不代表完整配对完成或眼镜已退出配对页面。BLE 写入按协商 MTU 分块，等待每次写入完成后再发送下一块，并响应设备要求的传输确认帧。

所选模式的连接完成后才能点击“发送中文测试通知”。BLE 就绪不代表 SPP 已连接，写出数据也不代表眼镜已显示；佩戴者仍需目视确认。断开后再连接一次，用于验证重连。诊断可使用页面的“复制诊断日志”，或：

```sh
adb logcat -s OpenRayneo:I
```

## 协议来源与当前边界

- 帧、CRC16-XMODEM、认证和通知载荷沿用仓库的 Swift 实现与 `docs/protocol.md`。
- 本地 RayNeo AI 1.0.5 APK 的业务调用链 `E3/M → E3/C0628l → V3/o → V3/d → V3/p` 使用 UUID `99999999-9999-9999-9999-999999999999` 和公开的 `createRfcommSocketToServiceRecord`。此前引用的 `R7/k`、`R7/r` 属于 RNLink 日志抓取模块（见 `R7/n`），其标准 SPP UUID 不能作为眼镜业务服务的依据。Mac 版直接打开 RFCOMM 通道 26，未经过 Android 的 UUID 服务查找。
- APK 的 `E3/M` 对 VENUS（型号 `06`）支持 BLE-only 模式，并跳过 SPP；`E3/T` 在 SPP 不可用时通过 BLE 发送传输确认。0.1.2-dev 根据这条路径增加 BLE 通知验证，不把 SPP 作为唯一的数据传输方式。该模式的真机显示能力仍需单独验收。
- APK 的 `E3/P` 从 Android ID 的末尾 12 个十六进制字符派生六字节身份。未绑定眼镜采用相同派生方式；已绑定眼镜保留 Mac Bridge 已验证的“使用眼镜返回的绑定身份”行为。Android ID 按应用签名等条件隔离，本应用的身份不等于官方 App 的身份。
- `pairValue=1` 保留 Mac 基线。官方 APK 普通重连使用 `2`；在基线实测前不同时改变身份与配对意图。
- 账户绑定 ECDH 仍未实现，设备要求此模式时明确报错。
- BLE 协商大 MTU后发送完整认证帧；过小的 MTU会报错。RFCOMM 按字节流接收，解码器处理拆包、粘包与 CRC 错误。
- 官方 APK、反编译内容、设备日志和构建产物均不提交。

## 验收顺序

1. APK 编译、Lint、手机安装与启动。
2. 设备发现、BLE 身份读取与认证。
3. 所选模式建立、有效协议帧接收；BLE 与 SPP 分别记录验证结果。
4. 中文通知写出及佩戴者目视确认。
5. 断开、再次连接与再次显示。

0.2.1-dev 通知导航已获用户目视确认：显示正常、不再自动滚动。实时提示页仍待单独验收；不继续旧 SDK 导航与锁屏实验。

0.2.0-dev 本地验证：APK 构建和 Lint；独立参考帧、CRC、拆包／粘包、损坏帧恢复、Protobuf 音频字段隔离、20×5 网格的五项临时回归检查。电脑 App Server 已验证无令牌握手返回 401、带令牌初始化、模型列表读取和一次不使用工具的真实对话完成。这些检查尚不能替代手机端安装、地图 Key 鉴权、实际路线、锁屏重连及跨网络测试。阶段性测试源码在验证结束后移除。

2026-10-12，小米 13（Android 16 / HyperOS 3）已验证设备发现、B81D 与所需特征发现、MTU 517、绑定身份读取和 BLE 应用认证。0.1.1-dev 的显式系统配对收到 `BOND_BONDED`，但 SPP 仍失败；Android 日志记录 SDP 响应成功后服务记录解析报错，最终通道号 `scn=0`、服务发现失败。该次请求使用了错误 UUID，不能据此认定 Android SDP 解析器有缺陷。0.1.2-dev BLE 模式已收到业务帧，但用户仍报告连接失败或系统配对提示，完整配对和通知显示未获验证。

0.1.3-dev 修正 UUID 后，同日在小米 13 完成首次完整连接验证：

- 先以 BLE-only 模式认证并发送通知，用户确认通知可见，但眼镜未进入主页。该模式不能作为完整连接的验收结果。
- 取消 BLE-only 后，一次系统配对在确认窗口出现约 30 秒后返回 `HCI_ERR_AUTH_FAILURE`。未找到确认提交记录，不能据此断定用户未点击或密钥失效。
- 随后的成功尝试在 13:20:14 收到 `BOND_BONDED`，13:20:16 完成 BLE 应用认证，并收到命令 23、配对状态 `2`。
- 使用业务 UUID 的 SDP 查询返回 `SUCCESS scn:26`，随后 RFCOMM 通道 26 打开并持续收到有效协议帧，与 Mac 已验证的数据通道一致。13:20:21 通过 RFCOMM 写出中文测试通知；用户确认完整模式连接成功、眼镜进入主页。
- 此次使用 `pairValue=1` 和本应用 Android ID 派生身份。保留现有配对后的断开重连、后台运行仍待单独验证。

Mac 历史上也曾出现系统配对成功、BLE 认证通过而 RFCOMM 失败，但当时系统日志明确记录 `BT_ERROR_INVALID_LINK_KEY`。已验证的恢复方式是停止 Bridge、仅忘记 Mac 端旧配对、保持眼镜状态、通过独立 helper 配对并退出，再从新进程确认配对后启动 Bridge；随后通道 26 打开并显示通知。详见 `docs/protocol.md` 的 Verified recovery。安卓只有出现对应密钥错误证据时才进一步比较这条恢复路径，不因表面超时相似就重置配对。
