# LAN 测速 v1.3.7

Windows / Android 图形化 iperf3 局域网测速工具。

- 启动自动开启服务端，默认端口统一为 5201；自动搜索运行 iperf3 的局域网设备，也可手动添加 IPv4、IPv6 或主机名。
- 普通测速支持先下载后上传、只下载、只上传；可切换单连接/多连接，实际统计间隔 0.1 秒。
- 时长范围 1–99999 秒，超出引擎单次会话上限时自动续接并合并结果。
- 实时曲线按实际时间推进，长时间运行滚动显示最近 60 秒；服务端也显示连接提示与曲线。
- 静态 TCP 延迟测试持续到手动停止；恒定负载测延迟可选择只上传或只下载。
- 本机连接信息显示连接类型、发送/接收链路速率；Wi-Fi 显示信号强度、频段、信道及标准，每 3 秒刷新。
- 修复安卓服务端重启、端口切换及连续连接后的原生崩溃。

## 下载与使用

- `lan-iperf-windows.zip`：完整 Windows x64 运行包，解压后运行 `lan_iperf.exe`，保留全部 DLL、data 和 licenses。
- `lan-iperf-android-debug.apk`：Android 7.0+，支持 arm64-v8a / armeabi-v7a / x86_64；开发签名测试版，可覆盖同签名旧版。
- `lan-iperf-source.zip`：完整项目源码，含 Android 内置 iperf3 源码及第三方许可说明。
- `SHA256SUMS.txt`：以上文件的 SHA-256 校验值。

两端连接同一局域网并打开软件，等待“服务端已开启”，再搜索或手动添加对方。Windows 防火墙需允许相应 TCP/UDP 端口；访客网络或 AP 隔离可能阻止互访。

## 验证与限制

56 项自动测试通过，含真实 TCP/UDP、IPv4/IPv6 回归；Android 16 模拟器完成服务端连续上传下载、端口切换和 Wi-Fi 信息刷新验证。Windows 原生接口实际读取到本机以太网协商速率。

尚未完成两台物理设备之间的网络实测及用户手机厂商系统验证。链路速率不是 iperf3 实测吞吐量，TCP 连接延迟不是 ICMP ping；系统未提供的 Wi-Fi 字段会明确提示。Windows Cygwin 服务端的 UDP 多连接仍存在上游兼容性限制，建议使用 TCP 或关闭 UDP 多连接。

Windows 运行包包含 iperf3 / Cygwin 对应许可证及源码归档，详见仓库 `THIRD_PARTY.md` 和运行包 `licenses`。
