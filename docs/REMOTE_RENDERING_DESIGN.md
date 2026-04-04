# H264 VideoToolbox + WebCodecs 远程渲染架构设计

## 概述

实现从 Metal 引擎到浏览器的硬件加速 H264 视频流管线，利用 macOS VideoToolbox 硬件编码和浏览器 WebCodecs VideoDecoder API 实现低延迟远程渲染。

### 核心像素管线

```
┌─────────────┐    ┌──────────────────┐    ┌──────────────────┐    ┌────────────────┐    ┌───────────────┐
│ Metal 渲染  │───▶│ IOSurface (共享) │───▶│ VideoToolbox     │───▶│ WebSocket      │───▶│ WebCodecs     │
│ color_tex   │    │ BGRA8 纹理       │    │ VTCompress H264  │    │ Binary Frame   │    │ VideoDecoder  │
└─────────────┘    └──────────────────┘    └──────────────────┘    └────────────────┘    └───────┬───────┘
                                                                                                 │
                                         ┌──────────────────┐                                    │
                                         │ <canvas>         │◀───────────────────────────────────┘
                                         │ drawImage(frame) │        VideoFrame
                                         └──────────────────┘
```

### 关键创新：零拷贝编码路径

VideoToolbox 可以直接从 IOSurface 创建 CVPixelBuffer，**完全避免 GPU→CPU 数据回读**：

```
IOSurface ──CVPixelBufferCreateWithIOSurface──▶ CVPixelBuffer ──VTCompressionSession──▶ H264 NALUs
         零拷贝，硬件编码器直接访问 GPU 显存
```

这比当前的 `downloadFramePixelsAlloc()` 路径（staging buffer + waitUntilCompleted + memcpy）效率高一个数量级。

---

## 1. 引擎侧：VideoToolbox 编码器

### 1.1 Metal Bridge 新增 (`metal_rhi_bridge.mm`)

```objc
// ── VideoToolbox 编码器上下文 ──────────────────────────────────
#import <VideoToolbox/VideoToolbox.h>
#import <CoreVideo/CVPixelBuffer.h>

struct GuavaH264Encoder {
    VTCompressionSessionRef session = nullptr;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t target_fps = 60;
    uint32_t bitrate_kbps = 8000;     // 8 Mbps 默认
    bool realtime = true;
    uint32_t keyframe_interval = 60;  // 每 60 帧一个关键帧
    
    // NAL 输出环形缓冲区（编码器回调写入，主线程读取）
    struct EncodedFrame {
        uint8_t* data;        // H264 Annex-B NALUs
        uint32_t size;
        uint64_t timestamp;   // presentation timestamp (微秒)
        bool key_frame;
    };
    
    static constexpr uint32_t MAX_PENDING = 8;
    EncodedFrame pending[MAX_PENDING];
    std::atomic<uint32_t> write_idx{0};
    std::atomic<uint32_t> read_idx{0};
    std::mutex drain_mutex;
};
```

#### C API 接口声明 (`metal_rhi_bridge.h`)

```c
// ── H264 编码器 API ────────────────────────────────────────────
void* guava_h264_encoder_create(
    uint32_t width, uint32_t height,
    uint32_t fps, uint32_t bitrate_kbps,
    uint32_t keyframe_interval
);
void  guava_h264_encoder_destroy(void* encoder);

// 从 IOSurface 直接编码一帧（零拷贝）
bool  guava_h264_encoder_encode_iosurface(
    void* encoder,
    void* iosurface_ref,      // IOSurfaceRef
    uint64_t timestamp_us     // presentation timestamp
);

// 排出编码后的帧数据
// 返回帧数量，调用者负责释放 out_data
uint32_t guava_h264_encoder_drain(
    void* encoder,
    uint8_t** out_data,       // [out] NAL 数据指针数组
    uint32_t* out_sizes,      // [out] 每帧字节数
    uint64_t* out_timestamps, // [out] presentation timestamps
    bool* out_keyframes,      // [out] 是否关键帧
    uint32_t max_frames
);

void guava_h264_encoder_free_frame(uint8_t* data);

// 动态调整编码参数
void guava_h264_encoder_set_bitrate(void* encoder, uint32_t bitrate_kbps);
void guava_h264_encoder_force_keyframe(void* encoder);

// 获取 SPS/PPS 供解码器初始化
bool guava_h264_encoder_get_params(
    void* encoder,
    uint8_t* out_sps, uint32_t* sps_size,
    uint8_t* out_pps, uint32_t* pps_size
);
```

#### 核心实现

```objc
// ── 编码器创建 ────────────────────────────────────────────────
void* guava_h264_encoder_create(
    uint32_t width, uint32_t height,
    uint32_t fps, uint32_t bitrate_kbps,
    uint32_t keyframe_interval)
{
    auto* enc = new GuavaH264Encoder();
    enc->width = width;
    enc->height = height;
    enc->target_fps = fps;
    enc->bitrate_kbps = bitrate_kbps;
    enc->keyframe_interval = keyframe_interval;
    
    // 像素缓冲属性 — 匹配 IOSurface 的 BGRA 格式
    NSDictionary* pixelAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},  // 允许 IOSurface 支持
    };
    
    VTCompressionSessionRef session;
    OSStatus status = VTCompressionSessionCreate(
        kCFAllocatorDefault,
        width, height,
        kCMVideoCodecType_H264,
        (__bridge CFDictionaryRef)@{
            // 强制硬件编码器
            (id)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: @YES,
            (id)kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: @YES,
        },
        (__bridge CFDictionaryRef)pixelAttrs,
        kCFAllocatorDefault,
        &compressionCallback,    // NAL 输出回调
        enc,                     // refcon → encoder context
        &session
    );
    
    if (status != noErr) {
        fprintf(stderr, "[H264] VTCompressionSessionCreate failed: %d\n", (int)status);
        delete enc;
        return nullptr;
    }
    
    // 配置编码参数
    VTSessionSetProperty(session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Main_AutoLevel);
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AllowFrameReordering,
                         kCFBooleanFalse);  // 禁用 B 帧 → 最低延迟
    
    // 码率控制
    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberIntType,
                                            &(int){bitrate_kbps * 1000});
    VTSessionSetProperty(session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);
    
    // 关键帧间隔
    CFNumberRef keyRef = CFNumberCreate(NULL, kCFNumberIntType, &(int){keyframe_interval});
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxKeyFrameInterval, keyRef);
    CFRelease(keyRef);
    
    // 最大帧延迟 = 0（编码完立即输出）
    VTSessionSetProperty(session, kVTCompressionPropertyKey_MaxFrameDelayCount,
                         (__bridge CFTypeRef)@0);
    
    VTCompressionSessionPrepareToEncodeFrames(session);
    enc->session = session;
    return enc;
}

// ── 编码回调（VideoToolbox 编码完成时调用） ────────────────────
static void compressionCallback(
    void* outputCallbackRefCon,
    void* sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CMSampleBufferRef sampleBuffer)
{
    if (status != noErr || !sampleBuffer) return;
    
    auto* enc = static_cast<GuavaH264Encoder*>(outputCallbackRefCon);
    
    // 检测关键帧
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    bool isKeyFrame = true;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync;
        if (CFDictionaryGetValueIfPresent(dict, kCMSampleAttachmentKey_NotSync, (const void**)&notSync)) {
            isKeyFrame = !CFBooleanGetValue(notSync);
        }
    }
    
    // 提取 H264 NAL 数据 (Annex-B 格式：00 00 00 01 + NAL)
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    size_t totalLen = 0;
    char* dataPtr = nullptr;
    CMBlockBufferGetDataPointer(blockBuffer, 0, nullptr, &totalLen, &dataPtr);
    
    // AVCC → Annex-B 转换
    // AVCC 格式: [4-byte length][NAL unit] ...
    // Annex-B:   [00 00 00 01][NAL unit] ...
    uint8_t* annexB = (uint8_t*)malloc(totalLen + 64); // 预留 SPS/PPS 空间
    uint32_t annexB_len = 0;
    
    // 关键帧前插入 SPS/PPS
    if (isKeyFrame) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        size_t spsSize, ppsSize;
        const uint8_t* spsData;
        const uint8_t* ppsData;
        size_t paramCount;
        
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 0, &spsData, &spsSize, &paramCount, nullptr);
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 0;
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 1;
        memcpy(annexB + annexB_len, spsData, spsSize);
        annexB_len += spsSize;
        
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, 1, &ppsData, &ppsSize, nullptr, nullptr);
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 0;
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 1;
        memcpy(annexB + annexB_len, ppsData, ppsSize);
        annexB_len += ppsSize;
    }
    
    // 转换 AVCC NAL units → Annex-B
    size_t offset = 0;
    while (offset < totalLen) {
        uint32_t nalLen = 0;
        memcpy(&nalLen, dataPtr + offset, 4);
        nalLen = CFSwapInt32BigToHost(nalLen);
        offset += 4;
        
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 0;
        annexB[annexB_len++] = 0; annexB[annexB_len++] = 1;
        memcpy(annexB + annexB_len, dataPtr + offset, nalLen);
        annexB_len += nalLen;
        offset += nalLen;
    }
    
    // 写入环形缓冲区
    uint32_t wi = enc->write_idx.load(std::memory_order_relaxed);
    uint32_t ri = enc->read_idx.load(std::memory_order_acquire);
    uint32_t next_wi = (wi + 1) % GuavaH264Encoder::MAX_PENDING;
    
    if (next_wi == ri) {
        // 缓冲区满 — 丢弃最旧帧
        free(annexB);
        return;
    }
    
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    uint64_t timestamp_us = (uint64_t)(CMTimeGetSeconds(pts) * 1000000.0);
    
    enc->pending[wi] = {
        .data = annexB,
        .size = annexB_len,
        .timestamp = timestamp_us,
        .key_frame = isKeyFrame,
    };
    enc->write_idx.store(next_wi, std::memory_order_release);
}

// ── 零拷贝编码：IOSurface → H264 ──────────────────────────────
bool guava_h264_encoder_encode_iosurface(
    void* encoder_ptr,
    void* iosurface_ref,
    uint64_t timestamp_us)
{
    auto* enc = static_cast<GuavaH264Encoder*>(encoder_ptr);
    IOSurfaceRef surface = (IOSurfaceRef)iosurface_ref;
    
    // 从 IOSurface 创建 CVPixelBuffer（零拷贝，共享底层显存）
    CVPixelBufferRef pixelBuffer = nullptr;
    CVReturn cvRet = CVPixelBufferCreateWithIOSurface(
        kCFAllocatorDefault,
        surface,
        nullptr,    // pixelBufferAttributes (nil = 继承 IOSurface 属性)
        &pixelBuffer
    );
    
    if (cvRet != kCVReturnSuccess || !pixelBuffer) {
        fprintf(stderr, "[H264] CVPixelBufferCreateWithIOSurface failed: %d\n", cvRet);
        return false;
    }
    
    // 提交给 VideoToolbox
    CMTime pts = CMTimeMake(timestamp_us, 1000000); // 微秒精度
    
    OSStatus status = VTCompressionSessionEncodeFrame(
        enc->session,
        pixelBuffer,
        pts,
        kCMTimeInvalid,  // duration — 不指定
        nullptr,         // frameProperties — 不强制关键帧
        nullptr,         // sourceFrameRefCon
        nullptr          // infoFlagsOut
    );
    
    CVPixelBufferRelease(pixelBuffer);
    
    return status == noErr;
}

// ── 排出编码帧 ────────────────────────────────────────────────
uint32_t guava_h264_encoder_drain(
    void* encoder_ptr,
    uint8_t** out_data,
    uint32_t* out_sizes,
    uint64_t* out_timestamps,
    bool* out_keyframes,
    uint32_t max_frames)
{
    auto* enc = static_cast<GuavaH264Encoder*>(encoder_ptr);
    uint32_t count = 0;
    
    while (count < max_frames) {
        uint32_t ri = enc->read_idx.load(std::memory_order_relaxed);
        uint32_t wi = enc->write_idx.load(std::memory_order_acquire);
        if (ri == wi) break; // 空
        
        auto& frame = enc->pending[ri];
        out_data[count] = frame.data;
        out_sizes[count] = frame.size;
        out_timestamps[count] = frame.timestamp;
        out_keyframes[count] = frame.key_frame;
        count++;
        
        enc->read_idx.store((ri + 1) % GuavaH264Encoder::MAX_PENDING, std::memory_order_release);
    }
    
    return count;
}
```

### 1.2 Zig 绑定层

#### `packages/engine/src/engine/rhi/metal/metal_device.zig` 新增

```zig
// ── H264 硬件编码器绑定 ──────────────────────────────────────
const H264Encoder = opaque {};

extern fn guava_h264_encoder_create(w: u32, h: u32, fps: u32, kbps: u32, kf: u32) ?*H264Encoder;
extern fn guava_h264_encoder_destroy(enc: *H264Encoder) void;
extern fn guava_h264_encoder_encode_iosurface(enc: *H264Encoder, surface: *anyopaque, ts: u64) bool;
extern fn guava_h264_encoder_drain(
    enc: *H264Encoder,
    out_data: [*]*u8,
    out_sizes: [*]u32,
    out_ts: [*]u64,
    out_kf: [*]bool,
    max: u32,
) u32;
extern fn guava_h264_encoder_free_frame(data: *u8) void;
extern fn guava_h264_encoder_force_keyframe(enc: *H264Encoder) void;
extern fn guava_h264_encoder_set_bitrate(enc: *H264Encoder, kbps: u32) void;
```

#### `packages/engine/src/engine/rhi/device.zig` 抽象接口新增

```zig
pub const EncodedFrame = struct {
    data: []const u8,   // H264 Annex-B NAL units
    timestamp: u64,     // presentation timestamp (μs)
    key_frame: bool,
};

/// 获取纹理关联的 IOSurface 引用（仅 Metal + IOSurface 纹理有效）
pub fn getIOSurfaceRef(self: *RhiDevice, texture_id: u32) ?*anyopaque {
    return switch (self.backend) {
        .metal => |md| md.getIOSurfaceRef(texture_id),
        else => null,
    };
}
```

---

## 2. WebSocket 二进制帧支持

### 2.1 `websocket.zig` 新增 `writeBinaryFrame()`

```zig
/// Write a WebSocket binary frame to the stream.
/// Server frames are never masked per RFC 6455.
pub fn writeBinaryFrame(stream: std.net.Stream, payload: []const u8) !void {
    var header_buf: [10]u8 = undefined;
    var header_len: usize = 2;
    header_buf[0] = 0x82; // FIN + binary opcode (0x2)

    if (payload.len < 126) {
        header_buf[1] = @intCast(payload.len);
    } else if (payload.len <= 65535) {
        header_buf[1] = 126;
        std.mem.writeInt(u16, header_buf[2..4], @intCast(payload.len), .big);
        header_len = 4;
    } else {
        header_buf[1] = 127;
        std.mem.writeInt(u64, header_buf[2..10], @intCast(payload.len), .big);
        header_len = 10;
    }

    try streamWriteAll(stream, header_buf[0..header_len]);
    if (payload.len > 0) {
        try streamWriteAll(stream, payload);
    }
}
```

### 2.2 服务器发送管线扩展 (`server.zig`)

```zig
const OutgoingMessage = struct {
    client_id: u32,
    payload: []u8,
    binary: bool,      // ← 新增：true = binary frame, false = text frame

    fn deinit(self: *OutgoingMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

/// 入队二进制消息（用于 H264 帧）
pub fn enqueueBinaryBroadcast(self: *Server, payload: []u8) void {
    self.outgoing_mutex.lock();
    defer self.outgoing_mutex.unlock();
    self.outgoing.append(self.allocator, .{
        .client_id = 0,
        .payload = payload,
        .binary = true,
    }) catch {
        self.allocator.free(payload);
    };
}
```

`flushOutgoing()` 修改：根据 `msg.binary` 选择 `writeBinaryFrame` 或 `writeTextFrame`：

```zig
if (msg.binary) {
    ws.writeBinaryFrame(client.stream, msg.payload) catch {};
} else {
    ws.writeTextFrame(client.stream, msg.payload) catch {};
}
```

---

## 3. 二进制帧协议

### 帧头格式（16 字节）

WebSocket binary frame 的前 16 字节为帧头，其余为 H264 Annex-B 数据：

```
Offset  Size  Field              Description
──────  ────  ─────────────────  ────────────────────────────────────
0       4     magic              0x47564832 ("GVH2" — Guava H264 v2)
4       4     payload_size       H264 数据字节数（不含帧头）
8       8     timestamp          presentation timestamp (μs, little-endian)
16      1     flags              bit 0: key_frame
                                 bit 1: config_change (SPS/PPS 在数据中)
                                 bit 2-7: reserved
17      1     reserved           填充
18      2     width              帧宽度
20      2     height             帧高度
22      2     reserved           对齐到 24 字节
──────────────────────────────────────────────────────────────────────
24+     N     h264_data          Annex-B NAL units (00 00 00 01 + NAL)
```

总大小：24 字节帧头 + H264 payload

### Zig 编码端

```zig
const StreamFrameHeader = extern struct {
    magic: u32 = 0x47564832,
    payload_size: u32,
    timestamp: u64,
    flags: u8,
    reserved1: u8 = 0,
    width: u16,
    height: u16,
    reserved2: u16 = 0,
};

fn buildStreamFrame(allocator: std.mem.Allocator, frame: EncodedFrame, w: u16, h: u16) ![]u8 {
    const total = @sizeOf(StreamFrameHeader) + frame.data.len;
    const buf = try allocator.alloc(u8, total);

    const header = @as(*StreamFrameHeader, @ptrCast(@alignCast(buf.ptr)));
    header.* = .{
        .payload_size = @intCast(frame.data.len),
        .timestamp = frame.timestamp,
        .flags = if (frame.key_frame) 0x01 else 0x00,
        .width = w,
        .height = h,
    };

    @memcpy(buf[@sizeOf(StreamFrameHeader)..], frame.data);
    return buf;
}
```

---

## 4. 流控制 RPC 方法

### 4.1 新增 RPC 方法定义

**引擎侧 handler (`handlers/viewport.zig`)**：

```zig
// viewport.startStreaming
pub fn startStreaming(ctx: *HandlerContext, params: struct {
    bitrate_kbps: ?u32 = null,    // 默认 8000
    fps: ?u32 = null,              // 默认 60
    keyframe_interval: ?u32 = null, // 默认 60
}) !void {
    const renderer = ctx.layer_context.renderer;
    renderer.pending_start_streaming = .{
        .bitrate_kbps = params.bitrate_kbps orelse 8000,
        .fps = params.fps orelse 60,
        .keyframe_interval = params.keyframe_interval orelse 60,
    };
}

// viewport.stopStreaming
pub fn stopStreaming(ctx: *HandlerContext, params: struct {}) !void {
    ctx.layer_context.renderer.pending_stop_streaming = true;
}

// viewport.setStreamBitrate — 实时调整码率
pub fn setStreamBitrate(ctx: *HandlerContext, params: struct {
    bitrate_kbps: u32,
}) !void {
    ctx.layer_context.renderer.pending_stream_bitrate = params.bitrate_kbps;
}
```

### 4.2 TypeScript 类型定义 (`rpc-types.ts`)

```typescript
// 新增方法
"viewport.startStreaming": {
  params: {
    bitrate_kbps?: number;   // 默认 8000
    fps?: number;            // 默认 60
    keyframe_interval?: number; // 默认 60
  };
  result: { codec: string; width: number; height: number };
};

"viewport.stopStreaming": {
  params: Record<string, never>;
  result: Record<string, never>;
};

"viewport.setStreamBitrate": {
  params: { bitrate_kbps: number };
  result: Record<string, never>;
};
```

---

## 5. 引擎主循环集成

### 5.1 编码调度 (`subscriptions.zig` 或独立模块)

在 `checkAndBroadcast()` 中每帧执行：

```zig
// ── H264 流式编码 ──────────────────────────────────────────────
if (server.h264_streaming) {
    const encoder = server.h264_encoder orelse continue;
    const renderer = layer_context.renderer;
    const viewport = &renderer.scene_viewport;
    
    // 1. 从 IOSurface 提交编码（零拷贝）
    if (viewport.iosurface_id != 0) {
        const surface_ref = renderer.rhi.getIOSurfaceRef(viewport.color_texture_id);
        if (surface_ref) |surface| {
            const timestamp = @as(u64, @intCast(server.frame_counter)) * 
                              (1_000_000 / encoder.target_fps);
            _ = encoder.encodeIOSurface(surface, timestamp);
        }
    }
    
    // 2. 排出编码完成的帧
    var frame_data: [4]*u8 = undefined;
    var frame_sizes: [4]u32 = undefined;
    var frame_ts: [4]u64 = undefined;
    var frame_kf: [4]bool = undefined;
    
    const count = encoder.drain(&frame_data, &frame_sizes, &frame_ts, &frame_kf, 4);
    
    for (0..count) |i| {
        // 3. 构建二进制帧 + WebSocket 广播
        const frame_buf = buildStreamFrame(server.allocator, .{
            .data = frame_data[i][0..frame_sizes[i]],
            .timestamp = frame_ts[i],
            .key_frame = frame_kf[i],
        }, @intCast(viewport.width), @intCast(viewport.height)) catch continue;
        
        server.enqueueBinaryBroadcast(frame_buf);
        
        // 4. 释放编码器分配的帧内存
        encoder.freeFrame(frame_data[i]);
    }
    
    server.frame_counter += 1;
}
```

### 5.2 流状态管理 (`server.zig`)

```zig
// Server struct 新增字段
h264_encoder: ?*H264Encoder = null,
h264_streaming: bool = false,
frame_counter: u64 = 0,
stream_config: ?StreamConfig = null,

const StreamConfig = struct {
    bitrate_kbps: u32,
    fps: u32,
    keyframe_interval: u32,
};

/// 在 processPending() 中消费 pending 流控制指令
fn handleStreamingState(self: *Server, renderer: *Renderer) void {
    // 开始流
    if (renderer.pending_start_streaming) |config| {
        renderer.pending_start_streaming = null;
        self.startH264Stream(config, renderer);
    }
    
    // 停止流
    if (renderer.pending_stop_streaming) {
        renderer.pending_stop_streaming = false;
        self.stopH264Stream();
    }
    
    // 调整码率
    if (renderer.pending_stream_bitrate) |kbps| {
        renderer.pending_stream_bitrate = null;
        if (self.h264_encoder) |enc| {
            enc.setBitrate(kbps);
        }
    }
}
```

---

## 6. 浏览器侧：WebCodecs 解码

### 6.1 `engine-client.ts` 二进制帧处理

```typescript
// handleMessage 修改
private handleMessage(data: WebSocket.Data): void {
    // 二进制帧 → H264 流数据
    if (data instanceof Buffer || data instanceof ArrayBuffer) {
        this.handleBinaryFrame(data instanceof Buffer ? data.buffer : data);
        return;
    }
    
    // 文本帧 → JSON-RPC（现有逻辑不变）
    let msg: JsonRpcResponse | JsonRpcNotification;
    try {
        msg = JSON.parse(data.toString());
    } catch {
        console.error("[EngineClient] Invalid JSON from engine");
        return;
    }
    // ... 现有 JSON 处理逻辑 ...
}

private handleBinaryFrame(buffer: ArrayBuffer): void {
    const view = new DataView(buffer);
    const magic = view.getUint32(0, true);
    
    if (magic !== 0x47564832) { // "GVH2"
        console.warn("[EngineClient] Unknown binary frame magic:", magic.toString(16));
        return;
    }
    
    // 转发到渲染进程
    this.binaryHandlers.forEach(handler => handler(buffer));
}

// 新增：二进制帧注册
private binaryHandlers = new Set<(data: ArrayBuffer) => void>();

onBinaryFrame(handler: (data: ArrayBuffer) => void): () => void {
    this.binaryHandlers.add(handler);
    return () => this.binaryHandlers.delete(handler);
}
```

### 6.2 主进程转发 (`main/index.ts`)

```typescript
// 注册二进制帧转发到渲染进程
engineClient.onBinaryFrame((buffer) => {
    // 通过 MessagePort 零拷贝传输（比 IPC 更高效）
    const { port1, port2 } = new MessageChannelMain();
    mainWindow.webContents.postMessage("viewport:h264-frame", null, [port2]);
    // 或者直接使用 SharedArrayBuffer 传递
    mainWindow.webContents.send("viewport:h264-frame", Buffer.from(buffer));
});
```

### 6.3 Viewport.tsx WebCodecs 集成

```tsx
// ── H264 解码器路径 ──────────────────────────────────────────
const FRAME_HEADER_SIZE = 24;
const MAGIC_GVH2 = 0x47564832;

interface StreamState {
    decoder: VideoDecoder | null;
    configured: boolean;
    canvas: OffscreenCanvas | null;
    ctx: CanvasRenderingContext2D | null;
    frameCount: number;
    lastKeyframe: number;
}

function useH264Stream(canvasRef: React.RefObject<HTMLCanvasElement>) {
    const streamRef = useRef<StreamState>({
        decoder: null, configured: false,
        canvas: null, ctx: null,
        frameCount: 0, lastKeyframe: 0,
    });
    
    useEffect(() => {
        const stream = streamRef.current;
        
        // 创建 VideoDecoder
        stream.decoder = new VideoDecoder({
            output: (frame: VideoFrame) => {
                // 直接绘制到 canvas
                const canvas = canvasRef.current;
                if (canvas) {
                    const ctx = canvas.getContext("2d");
                    ctx?.drawImage(frame, 0, 0, canvas.width, canvas.height);
                }
                frame.close(); // 必须释放
            },
            error: (e: DOMException) => {
                console.error("[H264] Decoder error:", e);
            },
        });
        
        // 监听 H264 帧
        const cleanup = window.electronAPI.onH264Frame((buffer: ArrayBuffer) => {
            const view = new DataView(buffer);
            const magic = view.getUint32(0, true);
            if (magic !== MAGIC_GVH2) return;
            
            const payloadSize = view.getUint32(4, true);
            const timestamp = Number(view.getBigUint64(8, true));
            const flags = view.getUint8(16);
            const width = view.getUint16(18, true);
            const height = view.getUint16(20, true);
            const isKeyFrame = (flags & 0x01) !== 0;
            
            const h264Data = new Uint8Array(buffer, FRAME_HEADER_SIZE, payloadSize);
            
            // 首次或分辨率变化时（重新）配置解码器
            if (!stream.configured || needsReconfigure(stream, width, height)) {
                stream.decoder!.configure({
                    codec: "avc1.4D0032", // Main Profile, Level 5.0
                    codedWidth: width,
                    codedHeight: height,
                    optimizeForLatency: true,
                });
                stream.configured = true;
            }
            
            // 调整 canvas 尺寸
            if (canvasRef.current) {
                canvasRef.current.width = width;
                canvasRef.current.height = height;
            }
            
            // 送入解码器
            const chunk = new EncodedVideoChunk({
                type: isKeyFrame ? "key" : "delta",
                timestamp: timestamp,
                data: h264Data,
            });
            
            stream.decoder!.decode(chunk);
            stream.frameCount++;
        });
        
        return () => {
            cleanup();
            stream.decoder?.close();
        };
    }, []);
}
```

---

## 7. 实现分期计划

### Phase 2a：WebSocket 二进制帧（1 天）

| 文件 | 变更 |
|------|------|
| `websocket.zig` | 新增 `writeBinaryFrame()` |
| `server.zig` | `OutgoingMessage` 添加 `binary` 字段；新增 `enqueueBinaryBroadcast()`；`flushOutgoing()` 区分文本/二进制 |
| `engine-client.ts` | `handleMessage()` 区分 Buffer/string；新增 `onBinaryFrame()` |

### Phase 2b：VideoToolbox 编码器（2-3 天）

| 文件 | 变更 |
|------|------|
| `metal_rhi_bridge.h` | H264 encoder C API 声明 |
| `metal_rhi_bridge.mm` | `GuavaH264Encoder` 实现：create/destroy/encode_iosurface/drain |
| `metal_device.zig` | extern fn 绑定 |
| `device.zig` | 抽象接口 `getIOSurfaceRef()` |

### Phase 2c：流控制 RPC + 主循环集成（1-2 天）

| 文件 | 变更 |
|------|------|
| `renderer.zig` | 新增 `pending_start_streaming`/`pending_stop_streaming`/`pending_stream_bitrate` |
| `handlers/viewport.zig` | `startStreaming`/`stopStreaming`/`setStreamBitrate` handlers |
| `server.zig` | `h264_encoder`/`h264_streaming` 字段；`handleStreamingState()` |
| `subscriptions.zig` | 每帧 encode + drain + broadcast |
| `rpc-types.ts` | 新增方法类型定义 |
| `dispatch.zig` | 注册新 RPC 方法 |

### Phase 2d：浏览器 WebCodecs 解码（1-2 天）

| 文件 | 变更 |
|------|------|
| `preload.ts` | 新增 `onH264Frame()` API |
| `main/index.ts` | 二进制帧从主进程转发到渲染进程 |
| `Viewport.tsx` | `useH264Stream` hook；三路切换：H264 / SAB / IPC |

---

## 8. 性能预期

| 指标 | 当前 SAB | H264 远程 |
|------|----------|-----------|
| 带宽（1080p@60fps） | ~500 MB/s（原始像素） | ~1-4 MB/s（H264 CBR 8Mbps）|
| 延迟 | ~1ms（共享内存） | ~5-15ms（编码+网络+解码）|
| 跨网络 | ❌ 同机器 | ✅ 任意网络 |
| CPU 开销 | ~0（memcpy only） | ~2-5%（硬件编码）|
| GPU 开销 | 0 | ~5-10%（Media Engine）|
| 画质 | 无损 | 近无损（高码率）/ 有损（低码率）|

### 自适应码率策略（可选后续优化）

```
if (client_rtt > 50ms || decode_queue_depth > 2) {
    降低码率至 50%
    降低帧率至 30fps
} else if (client_rtt < 10ms && decode_queue_depth == 0) {
    恢复默认码率和帧率
}
```

---

## 9. 模式切换逻辑

Viewport 组件支持三种渲染模式，按优先级自动选择：

```
1. SharedArrayBuffer（本地编辑器，最低延迟）
   条件：同进程，crossOriginIsolated，非远程

2. H264 流（远程渲染，最低带宽）
   条件：远程连接，或用户手动启用
   
3. IPC 像素推送（后备方案）
   条件：以上都不可用
```

```tsx
type ViewportMode = "sab" | "h264" | "ipc";

function detectViewportMode(): ViewportMode {
    if (isRemoteConnection()) return "h264";
    if (typeof SharedArrayBuffer !== "undefined" && crossOriginIsolated) return "sab";
    return "ipc";
}
```

---

## 10. 安全考虑

- **H264 帧验证**：解码前检查 magic number，防止恶意数据
- **码率限制**：服务端最大码率上限（如 50 Mbps），防止资源耗尽
- **帧大小限制**：复用 WebSocket 16MB 帧限制
- **WebCodecs 错误处理**：解码失败时回退到 IPC 模式
- **跨域隔离**：H264 路径不需要 `crossOriginIsolated`（不使用 SAB）
