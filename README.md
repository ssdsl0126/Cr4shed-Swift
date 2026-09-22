# Cr4shed

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md)

Cr4shed is a crash reporter for jailbroken iOS devices. It records Objective-C exceptions, Mach exceptions, and memory-pressure terminations, then presents the resulting reports in a SwiftUI application.

This repository contains the Swift/Xcode rewrite of Cr4shed. It uses XcodeGen, native XPC, and the upstream [libroot](https://github.com/opa334/libroot) project for rootless path handling. The packaged tweak declares MobileSubstrate and libSandy as its runtime dependencies.

## Features

- `Cr4shedException.dylib` records uncaught Objective-C exceptions.
- `Cr4shedMach.dylib` integrates with `ReportCrash` for Mach-level crash reports.
- `Cr4shedJetsam.dylib` integrates with `ReportMemoryException` for memory-pressure reports.
- `cr4shedd` stores reports and delivers notifications through native XPC.
- The SwiftUI app supports report browsing, filtering, sorting, blacklist management, and file sharing.
- The project targets iOS 15.0 and later on `arm64` and `arm64e` devices.

## Requirements

- macOS with Xcode 16 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `ldid`
- `dpkg-deb`
- A jailbroken iOS device with MobileSubstrate and libSandy available at runtime

Clone the repository with its `libroot` submodule:

```sh
git clone --recurse-submodules https://github.com/ssdsl0126/Cr4shed-Swift.git
cd Cr4shed-Swift
```

If the repository has already been cloned, initialize the submodule with:

```sh
git submodule update --init --recursive
```

## Build

Generate the Xcode project and build the Debian package:

```sh
make package
```

The package is written to:

```text
packages/com.muirey03.cr4shed_5.0.0_iphoneos-arm64.deb
```

For a debug build with additional logging:

```sh
DEBUG=1 make package
```

Use `make clean` to remove generated Xcode and packaging output.

## Repository layout

| Path | Purpose |
| --- | --- |
| `Sources/App` | SwiftUI application |
| `Sources/CCommon` | Shared Objective-C/C helpers and native XPC bridge |
| `Sources/Exception` | Objective-C exception capture tweak |
| `Sources/Mach` | `ReportCrash` integration |
| `Sources/Jetsam` | `ReportMemoryException` integration |
| `Sources/Daemon` | Report storage and notification daemon |
| `Sources/Packaging` | Debian layout, launch daemon, and tweak filters |
| `Vendor/libroot` | Git submodule linked to the upstream libroot repository |

Build products, local diagnostics, and the `TestTweak` test plugin are intentionally excluded by `.gitignore`.

## Credits

The original Cr4shed project was created by Muirey03. Rootless path support is provided by [libroot](https://github.com/opa334/libroot).

## License

This project is distributed under the [Apache License 2.0](LICENSE).
