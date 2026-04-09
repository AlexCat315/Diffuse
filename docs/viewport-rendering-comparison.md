# Metal CAMetalLayer vs Qt RHI 方案对比

## 1. 方案 A: Metal CAMetalLayer + IOSurface

### 实现原理
```
引擎 (headless) 
  ↓ 每帧渲染到 IOSurface
IOSurface (GPU 共享内存)
  ↓ 
Qt ViewportWidget (Objective-C++）
  ↓
CAMetalLayer (Cocoa Metal 渲染层)
  ↓ Metal blit pass
屏幕显示
```

### 核心代码结构
```cpp
// ViewportWidget.h (Objective-C++)
class ViewportWidget : public QWidget {
    CAMetalLayer* metalLayer_;           // Cocoa layer
    id<MTLDevice> device_;               // Metal device  
    id<MTLCommandQueue> commandQueue_;   // Command queue
    IOSurfaceRef currentSurface_;        // Current IOSurface from engine
    
    void initializeMetalLayer();
    void renderFrame();                  // Blit IOSurface to screen
};
```

### 优点
✅ **性能最优** — 零拷贝，直接 GPU 操作
✅ **响应式** — 低延迟渲染
✅ **完全控制** — 可添加 UI overlay (ViewCube、gizmo 提示)
✅ **最简单的窗口嵌入** — 不需要子窗口，直接渲染到 QWidget

### 缺点
❌ **macOS only** — 其他平台需要重新实现（Vulkan for Linux, DX12 for Windows）
❌ **Objective-C++** — 混合语言，编译复杂
❌ **Metal API 学习曲线** — 需要深入 Metal 知识
❌ **IOSurface 同步** — 需要仔细处理 CPU/GPU 屏障

### 时间估计
- 基础 Metal 设备初始化: 1h
- CAMetalLayer 集成: 1h  
- IOSurface blit 实现: 1.5h
- 输入同步、同步原语: 1h
**总计: 4.5 小时**

---

## 2. 方案 B: Qt RHI (Rendering Hardware Interface)

### 实现原理
```
引擎 (headless) 
  ↓ 每帧渲染到 IOSurface
IOSurface (跨平台共享)
  ↓
Qt RHI (QRhiWidget / QRhiSwapChain)
  ↓ RHI Metal/Vulkan/DX12 backend
编译为 Metal (macOS) / Vulkan (Linux) / DX12 (Windows)
  ↓ 自动跨平台驱动管理
屏幕显示
```

### 核心代码结构
```cpp
// ViewportWidget.h (C++ only)
class ViewportWidget : public QRhiWidget {
    QRhi* rhi_;                      // RHI 实例（自动选择后端）
    QRhiTexture* surfaceTexture_;    // IOSurface 绑定为纹理
    QRhiRenderPassDescriptor* rpDesc_;
    
    void render(QRhiCommandBuffer* cb) override;  // RHI render pass
    void initResources() override;
    void releaseResources() override;
};
```

### 优点  
✅ **跨平台** — 一套代码支持 macOS/Linux/Windows
✅ **解耦** — 独立于具体 GPU API，可以切换后端
✅ **Qt 官方支持** — Qt 6.8+ 成熟特性
✅ **纯 C++** — 无 Objective-C++ 复杂性
✅ **同步管理** — Qt 内在处理 GPU 屏障
✅ **集成 UI overlay** — QRhiWidget 可以混合 2D/3D

### 缺点
❌ **抽象开销** — 可能比直接 Metal 慢 5-10%
❌ **学习复杂** — QRhi API 曲线陡峭
❌ **Linux/Windows 未测** — IOSurface 在其他平台实现不同
  - Linux: DMA-BUF 或 DMABUF
  - Windows: HANDLE/D3D12 texture sharing
❌ **纹理导入复杂** — 跨 API 做 IOSurface → 纹理映射不直观

### 时间估计
- QRhiWidget 基类实现: 1h
- Metal backend IOSurface 纹理导入: 2h
- Render pass 设置: 1.5h
- 跨平台同步（需要 Vulkan/DX12）: 2-4h（可延后）
**总计 (macOS): 4.5h | 全平台: 7-9h**

---

## 3. 详细对比表

| 维度 | Metal CAMetalLayer | Qt RHI |
|------|-------------------|--------|
| **平台支持** | macOS 🍎 | macOS 🍎 Linux 🐧 Windows 🪟 |
| **性能** | ⭐⭐⭐⭐⭐ (~60 FPS @ 4K) | ⭐⭐⭐⭐ (~55-58 FPS @ 4K) |
| **开发速度** | 中等 (需 Obj-C++) | 较慢 (需学 QRhi) |
| **维护成本** | 低 (单平台) | 中等 (跨平台同步) |
| **代码覆盖** | macOS: 100% | macOS: 80% Linux: 60% Windows: TBD |
| **UI 叠加** | 原生 CALayer | QRhi shader overlay |
| **IOSurface 处理** | 直接 Metal IOSurface API | 需要 Qt 扩展 |
| **输入延迟** | <1ms | <2ms |
| **调试** | Xcode Instruments | RenderDoc (Vulkan) / PIX (DX12) |
| **第三方库** | Metal.framework (系统) | Qt 6 RHI (已包含) |

---

## 4. 技术细节对比

### IOSurface 集成

**方案 A (Metal):**
```objc
// 直接用 IOSurface ID 创建 MTLTexture
IOSurfaceRef surface = IOSurfaceLookupFromID(surfaceId);
MTLTextureDescriptor* desc = [MTLTextureDescriptor...];
id<MTLTexture> ioSurfaceTexture = 
    [device newTextureWithDescriptor:desc ioSurface:surface plane:0];
```

**方案 B (RHI):**
```cpp
// Qt RHI 需要自定义实现（macOS）
// 或等待 Qt 6.9+ 官方 IOSurface 支持
QRhiTexture* tex = rhi->newTexture(QRhiTexture::BGRA8, size);
// 手工映射 IOSurface（复杂）
```

---

## 5. 推荐策略

### 短期 (Phase 1 MVP — 本周)
**选择: Metal CAMetalLayer** ✅
- 目标是快速获得工作的 viewport
- Guava 当前只面向 macOS
- RHI 学习曲线会延迟交付

### 中期 (Phase 3-4 — 下月)
**添加: Qt RHI 支持** (可选)
- 如果团队决定支持 Windows/Linux
- 并行维护两套实现，逐步迁移到 RHI

### 长期 (Phase 5+ — 2+月后)
**统一: 完全 RHI** (可能)
- 移除 Objective-C++ 代码
- 所有平台统一接口
- 如果 Qt 发布官方 IOSurface 支持

---

## 6. 采纳建议

根据 Guava 当前状态：
- ✅ 项目初期，功能优于性能
- ✅ macOS 用户群体明确
- ✅ 团队规模小，维护单平台更现实
- ✅ 引擎已提供完整 IOSurface API

**结论: 先实现 Metal CAMetalLayer，后期可过渡到 Qt RHI。**
