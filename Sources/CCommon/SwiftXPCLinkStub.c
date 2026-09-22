// 最新 Swift 的 Foundation 覆盖层会自动弱链接 swiftXPC，即使 Swift 代码没有使用 XPC。
// 项目的 XPC 已完全由 Objective-C 实现；该占位符只满足编译器生成的强制加载标记。
__attribute__((used, visibility("hidden")))
char CR4SwiftXPCForceLoadStub __asm__("__swift_FORCE_LOAD_$_swiftXPC") = 0;
