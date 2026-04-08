const std = @import("std");
const world_mod = @import("../scene/world.zig");

// ─────────────────────────── 资源类型 ───────────────────────────

/// 预定义资源槽位，最多支持 max_resource_types 种
pub const ResourceKind = enum(u8) {
    gold = 0,
    wood = 1,
    food = 2,
    stone = 3,
    tech = 4,
    supply = 5,     // 人口/供给：current 为当前占用, max 由 SupplyProvider 提供
    custom_0 = 6,
    custom_1 = 7,
    _,
};

pub const max_resource_types: usize = 8;

/// 单一资源槽
pub const ResourceSlot = struct {
    amount: f64 = 0,
    capacity: f64 = std.math.inf(f64), // 上限，默认无限
};

/// 固定大小资源数组
pub const ResourceArray = [max_resource_types]ResourceSlot;

fn defaultResourceArray() ResourceArray {
    var arr: ResourceArray = undefined;
    for (&arr) |*slot| {
        slot.* = .{};
    }
    return arr;
}

// ─────────────────────────── ECS 组件 ───────────────────────────

/// 资源储备——附着在"玩家实体"或"基地"上，代表该阵营拥有的资源
pub const ResourceStorage = struct {
    team_id: u8 = 0,
    resources: ResourceArray = defaultResourceArray(),

    /// 安全加减（不超上限、不低于 0）
    pub fn add(self: *ResourceStorage, kind: ResourceKind, delta: f64) void {
        const idx: usize = @intFromEnum(kind);
        if (idx >= max_resource_types) return;
        const slot = &self.resources[idx];
        slot.amount = @min(slot.amount + delta, slot.capacity);
    }

    pub fn spend(self: *ResourceStorage, kind: ResourceKind, cost: f64) bool {
        const idx: usize = @intFromEnum(kind);
        if (idx >= max_resource_types) return false;
        const slot = &self.resources[idx];
        if (slot.amount < cost) return false;
        slot.amount -= cost;
        return true;
    }

    pub fn canAfford(self: *const ResourceStorage, kind: ResourceKind, cost: f64) bool {
        const idx: usize = @intFromEnum(kind);
        if (idx >= max_resource_types) return false;
        return self.resources[idx].amount >= cost;
    }

    pub fn get(self: *const ResourceStorage, kind: ResourceKind) f64 {
        const idx: usize = @intFromEnum(kind);
        if (idx >= max_resource_types) return 0;
        return self.resources[idx].amount;
    }

    pub fn setCapacity(self: *ResourceStorage, kind: ResourceKind, cap: f64) void {
        const idx: usize = @intFromEnum(kind);
        if (idx >= max_resource_types) return;
        self.resources[idx].capacity = cap;
    }
};

/// 资源采集者——附着在"农民""矿工"等单位上
pub const ResourceHarvester = struct {
    team_id: u8 = 0,
    /// 当前采集的资源类型
    harvest_kind: ResourceKind = .gold,
    /// 每秒采集量
    rate: f32 = 1.0,
    /// 单位本身的背包容量
    carry_capacity: f32 = 10.0,
    /// 当前携带量
    carried: f32 = 0,
    /// 是否正在采集（需要在资源点旁或与资源点碰撞）
    is_harvesting: bool = false,
    /// 是否正在卸货（到达基地时自动卸货）
    is_delivering: bool = false,
    enabled: bool = true,
};

/// 资源节点——附着在矿山、树木、金矿等可采集物上
pub const ResourceNode = struct {
    kind: ResourceKind = .gold,
    /// 剩余量（耗尽后实体可被标记为 depleted）
    remaining: f32 = 1000.0,
    /// 采集速率修正（乘以采集者速率）
    gather_multiplier: f32 = 1.0,
    /// 是否已耗尽
    depleted: bool = false,
};

/// 供给提供者——附着在"房屋""基地"等建筑上，提供人口上限
pub const SupplyProvider = struct {
    team_id: u8 = 0,
    supply_amount: f32 = 10.0,
    enabled: bool = true,
};

/// 供给消费者——附着在每个需要人口的单位上
pub const SupplyConsumer = struct {
    team_id: u8 = 0,
    supply_cost: f32 = 1.0,
};

// ─────── 生产队列组件 ───────

/// 生产队列中的单个条目
pub const ProductionEntry = struct {
    /// 生产目标的名字/标识（引擎层仅存储哈希，脚本层映射实际含义）
    product_id: u32 = 0,
    /// 资源消耗列表——简化为至多4种资源的消耗
    costs: [4]Cost = [_]Cost{.{}} ** 4,
    cost_count: u8 = 0,
    /// 总生产时间（秒）
    build_time: f32 = 5.0,
    /// 当前已投入的时间
    elapsed: f32 = 0,
};

pub const Cost = struct {
    kind: ResourceKind = .gold,
    amount: f64 = 0,
};

/// 生产队列——附着在建筑上
pub const ProductionQueue = struct {
    team_id: u8 = 0,
    /// 最大排队数
    max_queue_size: u8 = 5,
    /// 当前队列
    queue: [8]ProductionEntry = undefined,
    queue_len: u8 = 0,
    /// 最近完成的产品 ID（上层系统读取后清零）
    completed_product: u32 = 0,
    enabled: bool = true,

    pub fn enqueue(self: *ProductionQueue, entry: ProductionEntry) bool {
        if (self.queue_len >= self.max_queue_size) return false;
        self.queue[self.queue_len] = entry;
        self.queue_len += 1;
        return true;
    }

    pub fn cancelFront(self: *ProductionQueue) void {
        if (self.queue_len == 0) return;
        // shift left
        var i: u8 = 0;
        while (i + 1 < self.queue_len) : (i += 1) {
            self.queue[i] = self.queue[i + 1];
        }
        self.queue_len -= 1;
    }

    pub fn cancelAll(self: *ProductionQueue) void {
        self.queue_len = 0;
    }
};

/// 交易报价组件——附着在"市场"建筑上，定义买卖汇率
pub const TradeOffer = struct {
    team_id: u8 = 0,
    /// 卖出资源类型
    sell_kind: ResourceKind = .wood,
    /// 买入资源类型
    buy_kind: ResourceKind = .gold,
    /// 汇率：花费 sell_amount 的 sell_kind 得到 buy_amount 的 buy_kind
    sell_amount: f32 = 100.0,
    buy_amount: f32 = 50.0,
    enabled: bool = true,
};

// ─────────────────────────── 系统 ───────────────────────────

/// 经济系统——在引擎主循环中每帧调用 update
pub const EconomySystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) EconomySystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EconomySystem) void {
        _ = self;
    }

    /// 每帧更新
    pub fn update(self: *EconomySystem, world: *world_mod.World, delta: f32) void {
        _ = self;
        // 1. 更新供给上限
        updateSupplyCaps(world);
        // 2. 采集系统
        updateHarvesting(world, delta);
        // 3. 生产队列
        updateProduction(world, delta);
    }
};

// ─────── 供给上限计算 ───────

fn updateSupplyCaps(world: *world_mod.World) void {
    // 先把所有 storage 的 supply capacity 重置为 0
    for (world.entities.items) |*entity| {
        if (entity.resource_storage) |*storage| {
            storage.resources[@intFromEnum(ResourceKind.supply)].capacity = 0;
        }
    }

    // 然后遍历所有 SupplyProvider，累加到对应 team 的 storage
    for (world.entities.items) |*entity| {
        const provider = entity.supply_provider orelse continue;
        if (!provider.enabled) continue;

        // 累加到该 team 的 storage
        for (world.entities.items) |*other| {
            if (other.resource_storage) |*storage| {
                if (storage.team_id == provider.team_id) {
                    storage.resources[@intFromEnum(ResourceKind.supply)].capacity += provider.supply_amount;
                    break; // 假设每个 team 只有一个主 storage
                }
            }
        }
    }

    // 遍历 SupplyConsumer，累加当前人口占用
    // 先清零
    for (world.entities.items) |*entity| {
        if (entity.resource_storage) |*storage| {
            storage.resources[@intFromEnum(ResourceKind.supply)].amount = 0;
        }
    }
    for (world.entities.items) |*entity| {
        const consumer = entity.supply_consumer orelse continue;

        for (world.entities.items) |*other| {
            if (other.resource_storage) |*storage| {
                if (storage.team_id == consumer.team_id) {
                    storage.resources[@intFromEnum(ResourceKind.supply)].amount += consumer.supply_cost;
                    break;
                }
            }
        }
    }
}

// ─────── 采集更新 ───────

fn updateHarvesting(world: *world_mod.World, delta: f32) void {
    for (world.entities.items) |*entity| {
        var harvester = entity.resource_harvester orelse continue;
        if (!harvester.enabled) continue;

        if (harvester.is_harvesting) {
            // 查找最近的同类型资源节点（简化：遍历全部）
            var best_node: ?*ResourceNode = null;
            for (world.entities.items) |*other| {
                if (other.resource_node) |*node| {
                    if (!node.depleted and @intFromEnum(node.kind) == @intFromEnum(harvester.harvest_kind)) {
                        best_node = node;
                        break; // 简化：取第一个
                    }
                }
            }

            if (best_node) |node| {
                const gather_amount = harvester.rate * node.gather_multiplier * delta;
                const actual = @min(gather_amount, node.remaining);
                const space_left = harvester.carry_capacity - harvester.carried;
                const collected: f32 = @min(@as(f32, @floatCast(actual)), space_left);

                harvester.carried += collected;
                node.remaining -= collected;
                if (node.remaining <= 0) {
                    node.depleted = true;
                    node.remaining = 0;
                }

                // 背包满了就切换到卸货模式
                if (harvester.carried >= harvester.carry_capacity) {
                    harvester.is_harvesting = false;
                    harvester.is_delivering = true;
                }
            }
        }

        if (harvester.is_delivering) {
            // 简化：立即卸货到对应 team 的 storage
            for (world.entities.items) |*other| {
                if (other.resource_storage) |*storage| {
                    if (storage.team_id == harvester.team_id) {
                        storage.add(harvester.harvest_kind, @floatCast(harvester.carried));
                        harvester.carried = 0;
                        harvester.is_delivering = false;
                        harvester.is_harvesting = true; // 回去继续采
                        break;
                    }
                }
            }
        }

        entity.resource_harvester = harvester;
    }
}

// ─────── 生产队列更新 ───────

fn updateProduction(world: *world_mod.World, delta: f32) void {
    for (world.entities.items) |*entity| {
        var queue = entity.production_queue orelse continue;
        if (!queue.enabled or queue.queue_len == 0) continue;

        // 处理队首
        var front = &queue.queue[0];
        front.elapsed += delta;

        if (front.elapsed >= front.build_time) {
            // 完成！
            queue.completed_product = front.product_id;

            // shift queue
            var i: u8 = 0;
            while (i + 1 < queue.queue_len) : (i += 1) {
                queue.queue[i] = queue.queue[i + 1];
            }
            queue.queue_len -= 1;
        }

        entity.production_queue = queue;
    }
}

// ─────── 交易辅助函数 ───────

/// 执行一次交易：从 team 的 storage 中扣除 sell，增加 buy
/// 返回 true 表示交易成功
pub fn executeTrade(world: *world_mod.World, offer: TradeOffer) bool {
    // 找到该 team 的 storage
    for (world.entities.items) |*entity| {
        if (entity.resource_storage) |*storage| {
            if (storage.team_id == offer.team_id) {
                if (!storage.canAfford(offer.sell_kind, @floatCast(offer.sell_amount))) {
                    return false;
                }
                _ = storage.spend(offer.sell_kind, @floatCast(offer.sell_amount));
                storage.add(offer.buy_kind, @floatCast(offer.buy_amount));
                return true;
            }
        }
    }
    return false;
}
