## Cr4shed

Swift 重写版（Xcode，无 Theos）。去掉 CrossOverIPC / libnotifications / Cephei / FRPreferences。iOS 15–26，路径走 libroot，IPC 用原生 XPC，通知由 cr4shedd 直发。

开发计划见 DEVELOPMENT_PLAN.md。

## 构建

需要 Xcode、XcodeGen、ldid、dpkg-deb。

    make -f Makefile.swift.mk

产物：packages/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb

不依赖 CrossOverIPC 与 libnotifications。钩子库需要 Substrate / ElleKit / libhooker 之一。

## 真机

在 iOS 15、16、26 上验收。17/18 仅对照 headers.82flex.com 头文件，未真机。

原作者 Muirey03。rootless 适配曾由 mhster_nice 等完成。
