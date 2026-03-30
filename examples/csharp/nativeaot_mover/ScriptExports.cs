using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

[assembly: DisableRuntimeMarshalling]

namespace GuavaNativeAotMover;

public static unsafe class ScriptExports
{
    private const uint ApiVersion = 1;

    public struct HostApi
    {
        public delegate* unmanaged[Cdecl]<nint, byte*, nuint, void> Log;
        public delegate* unmanaged[Cdecl]<nint, byte*, nuint, ulong> FindEntityByName;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, uint> GetPosition;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, uint> SetPosition;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, float*, uint> GetRotation;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, float, uint> SetRotation;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, float*, uint> GetScale;
        public delegate* unmanaged[Cdecl]<nint, float, float, float, uint> SetScale;
        public delegate* unmanaged[Cdecl]<nint, uint, uint> IsKeyDown;
        public delegate* unmanaged[Cdecl]<nint, uint, uint> WasKeyPressed;
        public delegate* unmanaged[Cdecl]<nint, float*, float*, uint> GetMousePosition;
        public delegate* unmanaged[Cdecl]<nint, float> GetDeltaTime;
        public delegate* unmanaged[Cdecl]<nint, float> GetTimeScale;
        public delegate* unmanaged[Cdecl]<nint, uint> GetGameState;
    }

    private struct ScriptState
    {
        public HostApi* Host;
        public nint UserData;
        public ulong EntityId;
        public float Speed;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_api_version")]
    public static uint GetApiVersion() => ApiVersion;

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_create_instance")]
    public static nint CreateInstance(HostApi* host, nint userData, ulong entityId)
    {
        ScriptState* state = (ScriptState*)NativeMemory.AllocZeroed((nuint)sizeof(ScriptState));
        state->Host = host;
        state->UserData = userData;
        state->EntityId = entityId;
        state->Speed = 2.0f;
        Log(state, "nativeaot csharp instance created");
        return (nint)state;
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_destroy_instance")]
    public static void DestroyInstance(nint instance)
    {
        if (instance == nint.Zero)
        {
            return;
        }

        ScriptState* state = (ScriptState*)instance;
        Log(state, "nativeaot csharp instance destroyed");
        NativeMemory.Free(state);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_on_init")]
    public static void OnInit(nint instance)
    {
        if (instance == nint.Zero)
        {
            return;
        }

        ScriptState* state = (ScriptState*)instance;
        Log(state, "nativeaot csharp init");
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_on_update")]
    public static void OnUpdate(nint instance, float dt)
    {
        if (instance == nint.Zero)
        {
            return;
        }

        ScriptState* state = (ScriptState*)instance;

        float x = 0;
        float y = 0;
        float z = 0;
        if (state->Host->GetPosition(state->UserData, &x, &y, &z) == 0)
        {
            return;
        }

        _ = state->Host->SetPosition(state->UserData, x + (dt * state->Speed), y, z);
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) }, EntryPoint = "guava_csharp_on_destroy")]
    public static void OnDestroy(nint instance)
    {
        if (instance == nint.Zero)
        {
            return;
        }

        ScriptState* state = (ScriptState*)instance;
        Log(state, "nativeaot csharp destroy");
    }

    private static void Log(ScriptState* state, string message)
    {
        if (state == null || state->Host == null)
        {
            return;
        }

        byte[] utf8 = Encoding.UTF8.GetBytes(message);
        fixed (byte* ptr = utf8)
        {
            state->Host->Log(state->UserData, ptr, (nuint)utf8.Length);
        }
    }
}
