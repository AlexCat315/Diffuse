// ---------------------------------------------------------------------------
// ScriptExports.cs — HelloWorld 项目的导出桩
//
// 复制自 GuavaEngine/ScriptExports.cs，仅修改 CreateScript() 返回值。
// ---------------------------------------------------------------------------

using System;
using System.Runtime.InteropServices;
using Guava;
using Guava.Exports;

namespace HelloWorldExports
{
    public static unsafe class ScriptExports
    {
        private static GuavaScript? s_instance;

        [UnmanagedCallersOnly(EntryPoint = "guava_api_version")]
        public static uint ApiVersion() => 2;

        [UnmanagedCallersOnly(EntryPoint = "guava_bind")]
        public static void Bind(HostApi* api, nint context, ulong entityId)
        {
            Engine.Bind(api, context, entityId);
        }

        [UnmanagedCallersOnly(EntryPoint = "guava_create_instance")]
        public static nint CreateInstance(HostApi* api, nint context, ulong entityId)
        {
            Engine.Bind(api, context, entityId);
            s_instance = new HelloWorld();
            var handle = GCHandle.Alloc(s_instance);
            return GCHandle.ToIntPtr(handle);
        }

        [UnmanagedCallersOnly(EntryPoint = "guava_destroy_instance")]
        public static void DestroyInstance(nint instancePtr)
        {
            if (instancePtr == nint.Zero) return;
            var handle = GCHandle.FromIntPtr(instancePtr);
            handle.Free();
            s_instance = null;
        }

        [UnmanagedCallersOnly(EntryPoint = "guava_on_init")]
        public static void OnInit(nint instancePtr)
        {
            if (instancePtr == nint.Zero) return;
            var handle = GCHandle.FromIntPtr(instancePtr);
            (handle.Target as GuavaScript)?.OnInit();
        }

        [UnmanagedCallersOnly(EntryPoint = "guava_on_update")]
        public static void OnUpdate(nint instancePtr, float deltaTime)
        {
            if (instancePtr == nint.Zero) return;
            var handle = GCHandle.FromIntPtr(instancePtr);
            (handle.Target as GuavaScript)?.OnUpdate(deltaTime);
        }

        [UnmanagedCallersOnly(EntryPoint = "guava_on_destroy")]
        public static void OnDestroy(nint instancePtr)
        {
            if (instancePtr == nint.Zero) return;
            var handle = GCHandle.FromIntPtr(instancePtr);
            (handle.Target as GuavaScript)?.OnDestroy();
        }
    }
}
