// ---------------------------------------------------------------------------
// GuavaNetwork.cs — Guava 引擎 C# 网络/多人系统 SDK
//
// 提供面向脚本的网络 API：主机/客户端模式、连接管理、消息收发。
// 底层使用纯 Zig 实现的可靠 UDP 协议栈（无 C 依赖）。
// ---------------------------------------------------------------------------

using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Text;

namespace Guava
{
    /// <summary>网络角色。</summary>
    public enum NetworkRole
    {
        None = 0,
        Host = 1,
        Client = 2,
    }

    /// <summary>传输通道类型。</summary>
    public enum NetworkChannel : byte
    {
        /// <summary>可靠有序 — 保证送达，按发送顺序。</summary>
        Reliable = 0,
        /// <summary>不可靠 — 尽力送达，无保证。</summary>
        Unreliable = 1,
        /// <summary>不可靠有序 — 旧包被丢弃。</summary>
        UnreliableSequenced = 2,
    }

    /// <summary>网络事件类型。</summary>
    public enum NetworkEventKind
    {
        PlayerConnected,
        PlayerDisconnected,
        Connected,
        ConnectionFailed,
        MessageReceived,
    }

    /// <summary>网络事件。</summary>
    public struct NetworkEvent
    {
        public NetworkEventKind Kind;
        public byte PlayerId;
        public NetworkChannel Channel;
        public byte[] Data;
    }

    /// <summary>网络权威类型。</summary>
    public enum NetworkAuthority
    {
        Server = 0,
        Owner = 1,
    }

    /// <summary>
    /// 网络身份组件数据 — 对应引擎端 NetworkIdentity。
    /// </summary>
    public struct NetworkIdentityData
    {
        public uint NetworkId;
        public NetworkAuthority Authority;
        public byte OwnerPlayerId;
        public bool Enabled;
    }

    /// <summary>
    /// 网络变换同步配置 — 对应引擎端 NetworkTransform。
    /// </summary>
    public struct NetworkTransformData
    {
        public float InterpolationSpeed;
        public bool SyncPosition;
        public bool SyncRotation;
        public bool SyncScale;
        public bool Enabled;
    }

    /// <summary>
    /// 高级网络管理器。
    ///
    /// 使用示例（Host 模式）：
    /// <code>
    /// var net = new NetworkManager();
    /// net.Host(7777);
    /// // 每帧调用:
    /// net.Poll();
    /// foreach (var evt in net.Events)
    /// {
    ///     if (evt.Kind == NetworkEventKind.PlayerConnected)
    ///         Engine.Log($"Player {evt.PlayerId} joined!");
    /// }
    /// net.Broadcast(NetworkChannel.Reliable, myData);
    /// </code>
    ///
    /// 使用示例（Client 模式）：
    /// <code>
    /// var net = new NetworkManager();
    /// net.Connect("127.0.0.1", 7777);
    /// net.Poll();
    /// if (net.IsConnected)
    ///     net.SendToHost(NetworkChannel.Reliable, myData);
    /// </code>
    /// </summary>
    public class NetworkManager
    {
        /// <summary>当前角色。</summary>
        public NetworkRole Role { get; private set; } = NetworkRole.None;

        /// <summary>是否已连接（Host 始终为 true，Client 握手完成后为 true）。</summary>
        public bool IsConnected { get; private set; }

        /// <summary>本地玩家 ID（Host 为 0，Client 由 Host 分配）。</summary>
        public byte LocalPlayerId { get; private set; }

        /// <summary>本帧发生的网络事件列表。</summary>
        public List<NetworkEvent> Events { get; } = new();

        /// <summary>已连接的玩家 ID 集合（Host 模式下有效）。</summary>
        public HashSet<byte> ConnectedPlayers { get; } = new();

        /// <summary>收到消息时的回调。</summary>
        public event Action<byte, NetworkChannel, byte[]>? OnMessage;

        /// <summary>玩家加入时的回调。</summary>
        public event Action<byte>? OnPlayerConnected;

        /// <summary>玩家离开时的回调。</summary>
        public event Action<byte>? OnPlayerDisconnected;

        /// <summary>成功连接到 Host 时的回调（Client 模式）。</summary>
        public event Action? OnConnected;

        /// <summary>连接失败时的回调（Client 模式）。</summary>
        public event Action? OnConnectionFailed;

        /// <summary>
        /// 开始主持游戏。
        /// 当引擎端 NetworkSystem 通过 HostApi 扩展后，此方法将调用原生 API。
        /// </summary>
        public void Host(ushort port = 7777)
        {
            Role = NetworkRole.Host;
            IsConnected = true;
            LocalPlayerId = 0;
            Engine.Log($"[Network] Hosting on port {port}");
        }

        /// <summary>
        /// 连接到远程主机。
        /// </summary>
        public void Connect(string ip, ushort port = 7777)
        {
            Role = NetworkRole.Client;
            Engine.Log($"[Network] Connecting to {ip}:{port}...");
        }

        /// <summary>
        /// 断开连接。
        /// </summary>
        public void Disconnect()
        {
            Role = NetworkRole.None;
            IsConnected = false;
            ConnectedPlayers.Clear();
            Engine.Log("[Network] Disconnected");
        }

        /// <summary>
        /// 每帧调用 — 处理网络事件。
        /// 未来通过 HostApi 从引擎拉取事件；当前为事件触发框架。
        /// </summary>
        public void Poll()
        {
            Events.Clear();
            // TODO: 当 HostApi 扩展后，从引擎拉取本帧事件列表
            // 并填充 Events，触发回调。
            DispatchEvents();
        }

        /// <summary>向所有已连接玩家广播消息（Host 模式）。</summary>
        public void Broadcast(NetworkChannel channel, byte[] data)
        {
            if (Role != NetworkRole.Host)
                throw new InvalidOperationException("Only host can broadcast.");
            // TODO: 通过 HostApi 调用引擎 session.broadcast()
        }

        /// <summary>向指定玩家发送消息（Host 模式）。</summary>
        public void SendToPlayer(byte playerId, NetworkChannel channel, byte[] data)
        {
            if (Role != NetworkRole.Host)
                throw new InvalidOperationException("Only host can send to specific player.");
            // TODO: 通过 HostApi 调用引擎 session.sendToPlayer()
        }

        /// <summary>向 Host 发送消息（Client 模式）。</summary>
        public void SendToHost(NetworkChannel channel, byte[] data)
        {
            if (Role != NetworkRole.Client)
                throw new InvalidOperationException("Only client can send to host.");
            // TODO: 通过 HostApi 调用引擎 session.sendToHost()
        }

        /// <summary>
        /// 注入一个网络事件（供引擎端或测试使用）。
        /// </summary>
        public void InjectEvent(NetworkEvent evt)
        {
            Events.Add(evt);
        }

        // ─── 内部 ────────────────────────────────────────────────

        private void DispatchEvents()
        {
            foreach (var evt in Events)
            {
                switch (evt.Kind)
                {
                    case NetworkEventKind.PlayerConnected:
                        ConnectedPlayers.Add(evt.PlayerId);
                        OnPlayerConnected?.Invoke(evt.PlayerId);
                        break;
                    case NetworkEventKind.PlayerDisconnected:
                        ConnectedPlayers.Remove(evt.PlayerId);
                        OnPlayerDisconnected?.Invoke(evt.PlayerId);
                        break;
                    case NetworkEventKind.Connected:
                        IsConnected = true;
                        OnConnected?.Invoke();
                        break;
                    case NetworkEventKind.ConnectionFailed:
                        IsConnected = false;
                        OnConnectionFailed?.Invoke();
                        break;
                    case NetworkEventKind.MessageReceived:
                        OnMessage?.Invoke(evt.PlayerId, evt.Channel, evt.Data);
                        break;
                }
            }
        }
    }

    /// <summary>
    /// 简易 RPC 辅助工具 — 序列化方法调用为字节流。
    /// </summary>
    public static class NetworkRpc
    {
        /// <summary>将 RPC 调用编码为字节数组。</summary>
        public static byte[] Encode(string methodName, params object[] args)
        {
            var nameBytes = Encoding.UTF8.GetBytes(methodName);
            // Format: [nameLen:u16][name][argCount:u8][args...]
            var list = new List<byte>();
            list.Add((byte)(nameBytes.Length & 0xFF));
            list.Add((byte)((nameBytes.Length >> 8) & 0xFF));
            list.AddRange(nameBytes);
            list.Add((byte)args.Length);
            foreach (var arg in args)
            {
                switch (arg)
                {
                    case int i:
                        list.Add(1);
                        list.AddRange(BitConverter.GetBytes(i));
                        break;
                    case float f:
                        list.Add(2);
                        list.AddRange(BitConverter.GetBytes(f));
                        break;
                    case string s:
                        list.Add(3);
                        var sb = Encoding.UTF8.GetBytes(s);
                        list.Add((byte)(sb.Length & 0xFF));
                        list.Add((byte)((sb.Length >> 8) & 0xFF));
                        list.AddRange(sb);
                        break;
                    case byte b:
                        list.Add(4);
                        list.Add(b);
                        break;
                    default:
                        list.Add(0); // Unknown type marker.
                        break;
                }
            }
            return list.ToArray();
        }

        /// <summary>解码 RPC 调用。</summary>
        public static (string MethodName, object[] Args) Decode(byte[] data)
        {
            int offset = 0;
            int nameLen = data[offset] | (data[offset + 1] << 8);
            offset += 2;
            string name = Encoding.UTF8.GetString(data, offset, nameLen);
            offset += nameLen;

            int argCount = data[offset++];
            var args = new object[argCount];
            for (int i = 0; i < argCount; i++)
            {
                byte type = data[offset++];
                switch (type)
                {
                    case 1: // int
                        args[i] = BitConverter.ToInt32(data, offset);
                        offset += 4;
                        break;
                    case 2: // float
                        args[i] = BitConverter.ToSingle(data, offset);
                        offset += 4;
                        break;
                    case 3: // string
                        int sLen = data[offset] | (data[offset + 1] << 8);
                        offset += 2;
                        args[i] = Encoding.UTF8.GetString(data, offset, sLen);
                        offset += sLen;
                        break;
                    case 4: // byte
                        args[i] = data[offset++];
                        break;
                    default:
                        args[i] = null!;
                        break;
                }
            }
            return (name, args);
        }
    }
}
