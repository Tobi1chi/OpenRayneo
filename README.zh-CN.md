# OpenRayneo

[English](README.md) · [简体中文](README.zh-CN.md)

**从 Mac 向雷鸟 RayNeo iO 眼镜发送通知和提词稿。**

OpenRayneo 是一个非官方、实验性的蓝牙 Bridge，提供本机 HTTP API，可供脚本、桌面应用和本地自动化调用。Bridge 直接连接眼镜，无需手机中转、云服务或修改官方 App。

目前复用眼镜已有的通知和提词器界面，不提供任意图形绘制、屏幕镜像或自定义显示布局。

## 已验证功能

以下结果来自一台 RayNeo iO 和运行 macOS 15.6.1 的 Apple Silicon Mac：

| 功能 | 实测结果 |
| --- | --- |
| Mac 蓝牙直连 | BLE 认证和 RFCOMM 26 通道正常 |
| 自定义通知 | 中文标题、正文正常显示 |
| 中文提词稿 | 短稿和 120 行、16,319 字节的长稿正常显示 |
| 播放控制 | 暂停、继续、退出均已目视确认 |
| 较大数据写入 | 按 RFCOMM 协商的 MTU 分段发送 |
| 连接诊断 | 通过 HTTP 查询连接阶段并重试 |

测试时未记录眼镜固件版本。其他固件、其他雷鸟型号、Intel Mac 和更早的 macOS 版本尚未验证。

## 环境要求

- 已开机、已与 Mac 配对的 RayNeo **iO** 眼镜。
- macOS 13 或更高版本：这是软件包的部署目标，实测版本为 15.6.1。
- Xcode Command Line Tools 或 Xcode，Swift 5.10 或更高版本；开发环境实测为 Swift 6.1.2。
- 按 macOS 提示，授予 Bridge 或启动它的应用蓝牙访问权限。

项目使用 Apple 系统框架，没有第三方 Swift 包依赖。构建和运行均不需要官方 Android APK 或蓝牙抓包文件。

## 快速开始

### 1. 构建

如尚未安装 Apple 开发工具：

```sh
xcode-select --install
```

克隆并构建：

```sh
git clone https://github.com/Tobi1chi/OpenRayneo.git
cd OpenRayneo
sh scripts/build-app.sh
```

脚本生成 `OpenRayneoBridge.app`，其中包含 macOS 要求的蓝牙用途说明。这是本机构建的命令行应用包，不是经过公证的图形安装程序。

### 2. 配对并启动

在 **系统设置 → 蓝牙** 中将眼镜与 Mac 配对，并自行完成系统配对确认。首次连接时让眼镜靠近 Mac；若手机平时连接这副眼镜，建议暂时关闭手机的系统蓝牙。

在第一个终端中启动：

```sh
export OPENRAYNEO_API_TOKEN="$(openssl rand -hex 24)"
./OpenRayneoBridge.app/Contents/MacOS/openrayneo-bridge
```

如系统询问，请允许蓝牙访问。保持该终端运行，按 `Ctrl+C` 停止服务。

默认 API 地址是 `http://127.0.0.1:8765`，启动输出会显示令牌。在第二个终端设置相同令牌，再执行后面的示例：

```sh
export OPENRAYNEO_API_TOKEN='粘贴第一个终端显示的令牌'
```

如果 Mac 配对了多副 iO，请在启动前设置 `RAYNEO_ADDRESS`，指定目标设备的经典蓝牙地址。

### 3. 连接并发送通知

```sh
curl -X POST http://127.0.0.1:8765/v1/device/connect \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"

curl -X POST http://127.0.0.1:8765/v1/notifications \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"来自 Mac 的通知","body":"你的本地应用可以向这里发送文字。"}'
```

通知和提词稿接口也会按需连接，因此可以省略显式的连接请求。

## API

除 `GET /health` 外，所有接口都要求 `Authorization: Bearer <token>`。

| 方法 | 路径 | 用途 |
| --- | --- | --- |
| `GET` | `/health` | 服务状态和 BLE/RFCOMM 连接标志 |
| `GET` | `/v1/device` | BLE 阶段、扫描数量、最近的 BLE 错误及连接状态 |
| `POST` | `/v1/device/connect` | 建立连接，不发送显示内容 |
| `POST` | `/v1/notifications` | 发送通知，必填字符串 `title` 和 `body` |
| `POST` | `/v1/teleprompter` | 传输并启动提词稿，必填非空字符串 `text` |
| `POST` | `/v1/teleprompter/pause` | 暂停当前稿件 |
| `POST` | `/v1/teleprompter/resume` | 继续当前稿件 |
| `POST` | `/v1/teleprompter/stop` | 退出当前稿件 |

### 提词器

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"演示稿","text":"你好，雷鸟眼镜。\n这段文字由 Mac 直接发送。","speed":60}'
```

`title` 默认值为 `OpenRayneo`，`speed` 默认值为 `120`。测试使用过 `60` 和 `120`，固件支持的完整范围和单位尚未确定。当前布局采用三秒倒计时。

成功响应包含稿件 ID：

```json
{"ok":true,"sent":"teleprompter","did":"<script-id>"}
```

控制当前 Bridge 进程创建的稿件：

```sh
curl -X POST http://127.0.0.1:8765/v1/teleprompter/pause \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/resume \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
curl -X POST http://127.0.0.1:8765/v1/teleprompter/stop \
  -H "Authorization: Bearer $OPENRAYNEO_API_TOKEN"
```

### 响应含义

- `200`：查询成功，或连接接口已打开 RFCOMM。`/health` 中的 `ok: true` 只表示服务运行正常，眼镜连接状态需查看 `bleReady` 和 `rfcommConnected`。
- `202`：显示或控制数据帧已经写出。提词稿启动还会等待文件传输确认，但返回值不等于目视显示或播放状态确认。
- 错误响应为 `{"error":"..."}`。常见状态包括参数错误 `400`、令牌错误 `401`、没有活动稿件 `409`、数据过大 `413`、连接或传输失败 `503`/`504`。

## 配置

启动前通过环境变量配置：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `OPENRAYNEO_API_TOKEN` | 启动时生成 | API 令牌，会打印到启动输出 |
| `OPENRAYNEO_PORT` | `8765` | 本机 HTTP 端口 |
| `RAYNEO_ADDRESS` | 自动选择唯一配对的 iO | 多设备时指定经典蓝牙地址 |
| `OPENRAYNEO_BLE_TRACE` | 关闭 | 设为 `1`，记录附近广播名称、服务、可连接性和 RSSI |

服务仅监听 `127.0.0.1`，面向本地集成。启动令牌属于访问凭据，分享日志前应移除；BLE 调试日志还可能包含附近设备的名称。

## 常见问题

**无法选择眼镜：**先在 macOS 中配对；如有多副 iO，设置 `RAYNEO_ADDRESS`。

**BLE 扫描超时：**保持眼镜唤醒并靠近 Mac，检查其配对或可发现状态，暂时关闭手机的系统蓝牙。实测仅断开手机 App 有时不足以释放连接，同时也应检查 macOS 的蓝牙权限。

**连接失败后重试：**先查看 `GET /v1/device`，再调用 `POST /v1/device/connect`。BLE 阶段等待 15 秒，超时后会清理扫描及待建立连接；RFCOMM 打开阶段另有 12 秒等待时间。

**控制返回 `409`：**先通过当前 Bridge 进程启动稿件。进程重启或执行 `stop` 后，不会恢复原稿件的活动状态。

## 当前限制

- 项目处于早期原型阶段，硬件验证范围有限，不是官方 SDK。
- 每个进程管理一副选定的眼镜和一份活动稿件，不同步手机 App 的提词稿库。
- 实测长稿只触发了一次应用层文件块请求；多次请求及更长稿件仍需真机验证。
- 单个协议载荷最多 65,531 字节，封装字段会占用其中一部分空间。超大帧返回 `413`；该限制与 RFCOMM 的 MTU 分段不同。
- 尚未实现账户绑定的 ECDH 认证；固件要求此认证时会明确报错。

## 开发

```sh
swift build
sh scripts/build-app.sh
```

GitHub Actions 在 macOS 上构建应用，蓝牙行为仍需真机测试。[协议笔记](docs/protocol.md) 记录了连接流程、数据格式和验证范围。

欢迎提交 Issue 和 Pull Request。连接问题请附上眼镜型号及固件版本、macOS 版本和脱敏后的 `/v1/device` 响应。不要公开令牌、设备地址、私人通知正文、官方 APK 或原始抓包。

## 许可证与项目关系

源码采用 [Apache License 2.0](LICENSE)。OpenRayneo 是独立项目，与雷鸟没有隶属或背书关系；相关名称和商标属于各自权利人。仓库不分发官方 APK、固件镜像或抓取的用户数据。
