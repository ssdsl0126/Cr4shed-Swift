# Cr4shed

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

Cr4shed 是面向越獄 iOS 裝置的當機報告工具。它可以記錄 Objective-C 例外、Mach 例外和記憶體壓力終止事件，並透過 SwiftUI 應用程式顯示產生的報告。

本儲存庫包含 Cr4shed 的 Swift/Xcode 重寫版本，使用 XcodeGen、原生 XPC，以及上游 [libroot](https://github.com/opa334/libroot) 處理 rootless 路徑。打包後的 tweak 依賴 MobileSubstrate 和 libSandy。

## 功能

- `Cr4shedException.dylib` 記錄未捕獲的 Objective-C 例外。
- `Cr4shedMach.dylib` 接入 `ReportCrash`，處理 Mach 層面的當機報告。
- `Cr4shedJetsam.dylib` 接入 `ReportMemoryException`，處理記憶體壓力報告。
- `cr4shedd` 負責儲存報告，並透過原生 XPC 傳送通知。
- SwiftUI 應用程式支援報告瀏覽、篩選、排序、黑名單管理和檔案分享。
- 專案目標為 iOS 15.0 及更高版本，支援 `arm64` 和 `arm64e` 裝置。

## 環境需求

- 安裝 Xcode 16 或更新版本的 macOS
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `ldid`
- `dpkg-deb`
- 執行時提供 MobileSubstrate 和 libSandy 的越獄 iOS 裝置

請連同 `libroot` 子模組一起複製儲存庫：

```sh
git clone --recurse-submodules https://github.com/<owner>/<repository>.git
cd Cr4shed-Swift
```

如果儲存庫已經複製，可以執行以下指令初始化子模組：

```sh
git submodule update --init --recursive
```

## 建置

產生 Xcode 專案並建置 Debian 安裝套件：

```sh
make package
```

安裝套件輸出路徑：

```text
packages/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb
```

如需啟用額外記錄，可以執行：

```sh
DEBUG=1 make package
```

執行 `make clean` 可以刪除產生的 Xcode 檔案和打包產物。

## 目錄結構

| 路徑 | 用途 |
| --- | --- |
| `Sources/App` | SwiftUI 應用程式 |
| `Sources/CCommon` | 共用的 Objective-C/C 輔助程式碼和原生 XPC 橋接 |
| `Sources/Exception` | Objective-C 例外捕獲 tweak |
| `Sources/Mach` | `ReportCrash` 整合 |
| `Sources/Jetsam` | `ReportMemoryException` 整合 |
| `Sources/Daemon` | 報告儲存和通知守護程式 |
| `Sources/Packaging` | Debian 目錄、啟動守護程式和 tweak 篩選器 |
| `Vendor/libroot` | 連結至上游 libroot 儲存庫的 Git 子模組 |

建置產物、本機診斷工具和 `TestTweak` 測試外掛程式已透過 `.gitignore` 排除，不會隨儲存庫發佈。

## 致謝

原始 Cr4shed 專案由 Muirey03 建立。rootless 路徑支援由 [libroot](https://github.com/opa334/libroot) 提供。
