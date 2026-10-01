# 连接、认证与故障恢复

## 复用桌面服务

以下适用于带桌面控制界面的版本。若安装的是仅提供 headless API 的版本，使用下方独立服务流程；不要假设每个已发布版本都有 GUI。

1. 打开 OpenRayneo App，在 **设备与 API** 选择已配对眼镜，点击 **连接并启用 API**。
2. 读取当前 API 地址；通过页面的复制功能取得令牌或带令牌的调用示例。令牌留在本机环境中，不回显到对话。不要假设 GUI 使用 8765。
3. `GET /health` 检查服务及 `bleReady`、`rfcommConnected`；`GET /v1/device` 验证鉴权和读取 BLE/RFCOMM 诊断。
4. 本地 API 执行期间不要同时点击 GUI 的显示/音频功能。GUI 的当前会话状态只跟踪自身操作。

GUI 拥有独立的 `--headless` 子进程；断开连接或退出 GUI 会停止它。**重启连接服务** 保留系统配对，但更换令牌，端口也可能变化。重启前先停止正在进行的录音并确认文件结束。服务重启丢失字幕 SID、提词器状态和本进程创建的待办 ID 所有权。

## 尚未配对

配对不属于 HTTP 路由。需要配对时使用 App 的 **添加并配对眼镜**，按界面引导让眼镜进入配对模式。该操作会替换目标眼镜的 Mac 配对记录；不要把它当作普通重连按钮。

系统蓝牙搜索曾找不到眼镜。历史成功命令行流程是：清理旧 Mac 记录，眼镜处于配对模式，用独立的已知地址 `IOBluetoothDevicePair` 助手配对，独立确认配对成功，**退出助手后再单独启动 Bridge**，BLE 认证后打开 RFCOMM 26。需要重现时先读仓库 `docs/protocol.md` 的已验证恢复步骤及当前配对帮助，不临时加入 SDP、HFP 等待或修改 `pairValue`。`paired=true` 不是数据通道可用的证明。

不要自动重置蓝牙、删除系统密钥、忽略设备、重新进入配对模式或反复尝试配对。出现明确失配证据后，向用户说明具体状态和恢复动作；取得需要的设备操作配合。已有授权不用重复询问。

## 独立 headless 服务

只有没有其他 Bridge 控制眼镜、并且任务需要自己启动服务时使用。以下从仓库根目录执行；需要已有构建产物，否则先按仓库 README 构建：

```sh
# 选择确认空闲的端口；8766 只是示例。
export OPENRAYNEO_PORT=8766
export OPENRAYNEO_API_URL="http://127.0.0.1:$OPENRAYNEO_PORT"
export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
open -n -g ./OpenRayneoBridge.app \
  --env "OPENRAYNEO_PORT=$OPENRAYNEO_PORT" \
  --env "OPENRAYNEO_API_TOKEN=$OPENRAYNEO_API_TOKEN" --args --headless
```

ASR 应通过 `.app` 和 Launch Services 启动，使蓝牙/语音权限归属于正确 App。允许系统权限后再查询状态，不修改 TCC 数据库。同一 shell 的环境可供调用脚本复用；agent 每次执行可能是不同 shell，需保留自己的私有进程环境，不能假设 export 跨执行永久有效。必要时通过受保护、Git 忽略的本地配置加载，不在共享输出打印。

有多副配对眼镜时，将目标实际地址设置为 `RAYNEO_ADDRESS`，并在上述 `open` 中用 `--env` 显式传给服务。不要从示例推断设备地址。独立 headless 启动日志可能含令牌；不要直接发布原始日志。

## 有限恢复

| 现象 | 下一步 |
| --- | --- |
| 连接拒绝 / 非 JSON 响应 | 核对服务是否运行及当前地址，不假设该端口就是 Bridge |
| `401` | 获取当前服务令牌；这不是重新配对的理由 |
| `bleReady=false` | 查看 `/v1/device` 的 `ble` 状态、扫描和错误，核对眼镜开机、权限及手机连接占用 |
| BLE 就绪但 `rfcommConnected=false` | 保存诊断；BLE 认证成功不等于 RFCOMM 成功 |
| 首次 connect 超时 | 不自动循环；检查状态。条件纠正后可再试一次；仍失败则停下并报告具体错误 |
| 同一 App 会话中卡住 | 已停止活动后可用 **重启连接服务** 一次，重新获取地址和令牌；保留 Mac 配对 |
| 重启服务后仍失败或 `BT_ERROR_INVALID_LINK_KEY` | 停止尝试，按项目恢复文档协调用户处理；不要声称确定是 macOS 缓存或 `pairValue` 导致 |
| `409` | 读取功能状态并核对自己拥有的会话，正确结束前一个功能；不要重新配对 |
| start 的 `acknowledged=false` | 用匹配的 captions/prompts stop 清理，再在条件纠正后重开；不要直接发 text |

常规 BLE 尝试约 15 秒，RFCOMM 打开另外最多约 12 秒；语音授权可能等待 60 秒。脚本默认单次超时 90 秒。客户端超时不会撤销已经发送的设备操作，因此重试前检查设备或功能状态。

排障报告保留 HTTP 状态、连接阶段和必要错误，移除令牌、设备地址、附近设备名称、通知内容和语音正文。不需要为普通 API 调用抓手机日志或重新研究 APK。
