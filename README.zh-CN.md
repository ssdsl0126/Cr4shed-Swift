# Cr4shed

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

Cr4shed 是面向越狱 iOS 设备的崩溃报告工具。它可以记录 Objective-C 异常、Mach 异常和内存压力终止事件，并通过 SwiftUI 应用展示生成的报告。

本仓库包含 Cr4shed 的 Swift/Xcode 重写版本，使用 XcodeGen、原生 XPC，以及上游 [libroot](https://github.com/opa334/libroot) 处理 rootless 路径。打包后的 tweak 依赖 MobileSubstrate 和 libSandy。

## 功能

- `Cr4shedException.dylib` 记录未捕获的 Objective-C 异常。
- `Cr4shedMach.dylib` 接入 `ReportCrash`，处理 Mach 层面的崩溃报告。
- `Cr4shedJetsam.dylib` 接入 `ReportMemoryException`，处理内存压力报告。
- `cr4shedd` 负责保存报告，并通过原生 XPC 发送通知。
- SwiftUI 应用支持报告浏览、过滤、排序、黑名单管理和文件分享。
- 项目目标为 iOS 15.0 及更高版本，支持 `arm64` 和 `arm64e` 设备。

## 环境要求

- 安装 Xcode 16 或更高版本的 macOS
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `ldid`
- `dpkg-deb`
- 运行时提供 MobileSubstrate 和 libSandy 的越狱 iOS 设备

请带上 `libroot` 子模块克隆仓库：

```sh
git clone --recurse-submodules https://github.com/ssdsl0126/Cr4shed-Swift.git
cd Cr4shed-Swift
```

如果仓库已经克隆，可以执行以下命令初始化子模块：

```sh
git submodule update --init --recursive
```

## 构建

生成 Xcode 项目并构建 Debian 安装包：

```sh
make package
```

安装包输出路径：

```text
packages/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb
```

如需启用额外日志，可以执行：

```sh
DEBUG=1 make package
```

执行 `make clean` 可以删除生成的 Xcode 文件和打包产物。

## 目录结构

| 路径 | 用途 |
| --- | --- |
| `Sources/App` | SwiftUI 应用 |
| `Sources/CCommon` | 共享的 Objective-C/C 辅助代码和原生 XPC 桥接 |
| `Sources/Exception` | Objective-C 异常捕获 tweak |
| `Sources/Mach` | `ReportCrash` 集成 |
| `Sources/Jetsam` | `ReportMemoryException` 集成 |
| `Sources/Daemon` | 报告保存和通知守护进程 |
| `Sources/Packaging` | Debian 目录、启动守护进程和 tweak 过滤器 |
| `Vendor/libroot` | 链接到上游 libroot 仓库的 Git 子模块 |

构建产物、本地诊断工具和 `TestTweak` 测试插件已通过 `.gitignore` 排除，不会随仓库发布。

## 致谢

原始 Cr4shed 项目由 Muirey03 创建。rootless 路径支持由 [libroot](https://github.com/opa334/libroot) 提供。

## 许可证

本项目基于 [Apache License 2.0](LICENSE) 发布。
