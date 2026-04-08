// ---------------------------------------------------------------------------
// GuavaEngine.cs — Guava 引擎 C# NativeAOT SDK 核心绑定
//
// 此文件通过函数指针表（HostApi）调用引擎原生功能。
// NativeAOT 编译后生成 .dylib/.so/.dll，引擎通过 dlopen 加载。
// ---------------------------------------------------------------------------

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Guava
{
    /// <summary>
    /// 引擎 Host API 函数指针表 — 由引擎在 guava_bind() 时传入。
    /// 字段顺序必须与 Zig CSharpNativeAotHostApi extern struct 完全一致。
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct HostApi
    {
        // ─── Logging ──────────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, byte*, nuint, void> Log;

        // ─── Entity ───────────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, byte*, nuint, ulong> FindEntityByName;

        // ─── Transform ────────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, uint> GetPosition;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, uint> SetPosition;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, float*, uint> GetRotation;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, uint> SetRotation;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, uint> GetScale;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, uint> SetScale;

        // ─── Input ────────────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, uint, uint> IsKeyDown;
        public delegate* unmanaged[Cdecl]<nint, uint, uint> WasKeyPressed;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, uint> GetMousePosition;

        // ─── Time ─────────────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, float> GetDeltaTime;
        public delegate* unmanaged[Cdecl]<nint, float> GetTimeScale;
        public delegate* unmanaged[Cdecl]<nint, uint> GetGameState;

        // ─── Canvas / UI ──────────────────────────────────────────
        public delegate* unmanaged[Cdecl]<nint, void> CanvasClear;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, byte*, nuint, byte, byte, byte, byte, uint> CanvasAddText;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, byte, byte, byte, byte, uint> CanvasAddPanel;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, byte*, nuint, uint> CanvasAddButton;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, float, uint> CanvasAddProgressBar;
        public delegate* unmanaged[Cdecl]<nint, uint, byte*, nuint, void> CanvasSetText;
        public delegate* unmanaged[Cdecl]<nint, uint, float, void> CanvasSetProgress;
        public delegate* unmanaged[Cdecl]<nint, uint, uint, void> CanvasSetVisible;
        public delegate* unmanaged[Cdecl]<nint, uint, void> CanvasRemoveWidget;
        public delegate* unmanaged[Cdecl]<nint, uint, uint> CanvasWasButtonClicked;
    }

    /// <summary>
    /// 全局引擎上下文 — guava_bind() 初始化，所有 API 入口。
    /// </summary>
    public static unsafe class Engine
    {
        internal static HostApi* Api;
        internal static nint Context;
        internal static ulong EntityId;

        internal static void Bind(HostApi* api, nint context, ulong entityId)
        {
            Api = api;
            Context = context;
            EntityId = entityId;
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    // 高层封装
    // ═══════════════════════════════════════════════════════════════════════

    /// <summary>日志输出到引擎控制台。</summary>
    public static unsafe class Log
    {
        public static void Info(string message)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(message);
            fixed (byte* ptr = bytes)
            {
                Engine.Api->Log(Engine.Context, ptr, (nuint)bytes.Length);
            }
        }
    }

    /// <summary>Transform 操作。</summary>
    public static unsafe class Transform
    {
        public static Vector3 GetPosition()
        {
            float x, y, z;
            Engine.Api->GetPosition(Engine.Context, &x, &y, &z);
            return new Vector3(x, y, z);
        }

        public static void SetPosition(Vector3 pos)
        {
            Engine.Api->SetPosition(Engine.Context, pos.X, pos.Y, pos.Z);
        }

        public static void SetPosition(float x, float y, float z)
        {
            Engine.Api->SetPosition(Engine.Context, x, y, z);
        }

        public static Quaternion GetRotation()
        {
            float x, y, z, w;
            Engine.Api->GetRotation(Engine.Context, &x, &y, &z, &w);
            return new Quaternion(x, y, z, w);
        }

        public static void SetRotation(Quaternion rot)
        {
            Engine.Api->SetRotation(Engine.Context, rot.X, rot.Y, rot.Z, rot.W);
        }

        public static Vector3 GetScale()
        {
            float x, y, z;
            Engine.Api->GetScale(Engine.Context, &x, &y, &z);
            return new Vector3(x, y, z);
        }

        public static void SetScale(Vector3 scale)
        {
            Engine.Api->SetScale(Engine.Context, scale.X, scale.Y, scale.Z);
        }
    }

    /// <summary>输入查询。</summary>
    public static unsafe class Input
    {
        public static bool IsKeyDown(KeyCode key) => Engine.Api->IsKeyDown(Engine.Context, (uint)key) != 0;
        public static bool WasKeyPressed(KeyCode key) => Engine.Api->WasKeyPressed(Engine.Context, (uint)key) != 0;

        public static Vector2 GetMousePosition()
        {
            float x, y;
            Engine.Api->GetMousePosition(Engine.Context, &x, &y);
            return new Vector2(x, y);
        }
    }

    /// <summary>时间查询。</summary>
    public static unsafe class Time
    {
        public static float DeltaTime => Engine.Api->GetDeltaTime(Engine.Context);
        public static float TimeScale => Engine.Api->GetTimeScale(Engine.Context);
        public static uint GameState => Engine.Api->GetGameState(Engine.Context);
    }

    /// <summary>实体查询。</summary>
    public static unsafe class Entity
    {
        public static ulong FindByName(string name)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(name);
            fixed (byte* ptr = bytes)
            {
                return Engine.Api->FindEntityByName(Engine.Context, ptr, (nuint)bytes.Length);
            }
        }
    }
}
