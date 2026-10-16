# 第三方组件

Android 内置 [ESnet iperf3](https://github.com/esnet/iperf) 3.15，
固定 commit `917d2f02188f6f4cdc443df7923a4bde72017d92`。
该版本采用单线程事件循环，兼容 Android bionic，避免依赖其不支持的 pthread_cancel。
保留上游源码及 [LICENSE](third_party/iperf/LICENSE)。本项目未修改上游 C 源码。
Android 构建使用 `android/app/src/main/cpp/iperf_config.h` 和 `version.h` 替代 autotools 生成头文件。
OpenSSL/SCTP 支持未启用，客户端提供 TCP 和 UDP。

Windows 交付包附带 [ar51an/iperf3-win-builds 3.22](https://github.com/ar51an/iperf3-win-builds/releases/tag/3.22)
无 OpenSSL 构建，以及 Cygwin 3.6.10-1 动态库。原始 ZIP SHA256：
`c9feabb3d721039508ccb81f74c2ada3ae11b9e75d33d24510573c2aa21da420`。
iperf3 原始源码：[ESnet 3.22](https://github.com/esnet/iperf/tree/3.22)。
Cygwin 许可及链接例外：[官方说明](https://cygwin.com/licensing.html)。
Windows 运行包 `licenses` 目录保留对应许可证及源码归档。
源码/CI 构建者自行提供的引擎及 DLL 需要保留各自许可。
Windows 运行包包含 Microsoft Visual C++ 14.44 应用本地运行库，以便加载客户端和 Flutter DLL。
Flutter 插件版本和依赖锁定在 `pubspec.lock`，其许可证属于各插件作者。
