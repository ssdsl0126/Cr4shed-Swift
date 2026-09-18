# Cr4shed Swift 重构开发计划

## Summary

Xcode 重写，去掉 CrossOverIPC / libnotifications / Cephei / FRPreferences。路径 libroot，IPC 原生 XPC，通知由 daemon 直发。iOS 15–26。Swift 为主；仅全局异常 dylib 和 ElleKit shim 用 C。

钩子以 [headers.82flex.com](https://headers.82flex.com/) 15.0 / 16.0 / 18.x / 26.2 为准，**按版本表装 selector**。真机验收用现有 **iOS 15、16、26**；17/18 无真机，只做头文件对照并在发布说明标「未真机」。

日志仍是钩子生成的 Cr4shed `*.log`，不读系统 `.ips`。导出：打开哪份就分享哪份磁盘上的 `*.log`（文件 URL），禁止再分享 HTML 转义纯文本。

崩溃路径低分配、短驻留。本文件即实现对照表，版本表不得省略。

NSException 处理因 Foundation API 编译为 Objective-C（`.m`），但 **Exception dylib 禁止链接 Swift runtime**。Mach / Jetsam / App / Daemon 为 Swift。

## 语言、性能、导出、真机（已锁定）

- **必须无 Swift runtime：** `Cr4shedException`（`otool -L` 不得出现 `libswift*`）；`HookSupport.c`。
- **100% Swift：** App、daemon、Mach、Jetsam、Shared 业务。不为 Mach 再写 `.m` 胶水。
- 热路径：黑名单 / Jetsam 开关 / handled 在符号化前返回；栈与镜像写完即释放；GUI 列表只读文件名+mtime，正文懒加载；Mach/Jetsam `-Osize`；Exception 保留 `hasCrashed` 门闩。
- **数据源：** 钩子在内存拼文本，写入 `JBROOT_PATH("/var/mobile/Library/Cr4shed")/*.log`。不把 DiagnosticReports `.ips` 当主数据。
- **导出：** 日志详情页分享当前 `Log.path` 的文件 URL，文件名保持 `Process@yyyy-MM-dd_h:mm_a.log`。不要字符串分享、不要改扩展名。不做 zip。
- **真机：** 15 / 16 / 26 必须装包测 NSException、BAD_ACCESS、Jetsam、通知、Safe Mode 通知。17/18 只对 82flex。模拟器不能验注入/XPC/launchd。

## Hook 版本表（实现必须对照）

### 1. Exception（无 Swift）

| 符号 | 15.0 | 16.0 | 17–18 | 26.2 | 动作 |
|---|---|---|---|---|---|
| `NSSetUncaughtExceptionHandler` | 有 | 有 | 有 | 有 | `MSHookFunction` |
| `NSGetUncaughtExceptionHandler` | 有 | 有 | 有 | 有 | 对外隐藏我们的 handler |

### 2. Mach 主类

| 类 | 15.0 | 15.2 | 16.0+ | 26.2 | 动作 |
|---|---|---|---|---|---|
| `OSACrashReport` | 有 | 有 | 有 | 有 | 全程主钩 |
| `LegacyCrashReport` | 有 | 有 | 无 | 无 | 仅 15.0–15.2 加旧 init/回溯 |
| 名为 `CrashReport` | 头文件无 | 无 | 无 | 无 | 不要当主查找 |

### 3. `OSACrashReport` 方法

| 符号 | 15.0 | 16.0 | 26.2 | 动作 |
|---|---|---|---|---|
| `loadBundleInfo` | 有 | 有 | 有 | 主采集 |
| `generateLogAtLevel:withBlock:` | 有 | 有 | 有 | 写出后再生成 Cr4shed 报告 |
| `generateCustomLogAtLevel:withBlock:` | 无 | 无 | 无 | 非主路径 |
| `initWithTask:` 无 threadId | 有 | 无 | 无 | 只装 15.x |
| `initWithTask:...threadId:` | 无 | 有 | 有 | 16–26 主 init |
| `isExceptionNonFatal` | 有 | 有 | 有 | 优先 |
| `decode_signal` | 有 | 有 | 有 | 信号名 |
| `decodeBacktraceWithBlock:` | 无 | 无 | 无 | 非主路径 |
| `_readStringAtTaskAddress:immutableOnly:maxLength:` | 有 | 无 | 无 | 15.x |
| `_readStringAtTaskAddress:maxLength:immutableCheck:` | 无 | 有 | 无 | 16–18 |
| `_readStringAtTaskAddress:...isInSharedCache:` | 无 | 无 | 有 | 26.x |

用 `respondsToSelector` 三选一缓存。

### 4. `OSACrashReport` ivar（没有就跳过）

| ivar | 15.0 OSA | 16.0 | 26.2 | 用途 |
|---|---|---|---|---|
| `_task` `_exceptionType` `_exceptionCode` `_exceptionCodeCount` `_signal` `_crashedThreadNumber` `_procName` `_bundle_id` `_short_vers` `_crashingAddress` `_exit_snapshot` `_terminator_reason` `_bundle_info` | 有 | 有 | 有 | 基本字段 |
| `_taskImages` `_threadInfos` `_usedImages` | 有 | 有 | 有 | 15–26 主回溯/镜像 |
| `_threadState`（`uint[1296]`）及 flavor/count | 有 | 有 | 有 | 按 flavor 解码，不当结构体硬读 |
| `_binaryImages` `_threadNames` `_backtraces` `_bundle_vers` | 无 | 无 | 无 | 只在 Legacy 15.0–15.2 |

### 5. `LegacyCrashReport`（仅 15.0 / 15.2）

有则加钩：无 threadId 的 init、`decodeBacktraceWithBlock:`、`generateCustomLogAtLevel:`、`signalName`、`binaryImageDictionaryForAddress:`、旧 ivar 与旧 `_readString`。16+ 跳过。

### 6. Jetsam

| 符号 | 15.0 | 16.0 | 26.2 | 动作 |
|---|---|---|---|---|
| `extractCorpseInfo` / `extractBacktraceInfo` | 无 | 无 | 无 | 禁止再钩 |
| `+resourceExceptionFromTask:error:` | 有 | 有 | 有 | 主钩 |
| `execName` `bundleID` `startTime` `upTime` `task` | 有 | 有 | 有 | 报告字段 |
| `prettyPrintBinaryImages` | 有 | 有 | 有 | 镜像 |
| `prettyPrintBacktrace:`（`Bool`） | 有 | 有 | 有 | 默认不调 |

### 7. 删除 / 运行时再探

删除 SB 通知 tweak、CrossOverIPC、HBPreferences。运行时探：`initWithBundleIdentifier:`、`dyld_all_image_infos.errorMessage`、ESR/FAR、CoreSymbolication。失败降级。

## 现有行为必须保住

NSException 过滤、culprit、硬黑名单、handled 去重；Mach 错误线程、VM、Swift annotations；Jetsam 开关+黑名单；日志尾 JSON、文件名、`0666`/`mobile`；GUI 分组/排序/拉黑/深链/懒加载。分享改为当前 `.log` 文件 URL。

## 工程结构

- `Sources/CCommon`：路径、XPC、日志格式、handled、culprit、ElleKit shim、符号化 C 封装
- `Sources/Exception`：全局 NSException 钩子（ObjC，无 Swift）
- `Sources/Mach`：`OSACrashReport` / `LegacyCrashReport`
- `Sources/Jetsam`：`resourceExceptionFromTask:error:`
- `Sources/Daemon`：XPC 服务、写文件、通知
- `Sources/App`：SwiftUI
- `Sources/Shared`：Swift 业务封装
- `Scripts/package.sh`：ldid + dpkg-deb
- `project.yml`：XcodeGen

## Test Plan

- `otool -L`：Exception 无 `libswift*`。
- 82flex：15.0 / 16.0 / 18.0 / 26.2 与上表勾完再写钩子。
- **iOS 15、16、26 真机：** NSException 不与 Mach 重复；BAD_ACCESS；Jetsam 走 `resourceExceptionFromTask:`；通知打开对应日志；Safe Mode 通知；分享得到可保存的 `.log` 且与磁盘一致。
- 17/18：只记头文件对照。
- 列表不全量读正文。

## Assumptions

- 82flex 与真机元数据一致。
- 有 15 / 16 / 26 越狱机，无 17 / 18。
- 系统 Swift 可被 ReportCrash / ReportMemoryException 加载。
- 现网 Jetsam 15+ 视为已失效。
- 不做 iOS 27 `CrashReportExtension`，不做批量 zip，不以系统 `.ips` 替换自有 `.log`。
