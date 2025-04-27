# BeeLight

**BeeLight** 是一个用 Zig 语言编写的自适应屏幕亮度调节服务，它利用环境光传感器数据和用户行为历史来智能调整屏幕亮度，旨在提供更舒适和节能的用户体验。

## 特性

- **高效性能:** 基于 Zig 语言实现，提供低资源消耗和快速响应。
- **自适应亮度调节:** 利用机器学习模型根据环境光和用户习惯进行预测。
- **增强型机器学习模型:**
  - **自适应分箱:** 根据历史环境光数据动态调整亮度区间的划分。
  - **加权数据点:** 考虑时间（白天/夜晚）、近期活动和用户活跃度的影响。
  - **异常点过滤:** 忽略异常的亮度/环境光变化数据，提高模型鲁棒性。
- **平滑过渡:** 在亮度变化时提供平滑的过渡效果，避免突兀感。
- **IPC 支持:** 提供进程间通信接口，允许其他应用程序与 BeeLight 服务进行交互（例如手动设置亮度、切换模式）。
- **历史数据记录:** 记录亮度和环境光数据，用于模型训练和分析。

## 项目结构

- `src/core/`: 包含项目的核心逻辑，如亮度控制器、传感器管理、屏幕控制、事件管理和配置加载。
- `src/ml/`: 包含机器学习相关的代码，主要是自适应分箱模型 (`enhanced_brightness_model.zig`)。
- `src/ipc/`: 包含进程间通信相关的代码，用于与其他应用交互。
- `src/storage/`: 包含数据存储相关的代码，用于记录历史数据。
- `build.zig`: Zig 构建文件。

## 构建和安装

### 前置条件

确保您已经安装了 Zig 编译器。您可以从 [Zig 官方网站](https://ziglang.org/download/) 下载。

### 使用 Makefile 构建

```bash
make
```

这将编译项目并生成可执行文件。

### 使用 Makefile 安装

```bash
sudo make install
```

## 配置

BeeLight 的配置通过 `src/core/config.zig` 文件定义。当前版本主要通过修改源码进行配置。未来版本可能支持从配置文件加载。

主要配置项包括：

- `auto_brightness_enabled`: 是否启用自动亮度调节。
- `min_brightness`, `max_brightness`: 屏幕亮度的最小值和最大值。
- `ambient_sensitivity`: 环境光敏感度。
- `min_ambient_light`, `max_ambient_light`: 环境光的范围。
- `bin_count`: 自适应分箱的数量。
- `activity_timeout`: 用户不活跃超时时间。
- `update_interval_ms`: 亮度更新间隔。
- `transition_duration_ms`: 亮度过渡时长。
- `transition_enabled`: 是否启用平滑过渡。
- `transition_type`: 平滑过渡类型（线性、指数、缓入缓出）。
- `time_schedule`: 基于时间的亮度调节时间表。

## 使用方法

构建并安装后，您可以运行 BeeLightd 服务：

```bash
beelightd
```

（请注意，具体的运行命令可能取决于您的安装方式和系统配置）

您可以通过 IPC 接口与其他应用程序或脚本进行交互。具体的 IPC 协议和使用示例将在未来提供更详细的文档。

## 贡献

欢迎对 BeeLight 做出贡献！如果您有任何想法、建议或发现了 bug，请随时提交 issue 或 Pull Request。

## 许可证

本项目采用 MIT 许可证。详情请参阅 `LICENSE` 文件。
