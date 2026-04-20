// ---------------------------------------------------------------------------
// ScriptExports.cs — NativeAOT 导出桩（每个项目需包含此文件）
//
// 用户需要修改 CreateScript() 方法返回自己的脚本类实例。
// 本文件通过 [UnmanagedCallersOnly] 导出 C ABI 函数供引擎 dlopen 调用。
// ---------------------------------------------------------------------------

using System;
using System.Runtime.InteropServices;

namespace Guava.Exports
{
    public static unsafe class ScriptExports
    {
        // 活跃脚本实例（单实例模型：一个 .dylib = 一个脚本类型）
        private static GuavaScript? s_instance;
        private static HostApi* s_api;
        private static nint s_context;
        private static ulong s_entityId;

        /// <summary>
        /// 返回 API 版本号，引擎用于兼容性校验。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_api_version")]
        public static uint ApiVersion() => 2;

        /// <summary>
        /// 引擎在加载 .dylib 后立即调用，传入 Host API 函数指针表。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_bind")]
        public static void Bind(HostApi* api, nint context, ulong entityId)
        {
            s_api = api;
            s_context = context;
            s_entityId = entityId;
            Engine.Bind(api, context, entityId);
        }

        /// <summary>
        /// 创建脚本实例。返回 GCHandle（作为不透明指针传回引擎）。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_create_instance")]
        public static nint CreateInstance(HostApi* api, nint context, ulong entityId)
        {
            Engine.Bind(api, context, entityId);
            s_instance = CreateScript();
            var handle = GCHandle.Alloc(s_instance);
            return GCHandle.ToIntPtr(handle);
        }

        /// <summary>
        /// 销毁脚本实例。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_destroy_instance")]
        public static void DestroyInstance(nint instancePtr)
        {
            if (instancePtr == nint.Zero) return;
            var handle = GCHandle.FromIntPtr(instancePtr);
            handle.Free();
            s_instance = null;
        }

        /// <summary>
        /// 生命周期：初始化。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_on_init")]
        public static void OnInit(nint instancePtr)
        {
            var script = Resolve(instancePtr);
            script?.OnInit();
        }

        /// <summary>
        /// 生命周期：每帧更新。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_on_update")]
        public static void OnUpdate(nint instancePtr, float deltaTime)
        {
            var script = Resolve(instancePtr);
            script?.OnUpdate(deltaTime);
        }

        /// <summary>
        /// 生命周期：销毁。
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "guava_on_destroy")]
        public static void OnDestroy(nint instancePtr)
        {
            var script = Resolve(instancePtr);
            script?.OnDestroy();
        }

        // ─── 用户需修改此方法 ─────────────────────────────────────
        // 返回你的脚本类实例。每个 .csproj 对应一个脚本类型。
        // 例如: return new MyPlayerController();
        private static GuavaScript CreateScript()
        {
            // TODO: 替换为你的脚本类
            throw new NotImplementedException(
                "请在 ScriptExports.CreateScript() 中返回你的 GuavaScript 子类实例。");
        }

        private static GuavaScript? Resolve(nint ptr)
        {
            if (ptr == nint.Zero) return null;
            var handle = GCHandle.FromIntPtr(ptr);
            return handle.Target as GuavaScript;
        }
    }
}
