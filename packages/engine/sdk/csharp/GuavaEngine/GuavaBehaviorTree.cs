// ---------------------------------------------------------------------------
// GuavaBehaviorTree.cs — C# 高级行为树构建器
//
// 提供纯 C# 的行为树实现，可在 OnUpdate 中手动 Tick，
// 或配合引擎端 BehaviorTreeComponent 自动驱动。
// ---------------------------------------------------------------------------

using System;
using System.Collections.Generic;

namespace Guava
{
    /// <summary>行为树节点执行状态。</summary>
    public enum BtStatus
    {
        Success,
        Failure,
        Running,
    }

    /// <summary>行为树节点基类。</summary>
    public abstract class BtNode
    {
        public abstract BtStatus Tick(BtContext ctx);
        public virtual void Reset() { }
    }

    /// <summary>每帧传入的上下文。</summary>
    public class BtContext
    {
        public float DeltaTime;
        public Dictionary<string, object> Blackboard;

        public BtContext(float dt, Dictionary<string, object> bb)
        {
            DeltaTime = dt;
            Blackboard = bb;
        }

        public T Get<T>(string key, T defaultValue = default!)
        {
            if (Blackboard.TryGetValue(key, out var v) && v is T typed) return typed;
            return defaultValue;
        }

        public void Set(string key, object value) => Blackboard[key] = value;
    }

    // ═══════════════════════════════════════════════════════════════
    // Composites
    // ═══════════════════════════════════════════════════════════════

    /// <summary>依次执行子节点，全部 Success 才 Success。</summary>
    public class Sequence : BtNode
    {
        private readonly List<BtNode> _children = new();
        private int _running;

        public Sequence(params BtNode[] children) { _children.AddRange(children); }

        public override BtStatus Tick(BtContext ctx)
        {
            for (int i = _running; i < _children.Count; i++)
            {
                var s = _children[i].Tick(ctx);
                if (s == BtStatus.Running) { _running = i; return BtStatus.Running; }
                if (s == BtStatus.Failure) { _running = 0; return BtStatus.Failure; }
            }
            _running = 0;
            return BtStatus.Success;
        }

        public override void Reset() { _running = 0; foreach (var c in _children) c.Reset(); }
    }

    /// <summary>依次尝试子节点，第一个 Success 即返回。</summary>
    public class Selector : BtNode
    {
        private readonly List<BtNode> _children = new();
        private int _running;

        public Selector(params BtNode[] children) { _children.AddRange(children); }

        public override BtStatus Tick(BtContext ctx)
        {
            for (int i = _running; i < _children.Count; i++)
            {
                var s = _children[i].Tick(ctx);
                if (s == BtStatus.Running) { _running = i; return BtStatus.Running; }
                if (s == BtStatus.Success) { _running = 0; return BtStatus.Success; }
            }
            _running = 0;
            return BtStatus.Failure;
        }

        public override void Reset() { _running = 0; foreach (var c in _children) c.Reset(); }
    }

    /// <summary>并行执行所有子节点，任一 Failure 则 Failure。</summary>
    public class Parallel : BtNode
    {
        private readonly List<BtNode> _children = new();

        public Parallel(params BtNode[] children) { _children.AddRange(children); }

        public override BtStatus Tick(BtContext ctx)
        {
            int success = 0, fail = 0;
            foreach (var c in _children)
            {
                var s = c.Tick(ctx);
                if (s == BtStatus.Success) success++;
                else if (s == BtStatus.Failure) fail++;
            }
            if (fail > 0) return BtStatus.Failure;
            if (success == _children.Count) return BtStatus.Success;
            return BtStatus.Running;
        }

        public override void Reset() { foreach (var c in _children) c.Reset(); }
    }

    // ═══════════════════════════════════════════════════════════════
    // Decorators
    // ═══════════════════════════════════════════════════════════════

    /// <summary>反转子节点结果。</summary>
    public class Inverter : BtNode
    {
        private readonly BtNode _child;
        public Inverter(BtNode child) { _child = child; }

        public override BtStatus Tick(BtContext ctx) => _child.Tick(ctx) switch
        {
            BtStatus.Success => BtStatus.Failure,
            BtStatus.Failure => BtStatus.Success,
            _ => BtStatus.Running,
        };

        public override void Reset() => _child.Reset();
    }

    /// <summary>无论子节点结果如何都返回 Success。</summary>
    public class Succeeder : BtNode
    {
        private readonly BtNode _child;
        public Succeeder(BtNode child) { _child = child; }

        public override BtStatus Tick(BtContext ctx)
        {
            var s = _child.Tick(ctx);
            return s == BtStatus.Running ? BtStatus.Running : BtStatus.Success;
        }

        public override void Reset() => _child.Reset();
    }

    /// <summary>冷却装饰器，子节点执行后等待指定秒数。</summary>
    public class Cooldown : BtNode
    {
        private readonly BtNode _child;
        private readonly float _seconds;
        private float _elapsed;

        public Cooldown(float seconds, BtNode child) { _seconds = seconds; _child = child; }

        public override BtStatus Tick(BtContext ctx)
        {
            if (_elapsed > 0) { _elapsed -= ctx.DeltaTime; return BtStatus.Failure; }
            var s = _child.Tick(ctx);
            if (s != BtStatus.Running) _elapsed = _seconds;
            return s;
        }

        public override void Reset() { _elapsed = 0; _child.Reset(); }
    }

    // ═══════════════════════════════════════════════════════════════
    // Leaves
    // ═══════════════════════════════════════════════════════════════

    /// <summary>执行一个动作回调。</summary>
    public class Action : BtNode
    {
        private readonly Func<BtContext, BtStatus> _fn;
        public Action(Func<BtContext, BtStatus> fn) { _fn = fn; }
        public override BtStatus Tick(BtContext ctx) => _fn(ctx);
    }

    /// <summary>评估一个条件。</summary>
    public class Condition : BtNode
    {
        private readonly Func<BtContext, bool> _fn;
        public Condition(Func<BtContext, bool> fn) { _fn = fn; }
        public override BtStatus Tick(BtContext ctx) => _fn(ctx) ? BtStatus.Success : BtStatus.Failure;
    }

    /// <summary>等待指定时长后返回 Success。</summary>
    public class Wait : BtNode
    {
        private readonly float _duration;
        private float _elapsed;

        public Wait(float seconds) { _duration = seconds; }

        public override BtStatus Tick(BtContext ctx)
        {
            _elapsed += ctx.DeltaTime;
            if (_elapsed >= _duration) { _elapsed = 0; return BtStatus.Success; }
            return BtStatus.Running;
        }

        public override void Reset() => _elapsed = 0;
    }
}
