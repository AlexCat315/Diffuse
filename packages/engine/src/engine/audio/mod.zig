//! 音频系统模块
//!
//! 集成 SoLoud 引擎，提供完整的音频播放、3D 空间音效、
//! 混音器控制和脚本接口。

pub const soloud_bindings = @import("./soloud_bindings.zig");
pub const runtime = @import("./runtime.zig");

pub const AudioRuntime = runtime.AudioRuntime;
pub const AudioClip = runtime.AudioClip;
pub const VoiceHandle = runtime.VoiceHandle;
pub const AudioClipHandle = runtime.AudioClipHandle;
pub const BusId = runtime.BusId;
pub const PlayState = runtime.PlayState;
pub const MixerStatus = runtime.MixerStatus;

// 再出口关键函数
pub const get = runtime.get;
