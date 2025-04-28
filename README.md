# BeeLight

[![Zig Version](https://img.shields.io/badge/Zig-0.14.0-orange.svg)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**BeeLight** 是一个使用 Zig 语言编写的实验性自适应屏幕亮度调节服务。它旨在利用环境光传感器数据和用户行为历史来智能调整屏幕亮度，以提供更舒适和节能的视觉体验。

## 特性

- **高效性能:** 基于 Zig 实现，旨在实现低资源消耗和快速响应。
- **自适应亮度调节:** 利用机器学习模型根据环境光和用户习惯预测合适的亮度。
- **增强型机器学习模型 (进行中):**
  - **自适应分箱:** 根据历史环境光数据动态调整亮度区间。
  - **加权数据点:** 考虑时间、近期活动和用户活跃度。
  - **异常点过滤:** 尝试忽略异常数据点以提高模型鲁棒性。
- **平滑过渡:** 支持亮度变化的平滑过渡效果。
- **IPC 支持 (规划中):** 计划提供进程间通信接口，允许其他应用与服务交互。
- **历史数据记录:** 记录亮度和环境光数据，用于模型训练和分析。

## 项目结构

```txt
├── build.zig # Zig 构建系统脚本
├── build.zig.zon # 构建依赖文件
├── Makefile # 便捷构建命令 (可选)
├── README.md # 本文件
├── src/ # 源代码目录
│ ├── main.zig # 程序入口
│ ├── lib.zig # 库入口 (如果作为库使用)
│ ├── cli.zig # 命令行参数处理 (可能与 IPC 客户端合并或重构)
│ ├── core/ # 核心逻辑
│ │ ├── controller.zig # 主要控制循环和逻辑
│ │ ├── sensor.zig # 环境光传感器接口 (平台相关)
│ │ ├── screen.zig # 屏幕亮度控制接口 (平台相关)
│ │ ├── config.zig # 当前硬编码的配置
│ │ └── log.zig # 日志记录实现
│ ├── model/ # 机器学习与数据处理
│ │ ├── enhanced_brightness_model.zig # 主要的亮度预测模型
│ │ ├── brightness_predictor.zig # 亮度预测接口
│ │ ├── brightness_record.zig # 数据记录结构
│ │ └── recorder.zig # 数据记录器实现
│ └── ipc/ # 进程间通信 (待实现)
├── .gitignore
└── ... (其他配置文件)
```

## 构建与安装

### 前置条件

- **Zig 编译器:** 版本 0.14.0。可从 [Zig 官方网站](https://ziglang.org/download/) 下载。
- **平台依赖:** 可能需要特定的库来访问传感器和屏幕亮度控制（例如，Linux 上的 `libudev` 或 D-Bus 接口）。请根据 `src/core/sensor.zig` 和 `src/core/screen.zig` 的具体实现确定。

### 构建

推荐使用 Zig 构建系统：

```bash
zig build
```

或者使用 Makefile（如果提供了便捷命令）：

```bash
make build # 或者直接 make
```

可执行文件将生成在 `zig-out/bin/` 目录下。

### 安装

可以使用 Zig 构建系统进行安装（如果 `build.zig` 中定义了安装步骤）：

```bash
zig build install --prefix /usr/local # 指定安装前缀
```

或者使用 Makefile（如果提供了安装命令）：

```bash
sudo make install
```

## 配置

**当前状态:** 配置项目前硬编码在 `src/core/config.zig` 文件中。修改配置需要重新编译项目。

**未来计划:** 将配置迁移到外部文件（如 TOML 或 JSON 格式），允许用户在运行时修改。

**主要可配置项 (在 `config.zig` 中):**

- `auto_brightness_enabled`: 是否启用自动亮度调节。
- `min_brightness`, `max_brightness`: 屏幕亮度的允许范围。
- `ambient_sensitivity`: 环境光敏感度调整因子。
- `update_interval_ms`: 亮度检查和更新的时间间隔。
- `transition_duration_ms`: 亮度变化的平滑过渡时间。
- ... 以及模型相关的参数。

## 使用方法

构建并安装后，可以尝试运行 BeeLight 服务（具体名称可能取决于构建配置）：

```bash
# 假设可执行文件名为 beelightd
beelightd
```

**注意:**

- 服务可能需要特定权限才能访问传感器或控制屏幕亮度。
- 由于配置和 IPC 尚未完善，当前版本主要用于开发和实验。

## 进程间通信 (IPC)

`src/ipc/` 目录已创建，用于未来的 IPC 实现。目标是允许其他应用程序或脚本：

- 查询当前状态（亮度、模式等）。
- 手动设置亮度。
- 启用/禁用自动调节。
- 触发模型重新训练（如果支持）。

具体的协议和实现细节尚未确定。

## 测试

**当前状态:** 项目尚未包含系统的单元测试或集成测试。

**未来计划:** 添加测试用例以确保核心逻辑、模型和平台接口的正确性和鲁棒性。

## 贡献

欢迎对 BeeLight 做出贡献！如果您有任何想法、改进建议或发现了 bug，请随时创建 Issue 或提交 Pull Request。请确保遵循项目的编码风格（使用 `zig fmt`）和约定。

## 许可证

本项目采用 MIT 许可证。
