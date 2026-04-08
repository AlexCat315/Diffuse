const std = @import("std");
const world_mod = @import("../scene/world.zig");

// ─────────────────────────── 回合制组件 ───────────────────────────

/// 回合制全局配置 — 挂载在管理实体上
pub const TurnConfig = struct {
    /// 是否启用回合制
    enabled: bool = true,
    /// 最大玩家数
    max_players: u8 = 8,
    /// 当前回合数（从 1 开始）
    current_turn: u32 = 1,
    /// 当前玩家索引（0-based）
    current_player: u8 = 0,
    /// 实际参与的玩家数
    player_count: u8 = 2,
    /// 当前回合阶段
    phase: TurnPhase = .waiting,
    /// 单回合最大时间限制（秒，0 = 无限）
    turn_time_limit: f32 = 0,
    /// 当前阶段已消耗的时间
    phase_elapsed: f32 = 0,
};

pub const TurnPhase = enum(u8) {
    /// 等待开始
    waiting = 0,
    /// 玩家执行阶段（接受输入）
    player_action = 1,
    /// 动画/效果播放阶段
    animation = 2,
    /// AI 回合处理
    ai_processing = 3,
    /// 回合结束结算
    end_of_turn = 4,
};

/// 回合制参与者 — 挂载在"玩家"实体上
pub const TurnPlayer = struct {
    /// 玩家索引（0-based，与 TurnConfig.current_player 匹配）
    player_index: u8 = 0,
    /// 是否 AI 玩家
    is_ai: bool = false,
    /// 是否已结束回合（玩家手动点击"结束回合"）
    has_ended_turn: bool = false,
    /// 本回合剩余行动点
    action_points: f32 = 0,
    /// 每回合初始行动点
    max_action_points: f32 = 2.0,
    /// 队伍 ID
    team_id: u8 = 0,
    enabled: bool = true,
};

/// 回合制动作 — 挂载在可执行动作的单位上
pub const TurnActor = struct {
    /// 所属玩家索引
    player_index: u8 = 0,
    /// 每回合可行动次数
    actions_per_turn: u8 = 1,
    /// 本回合已行动次数
    actions_used: u8 = 0,
    /// 是否已完成本回合
    turn_done: bool = false,
    enabled: bool = true,
};

/// 动作队列条目 — 用于记录需要播放动画的动作
pub const ActionQueueEntry = struct {
    /// 执行者实体 ID
    actor_id: world_mod.EntityId = 0,
    /// 动作类型标识
    action_type: u32 = 0,
    /// 目标位置
    target_position: [3]f32 = .{ 0, 0, 0 },
    /// 目标实体
    target_entity: ?world_mod.EntityId = null,
    /// 动画持续时间（秒）
    duration: f32 = 1.0,
    /// 已播放时间
    elapsed: f32 = 0,
};

// ─────────────────────────── 系统 ───────────────────────────

/// 最大动作队列长度
const max_action_queue: usize = 32;

/// 回合管理器系统
pub const TurnSystem = struct {
    allocator: std.mem.Allocator,
    /// 动作队列（记录待播放动画的动作）
    action_queue: [max_action_queue]ActionQueueEntry = undefined,
    action_queue_len: u8 = 0,
    /// 本回合是否刚开始（用于触发初始化逻辑）
    turn_just_started: bool = false,
    /// 本回合是否刚结束
    turn_just_ended: bool = false,

    pub fn init(allocator: std.mem.Allocator) TurnSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TurnSystem) void {
        _ = self;
    }

    /// 每帧更新
    pub fn update(self: *TurnSystem, world: *world_mod.World, delta: f32) void {
        self.turn_just_started = false;
        self.turn_just_ended = false;

        // 找到 TurnConfig
        var config: ?*TurnConfig = null;
        for (world.entities.items) |*entity| {
            if (entity.turn_config) |*tc| {
                config = tc;
                break;
            }
        }
        const cfg = config orelse return;
        if (!cfg.enabled) return;

        cfg.phase_elapsed += delta;

        switch (cfg.phase) {
            .waiting => {
                // 外部调用 startGame() 后切换到 player_action
            },
            .player_action => {
                // 检查回合时间限制
                if (cfg.turn_time_limit > 0 and cfg.phase_elapsed >= cfg.turn_time_limit) {
                    self.endCurrentPlayerTurn(world, cfg);
                    return;
                }

                // 检查当前玩家是否已手动结束回合
                for (world.entities.items) |*entity| {
                    const player = entity.turn_player orelse continue;
                    if (player.player_index == cfg.current_player and player.has_ended_turn) {
                        self.endCurrentPlayerTurn(world, cfg);
                        return;
                    }
                }
            },
            .animation => {
                // 处理动作队列中的动画
                if (self.action_queue_len > 0) {
                    self.action_queue[0].elapsed += delta;
                    if (self.action_queue[0].elapsed >= self.action_queue[0].duration) {
                        // 动画播放完毕，移除队首
                        var i: u8 = 0;
                        while (i + 1 < self.action_queue_len) : (i += 1) {
                            self.action_queue[i] = self.action_queue[i + 1];
                        }
                        self.action_queue_len -= 1;
                    }
                } else {
                    // 队列清空，进入下一阶段
                    cfg.phase = .end_of_turn;
                    cfg.phase_elapsed = 0;
                }
            },
            .ai_processing => {
                // AI 回合：这里只是一个占位，实际 AI 逻辑由
                // 行为树系统或脚本层驱动。
                // AI 完成后调用 endAiTurn()
            },
            .end_of_turn => {
                // 回合结算
                self.advanceToNextPlayer(world, cfg);
            },
        }
    }

    /// 开始游戏（从 waiting → player_action）
    pub fn startGame(self: *TurnSystem, world: *world_mod.World) void {
        for (world.entities.items) |*entity| {
            if (entity.turn_config) |*cfg| {
                cfg.current_turn = 1;
                cfg.current_player = 0;
                cfg.phase = .player_action;
                cfg.phase_elapsed = 0;
                self.beginPlayerTurn(world, cfg);
                return;
            }
        }
    }

    /// 当前玩家结束回合
    fn endCurrentPlayerTurn(self: *TurnSystem, world: *world_mod.World, cfg: *TurnConfig) void {
        // 如果有待播放动画
        if (self.action_queue_len > 0) {
            cfg.phase = .animation;
            cfg.phase_elapsed = 0;
        } else {
            cfg.phase = .end_of_turn;
            cfg.phase_elapsed = 0;
        }
        _ = world;
    }

    /// 推进到下一个玩家
    fn advanceToNextPlayer(self: *TurnSystem, world: *world_mod.World, cfg: *TurnConfig) void {
        cfg.current_player += 1;
        if (cfg.current_player >= cfg.player_count) {
            // 所有玩家完成，新回合
            cfg.current_player = 0;
            cfg.current_turn += 1;
            self.turn_just_ended = true;
        }
        cfg.phase_elapsed = 0;

        // 判断下一个玩家是 AI 还是人类
        var is_ai = false;
        for (world.entities.items) |*entity| {
            const player = entity.turn_player orelse continue;
            if (player.player_index == cfg.current_player) {
                is_ai = player.is_ai;
                break;
            }
        }

        if (is_ai) {
            cfg.phase = .ai_processing;
        } else {
            cfg.phase = .player_action;
        }

        self.beginPlayerTurn(world, cfg);
    }

    /// 回合开始初始化
    fn beginPlayerTurn(self: *TurnSystem, world: *world_mod.World, cfg: *TurnConfig) void {
        self.turn_just_started = true;

        // 重置该玩家的所有 TurnActor
        for (world.entities.items) |*entity| {
            if (entity.turn_actor) |*actor| {
                if (actor.player_index == cfg.current_player) {
                    actor.actions_used = 0;
                    actor.turn_done = false;
                }
            }
        }

        // 重置该玩家的 has_ended_turn
        for (world.entities.items) |*entity| {
            if (entity.turn_player) |*player| {
                if (player.player_index == cfg.current_player) {
                    player.has_ended_turn = false;
                    player.action_points = player.max_action_points;
                }
            }
        }
    }

    /// 结束 AI 回合（由 AI 系统调用）
    pub fn endAiTurn(self: *TurnSystem, world: *world_mod.World) void {
        for (world.entities.items) |*entity| {
            if (entity.turn_config) |*cfg| {
                if (cfg.phase == .ai_processing) {
                    if (self.action_queue_len > 0) {
                        cfg.phase = .animation;
                    } else {
                        cfg.phase = .end_of_turn;
                    }
                    cfg.phase_elapsed = 0;
                }
                return;
            }
        }
    }

    /// 将一个动作加入播放队列
    pub fn enqueueAction(self: *TurnSystem, entry: ActionQueueEntry) bool {
        if (self.action_queue_len >= max_action_queue) return false;
        self.action_queue[self.action_queue_len] = entry;
        self.action_queue_len += 1;
        return true;
    }

    /// 查询当前是否轮到指定玩家
    pub fn isPlayerTurn(self: *const TurnSystem, world: *const world_mod.World, player_index: u8) bool {
        _ = self;
        for (world.entities.items) |entity| {
            if (entity.turn_config) |cfg| {
                return cfg.phase == .player_action and cfg.current_player == player_index;
            }
        }
        return false;
    }
};
