# 破坏性重构说明

## 脚本结构变更

旧结构 → 新结构：

| 旧文件 | 新文件 | 说明 |
| --- | --- | --- |
| `scripts/build-lib.sh` | `scripts/lib.sh` | 精简共享库，移除非必要函数 |
| `scripts/full-build.sh` | `scripts/build.sh` | 完整构建流水线，合并阶段函数 |
| `scripts/local-build.sh` | `scripts/smoke.sh` | 本地烟雾测试，不再承载 `--mode full` |

## 已删除项

### 脚本文件
- `scripts/build-lib.sh` — 被 `scripts/lib.sh` 替代
- `scripts/full-build.sh` — 被 `scripts/build.sh` 替代
- `scripts/local-build.sh` — 被 `scripts/smoke.sh` 替代

### 函数与机制
- `step_start()` / `step_end()` 计时仪式 → 简单 `log_info` 阶段标记
- `config_default()` → 移除，`config.conf` 已有默认值
- `payload_apk_dir_name()` 等常量函数 → 变量常量
- `summary_append_line()` / `build_payload_dependency_summary()` → 内联
- `check_disk_space()` / `path_available_gb()` / `choose_temp_root()` / `make_managed_tempdir()` → `mktemp -d`
- `sed_escape_replacement()` → 内联
- `count_file_lines()` → `wc -l`
- `run_payload_summary_regression()` → 移除
- `prepare_compile_package_sets()` 复杂验证 → 简化为 `comm -12` 集合交叉检查
- `--metadata-file` 输出 → 移除

### 安装器变更
- `INSTALL_MODE_RESOLVED` 间接层 → 直接使用 `INSTALL_MODE`
- `INSTALL_PLAN_LABEL` → 移除

### CLI 变更
- `local-build.sh --mode smoke|full` → `smoke.sh` 和 `build.sh` 独立入口
- `full-build.sh --repo-root` → 移除，自动从脚本位置推导
- `full-build.sh --payload-dir` → 移除，使用内部临时目录
- `full-build.sh --metadata-file` → 移除

## 保留项

- 安装器模式 `auto|full`
- 版本保护（跳过同版/更高版包）
- payload 最小闭集：`INSTALL_WHITELIST`、`PAYLOAD_APK_MAP`、`apks/packages.adb`、`SHA256SUMS`
- 所有编译功能、依赖解析、SDK patch
- CI workflow 完整流程

## 迁移指南

1. `local-build.sh --mode smoke` → `smoke.sh`
2. `local-build.sh --mode full` → `build.sh`
3. `source scripts/build-lib.sh` → `source scripts/lib.sh`
4. `load_env_config` → `load_config`
5. CI 脚本中的 `build-lib.sh` 引用需更新为 `lib.sh`

## 重构结果

- 代码总量从 ~2630 行减少到 ~1850 行（精简约 30%）
- 入口清晰：`build.sh`（构建）、`smoke.sh`（测试）、独立职责
- 消除 build-lib.sh 万能厨房：lib.sh 仅保留跨脚本共享的必要函数
- 消除重复：config 加载、tag 解析不再在多处重复实现
