# 动画调试经验

## SwiftUI + AppKit 混合动画调试

### 问题场景

BoringNotch 窗口展开动画涉及 SwiftUI frame height 和 NSWindow animator 同步。

### 失败经历

修改了 9-10 次，尝试了禁用动画、调整 animatingNotchSize 设置时机、移除 withAnimation 等多种方案，全部失败。

### 根本原因

1. **NotificationCenter 通知重复发送** - `doOpen()` 和 `ViewModel.open()` 都发送了 `notchWillOpen`，AppDelegate 收到两次 → 两个动画同时启动 → 崩溃
2. **animatingNotchSize 多处修改** - ContentView、ViewModel、AppDelegate 都在修改同一状态 → 线程冲突
3. **"height is negative" 错误** - 两次动画同时计算中间帧 → SwiftUI 得到负值 → 崩溃

### 正确的调试方法

1. **使用 Console.app + NSLog**
   ```swift
   NSLog("🚀 [doOpen] START: closedHeight=%.0f, targetHeight=%.0f", ...)
   NSLog("🪟 [AppDelegate.notchWillOpen] START: targetHeight=%.0f", ...)
   ```
   - 在 Console.app 搜索进程名（如 `boringNotch`）
   - **不要用 print/fputs/文件写入** - 这些在 macOS GUI 应用中经常看不到

2. **追踪数据流每一步**
   - 从触发点（`doOpen`）到最终执行（`AppDelegate.notchWillOpen`）
   - 每个关键节点加日志：参数值、状态变化、通知发送
   - 特别追踪 **NotificationCenter 发送次数**

3. **检查通知监听是否重复注册**
   ```swift
   // AppDelegate 可能多次注册同一通知
   NotificationCenter.default.addObserver(forName: .notchWillOpen, ...)
   ```
   - 检查是否有多个 `addObserver` 调用
   - 检查是否从多处发送同一通知

4. **单一修改原则**
   - 每次只改一处代码
   - 测试后再改下一处
   - **不要一次性修改多个文件的多处代码**

5. **理解 SwiftUI 和 AppKit 动画线程模型**
   - SwiftUI 动画：在主线程计算中间帧
   - NSWindow animator：AppKit 动画上下文，可能在不同线程
   - **避免两者同时修改同一 @Published 状态**

### 正确的动画同步架构

```swift
// 原则：单一数据源控制动画状态

// ❌ 错误做法：多处修改 animatingNotchSize
// ContentView.doOpen: vm.animatingNotchSize = closedSize
// ViewModel.open: animatingNotchSize = targetSize
// AppDelegate: animatingNotchSize = targetSize

// ✅ 正确做法：AppDelegate 完全控制 animatingNotchSize
// ViewModel.open(): 只设置 notchState，发送通知（一次）
// AppDelegate: 收到通知 → 设置 animatingNotchSize → 启动动画

func open() {
    self.notchState = .open  // SwiftUI frame 触发变化
    NotificationCenter.default.post(name: .notchWillOpen, ...)  // 只发送一次
}

// AppDelegate:
NotificationCenter.default.addObserver(forName: .notchWillOpen, ...) {
    vm.animatingNotchSize = targetSize  // AppDelegate 独占修改权
    NSAnimationContext.runAnimationGroup { ... }
}
```

### 调试清单

遇到动画/崩溃问题时，按此顺序检查：

1. **Console.app 日志** - 是否有重复调用？通知发送几次？
2. **NotificationCenter** - 是否重复注册监听？重复发送通知？
3. **@Published 状态** - 是否多处同时修改？
4. **线程冲突** - SwiftUI 和 AppKit 是否同时操作同一状态？
5. **单一修改** - 每次只改一处，逐步验证
