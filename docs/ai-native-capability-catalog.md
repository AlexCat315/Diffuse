# AI 能力目录（CapabilityGraph 实例集）

> 本文档是 `ai-native-scene-model-design.md` §10 的实例化清单。
> `ai-native-game-workflow-design.md` 与 `ai-native-film-workflow-design.md` 通过 verb id 引用本目录。
> 本文档不重复定义 CapabilityGraph schema，只列具体 capability。

---

## 0. 字段约定

每个 capability 至少包含总纲 §10.1 的全部字段。本目录在表格中只展示关键列，完整字段以 verb id 为主键存放在引擎的 `CapabilityRegistry` 中。

字段简写：

- `scope`：作用域 = `asset | prefab | scene_instance | shot_override | runtime | project_config | sequence | track | clip`
- `rev?`：reversible，是否可撤销
- `prv?`：preview_support，是否支持预演
- `cfm`：confirmation_policy = `auto | warn | required | destructive_required`
- `wd`：writes_documents
- `wr`：writes_runtime

---

## 1. 资产域（asset / prefab）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `asset.import` | asset | y | y | warn | AssetGraph, ModelDocument | n |
| `asset.reimport` | asset | y | y | warn | AssetGraph, ModelDocument | n |
| `asset.promote_inferred_to_authored` | asset | y | y | required | ModelDocument | n |
| `asset.set_metadata` | asset | y | n | auto | AssetGraph | n |
| `asset.bake_lod` | asset | y | y | warn | ModelDocument | n |
| `asset.bake_collision` | asset | y | y | warn | ModelDocument | n |
| `prefab.create_from_instance` | prefab | y | y | warn | PrefabDocument, SceneDocument | n |
| `prefab.update_definition` | prefab | y | y | required | PrefabDocument | y |
| `prefab.propagate_to_instances` | prefab | y | y | required | SceneDocument | y |
| `model.set_part_transform` | asset | y | y | warn | ModelDocument | n |
| `model.set_material_override` | scene_instance | y | y | auto | SceneDocument | y |
| `model.edit_mesh_region` | asset | y | y | required | ModelDocument | n |
| `model.replace_part_asset` | asset | y | y | warn | ModelDocument | n |

---

## 2. 场景域（scene_instance / scene_graph）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `scene.create_instance` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.delete_instance` | scene_instance | y | y | warn | SceneDocument | y |
| `scene.duplicate_instance` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.set_transform` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.set_parent` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.add_component` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.remove_component` | scene_instance | y | y | warn | SceneDocument | y |
| `scene.set_component_field` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.apply_layout_solution` | scene_graph | y | y | required | SceneDocument | y |
| `scene.commit_inferred_draft` | scene_graph | y | y | required | SceneDocument | y |
| `scene.snap_to_ground` | scene_instance | y | y | auto | SceneDocument | y |
| `scene.resolve_collision` | scene_instance | y | y | warn | SceneDocument | y |

---

## 3. 序列域（sequence / shot / clip / binding）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `sequence.create` | sequence | y | y | auto | SequenceDocument | n |
| `sequence.add_shot` | shot | y | y | auto | SequenceDocument | n |
| `shot.set_range` | shot | y | y | auto | SequenceDocument | n |
| `shot.set_camera_binding` | shot | y | y | auto | SequenceDocument | n |
| `shot.create_override` | shot_override | y | y | warn | SequenceDocument | y |
| `shot.discard_override` | shot_override | y | y | warn | SequenceDocument | y |
| `track.add` | track | y | y | auto | SequenceDocument | n |
| `track.remove` | track | y | y | warn | SequenceDocument | n |
| `clip.add` | clip | y | y | auto | SequenceDocument | n |
| `clip.set_range` | clip | y | y | auto | SequenceDocument | n |
| `clip.retime` | clip | y | y | warn | SequenceDocument | n |
| `binding.bind` | binding | y | y | auto | SequenceDocument | n |
| `binding.rebind` | binding | y | y | warn | SequenceDocument | n |

---

## 4. 镜头语言（cinematic）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `camera.set_focal_length` | shot_override | y | y | auto | SequenceDocument | n |
| `camera.set_aperture` | shot_override | y | y | auto | SequenceDocument | n |
| `camera.set_focus_distance` | shot_override | y | y | auto | SequenceDocument | n |
| `camera.set_aspect` | shot | y | y | warn | SequenceDocument | n |
| `camera.move_dolly` | clip | y | y | auto | SequenceDocument | n |
| `camera.move_pan_tilt` | clip | y | y | auto | SequenceDocument | n |
| `camera.move_orbit` | clip | y | y | auto | SequenceDocument | n |
| `camera.frame_subject` | shot_override | y | y | auto | SequenceDocument | n |
| `composition.apply_rule` | shot_override | y | y | auto | SequenceDocument | n |
| `cut.add` | sequence | y | y | warn | SequenceDocument | n |
| `cut.remove` | sequence | y | y | warn | SequenceDocument | n |

`composition.apply_rule` 的 rule_id 闭集：`rule_of_thirds | center | golden_ratio | leading_lines | symmetry | headroom`。

---

## 5. 光照（lighting）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `lighting.set_env` | scene_instance | y | y | auto | SceneDocument | y |
| `lighting.add_light` | scene_instance | y | y | auto | SceneDocument | y |
| `lighting.remove_light` | scene_instance | y | y | warn | SceneDocument | y |
| `lighting.set_light_param` | scene_instance | y | y | auto | SceneDocument | y |
| `lighting.shot_override` | shot_override | y | y | warn | SequenceDocument | y |
| `lighting.bake_gi` | scene_instance | y | y | required | SceneDocument | n |

`lighting.add_light` 的 `usage_kind` 必填：`cinematic | gameplay | both`。两类灯光的 capability 行为不同：cinematic 默认仅在 sequencer 渲染时启用，gameplay 默认在 runtime 启用。

---

## 6. 动画 / 表演（animation / performance）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `anim.create_state_machine` | asset | y | y | warn | AnimationGraphDocument | n |
| `anim.add_state` | asset | y | y | auto | AnimationGraphDocument | n |
| `anim.add_transition` | asset | y | y | auto | AnimationGraphDocument | n |
| `anim.bind_clip` | asset | y | y | auto | AnimationGraphDocument | n |
| `perf.import_mocap` | asset | y | y | warn | PerformanceClipDocument | n |
| `perf.retarget` | asset | y | y | warn | PerformanceClipDocument | n |
| `perf.facial_solve` | asset | y | y | warn | PerformanceClipDocument | n |
| `perf.lipsync_from_audio` | asset | y | y | warn | PerformanceClipDocument | n |
| `perf.apply_to_binding` | binding | y | y | auto | SequenceDocument | n |
| `perf.layer_additive` | clip | y | y | auto | SequenceDocument | n |

---

## 7. 玩法脚本（gameplay scripting）

游戏域的脚本写入必须经过 capability，禁止 AI 直接生成自由代码字符串落库。

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `gameplay.create_event_handler` | prefab | y | y | warn | GameplayScriptDocument | n |
| `gameplay.add_behavior_tree` | asset | y | y | warn | BehaviorTreeDocument | n |
| `gameplay.set_bt_node` | asset | y | y | auto | BehaviorTreeDocument | n |
| `gameplay.add_fsm_state` | asset | y | y | auto | FsmDocument | n |
| `gameplay.bind_input` | project_config | y | y | warn | InputMapDocument | n |
| `gameplay.set_data_table_value` | asset | y | y | auto | DataTableDocument | n |
| `gameplay.fork_data_table_branch` | asset | y | y | warn | DataTableDocument | n |
| `gameplay.merge_data_table_branch` | asset | y | y | required | DataTableDocument | n |

`gameplay.create_event_handler` 的 body 不是自由代码，是受限 AST，其节点类型必须出现在 `GameplayActionRegistry`。详见游戏工作流文档 §3。

---

## 8. 关卡构造（level blockout / nav）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `level.create_blockout_volume` | scene_instance | y | y | auto | SceneDocument | y |
| `level.modify_blockout_volume` | scene_instance | y | y | auto | SceneDocument | y |
| `level.replace_blockout_with_asset` | scene_instance | y | y | warn | SceneDocument | y |
| `level.bake_navmesh` | scene_instance | y | y | warn | SceneDocument | n |
| `level.add_spawn_point` | scene_instance | y | y | auto | SceneDocument | y |
| `level.add_trigger_volume` | scene_instance | y | y | auto | SceneDocument | y |

---

## 9. 渲染编排（render orchestration）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `render.create_job` | sequence | y | y | warn | RenderJobDocument | n |
| `render.set_quality_preset` | sequence | y | y | auto | RenderJobDocument | n |
| `render.submit_local` | sequence | n | n | warn | RenderJobDocument | n |
| `render.submit_farm` | sequence | n | n | required | RenderJobDocument | n |
| `render.cancel_job` | sequence | y | n | warn | RenderJobDocument | n |
| `render.diff_versions` | sequence | n | n | auto | — | n |

`render.submit_*` 不可撤销（已消耗算力），但可 `cancel_job`。

---

## 10. 烘焙与缓存（bake）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `bake.physics_cache` | scene_instance | y | y | warn | BakeCacheDocument | n |
| `bake.cloth_cache` | scene_instance | y | y | warn | BakeCacheDocument | n |
| `bake.fluid_cache` | scene_instance | y | y | required | BakeCacheDocument | n |
| `bake.lighting_gi` | scene_instance | y | y | required | BakeCacheDocument | n |
| `bake.invalidate` | scene_instance | y | n | warn | BakeCacheDocument | n |

---

## 11. Playtest / Review

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `playtest.start_session` | runtime | n | n | auto | PlaytestSessionDocument | y |
| `playtest.stop_session` | runtime | n | n | auto | PlaytestSessionDocument | y |
| `playtest.attach_telemetry` | runtime | n | n | auto | PlaytestSessionDocument | y |
| `playtest.snapshot_diagnostics` | runtime | n | n | auto | DiagnosticsDocument | n |
| `review.create_annotation` | sequence | y | n | auto | ReviewDocument | n |
| `review.compare_versions` | sequence | n | n | auto | — | n |

---

## 12. 项目级（project_config）

| verb | scope | rev? | prv? | cfm | wd | wr |
|------|-------|------|------|-----|----|----|
| `project.set_target_platform` | project_config | y | y | required | ProjectDocument | n |
| `project.set_render_pipeline` | project_config | y | y | destructive_required | ProjectDocument | n |
| `project.add_plugin` | project_config | y | y | warn | ProjectDocument | n |
| `project.set_capability_thresholds` | project_config | y | n | warn | ProjectDocument | n |

---

## 13. 跨域共享约束

1. 所有 `wd` 写入走 Transaction IR，`wr` 写入按 transaction policy 同步到 RuntimeWorld
2. `cfm = destructive_required` 的 verb 必须二次确认（按钮 + 文字短语回填）
3. 任一 verb 失败必须返回结构化原因，不允许只丢异常字符串
4. `inferred` 来源的 verb 调用结果默认带 `provenance.confidence`，由 AmbiguityScorer 决定是否要确认
5. verb 不允许跨 scope 隐式越权（例如 `model.set_material_override` 不能背地里改 asset 本体）
6. 新增 verb 必须同时登记到本目录、`CapabilityRegistry`、对应工作流文档，三处缺一视为未上线

---

## 14. 待补的子目录

下列分组当前未细化，待对应工作流子文档稳定后补充：

- AI Director / Behavior Director 的高阶 verb（一组 capability 的脚本化组合）
- VFX / 粒子（Niagara 类）
- 音频（mixer / cue / spatial）
- 网络 / 多人
- 本地化
- 版本控制集成（commit / branch / merge 的 capability 化封装）
