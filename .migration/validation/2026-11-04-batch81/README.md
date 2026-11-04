# 批次 81 验证

`summary.json` 记录门禁、测试、失败名称/位置、FFmpeg 来源哈希及探针图像哈希；其余 JSON 是实际 Metal 探针报告。渲染图像留在 `/tmp/diffuse-metal-<scene>/`，源码和原生构建产物沿用仓库忽略规则。

本机已按旧构建设置暂存 FFmpeg 8.1.3；原生 bootstrap 和 Cargo 资源打包工具尚待迁移。已有原生产代码和 GPU 回归通过不代表 20 个原 Swift 渲染测试已迁移，场景层 15 个失败仍须处理。

在仓库根目录重跑本机 GPU 回归（需要已构建的原生依赖和可用 RHI 设备）：

```sh
mkdir -p /tmp/diffuse-migration-resources
ln -sfn "$PWD/Engine/Sources/RenderBackend/Resources" /tmp/diffuse-migration-resources/DiffuseRuntime_RenderBackend.bundle
export COVE_RESOURCE_PATH=/tmp/diffuse-migration-resources
cargo test -p diffuse-render-validation --test resource_lifecycle -- --test-threads=1
cargo run -p diffuse-render-validation --bin native_rhi_pass_probe -- --scene simulation --width 64 --height 64 --frames 3 --warmup 1 --repeats 1 --backends metal --output /tmp/diffuse-metal-simulation
```

八个场景是 grid、mesh、pbr、animated、post、stylized、particles、simulation。探针未开启 RHI validation，未比较 Swift 黄金图或多个后端，也不用于性能结论。GPU 回归在当前 Metal 设备上实际执行；其他设备不存在时按设备可用条件跳过。
