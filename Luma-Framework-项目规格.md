# Luma-Framework 项目规格

> 调研日期：2026-08-01
> 仓库：`https://github.com/Filoppi/Luma-Framework`（本地克隆：`E:\Code\pj\Luma-Framework`）
> 授权：MIT（LICENSE.md）

## 1. 项目概述

Luma 是一个 **DirectX 11 游戏图形增强/调优框架**，通过 ReShade Addon 系统实现。它深度侵入游戏渲染管线，支持：

- **HDR 输出改造**：swapchain 格式升级（8-bit → scRGB/16-bit float）、LUT 3D 升级、显示合成 pass
- **渲染技术替换**：添加/替换整个渲染 pass（后处理、色调映射等）
- **超分辨率**：DLSS (NGX) 与 FSR (FidelityFX) 集成
- **着色器替换**：按 shader 二进制哈希（cso hash）保存与替换游戏着色器
- **图形分析器**：捕获所有 draw/dispatch 命令与状态变化（SRVs/RTVs/UAVs/DSV/CBs 等）

> 注意：与 Starfield / Kingdom Come Deliverance 的 "Luma mod" 不是同一实体——那些是作者的早期独立作品，Luma Framework 是其后泛化出的通用框架。

## 2. 仓库规模

| 区域 | 内容 |
|---|---|
| `Source/Core/` | 核心框架（`core.hpp` ~912KB 单头文件 + dlss/fsr/utils 等子目录） |
| `Source/Games/` | **53 个游戏模组**（Prey、Batman Arkham Knight、Fallout 4、FF VII Remake、Mass Effect Andromeda、Titanfall 2 等）+ `_Template` 模板 + `_Generic Mod` |
| `Source/Graphics Analyzer/` | 独立图形分析器工具项目 |
| `Source/External/` | 子模块：ReShade (`crosire/reshade`)、DKUtil（仅 Prey 使用，vcpkg 管理） |
| `Shaders/` | 按游戏分目录的 HLSL 着色器 + `Global/` 通用着色器（`Luma_*` 前缀） |
| `Data/` | 游戏专用数据与配置（Prey 的 engine 文件、system.cfg 等） |
| `.github/workflows/` | CI 构建矩阵 + 自动打包发布 |

## 3. 技术栈

- **语言/平台**：C++（C++20+ 特性）、Windows（Win32/x64 均支持，如 BioShock 2 为 x86 示例）
- **图形 API**：DirectX 11（d3d11_4、dxgi1_6）
- **注入机制**：ReShade Addon 系统（编译为 DLL 注入游戏进程）
- **数学库**：DirectXMath
- **UI**：ImGui（ReShade 内置）
- **超分 SDK**：NVIDIA NGX (DLSS)、AMD FidelityFX Super Resolution
- **构建**：Visual Studio 解决方案（Luma.sln）、vcpkg（Prey 专用）
- **着色器**：HLSL（ps_5_0/vs_5_0/cs_5_0/gs_5_0）

## 4. 架构设计

### 4.1 核心模型

每个游戏模组是一个独立 DLL 项目，继承 `Game` 基类（`Source/Core/includes/game.h`），覆写生命周期虚方法：

| 方法 | 职责 |
|---|---|
| `OnLoad(path, failed)` | DLL 加载后（避免锁互斥量） |
| `OnInit(async)` | 模组初始化：注册 shader defines、设置 cbuffer 槽位、初始化游戏设置 |
| `OnCreateDevice(device, data)` | 创建设备时挂载自定义 `GameDeviceData` 子类 |
| `OnDrawOrDispatch(...)` | **核心入口**：拦截每个 draw/dispatch，按 shader 哈希追踪/改造渲染 pass |
| `OnPresent(device, data)` | 每帧 Present 时重置帧状态 |
| `OverrideCopyResource` / `OverrideCopyTextureRegion` | 拦截拷贝操作（资源升级兼容性） |
| `ModifyShaderByteCode` | 运行时内存级修改 shader 字节码（需宏启用） |

### 4.2 着色器替换机制

- 游戏着色器以 **cso 二进制哈希** 为标识（如 `HDRPostProcess_HDRFinalScene_0xB5DC761A.ps_5_0.hlsl`）
- 开发模式自动 dump 游戏 shader 到 `Shaders/GameName/`，自定义 HLSL 放同目录即按哈希覆盖
- 发布/测试模式从游戏二进制目录 `.\Luma\GameName\` 加载
- `ShaderPatching`（`shader_patching.h`）可解析 DXBC tokenized program，注入指令（如 `mov_sat`）

### 4.3 HDR 管线

- swapchain 格式升级：`SwapchainUpgradeType::scRGB`，`TextureFormatUpgradesType` 控制纹理升级（r8g8b8a8_unorm 等 → 16-bit float）
- LUT 3D 升级：尺寸/维度可配置（`texture_format_upgrades_lut_size`、`LUTDimensions`）
- 显示合成 pass：`Luma_DisplayComposition.hlsl`（伽马校正 + paper white 缩放延迟到此 pass）
- 渲染空间定义：`POST_PROCESS_SPACE_TYPE`、`EARLY_DISPLAY_ENCODING`、`VANILLA_ENCODING_TYPE` 等 shader defines

### 4.4 超分抽象

```
SR::SuperResolutionImpl（抽象基类，super_resolution.h）
├── NGX::DLSS（NVIDIA DLSS，宏 ENABLE_NGX 启用，仅 x64）
└── FidelityFX 实现（宏 ENABLE_FIDELITY_SK 启用）
```

任一启用则自动定义 `ENABLE_SR`。

### 4.5 cbuffer 注入

- 每 pass 自动向被覆写的 shader 上传 Luma settings/data cbuffer（插槽 13/12，可配置为 -1 禁用）
- 游戏自定义设置通过 `cb_luma_global_settings.GameSettings.*` 与 `GameCBuffers.hlsl` 镜像定义
- UI cbuffer（插槽可选）用于特定 UI 绘制类型

### 4.6 构建模式（宏控制，自动传播到 shader）

| 模式 | 用途 |
|---|---|
| `DEVELOPMENT` | 开发调试：dump shader、draw call 追踪、调试纹理可视化 |
| `TEST` | 测试：dump shader、日志警告（DEVELOPMENT 的子集） |
| Publishing（默认） | 发布：面向最终用户，从游戏目录加载 shader |

配置矩阵：`Development-Debug` / `Development-Release` / `Test-Release` / `Publishing-Release` × `x64` / `Win32`。

## 5. 添加新游戏模组流程

1. 安装 VS 项目模板（`Templates/VisualStudio` → 用户模板目录）
2. 在 `Source/Games/` 下新建项目（选 Luma Template）
3. 编辑 `main.cpp`：
   - 定义游戏宏（如 `GAME_PREY 1`）
   - 设置 shader defines 默认值（TONEMAP_TYPE、VANILLA_ENCODING_TYPE 等）
   - 配置 cbuffer 槽位索引
   - 配置纹理格式升级列表与过滤条件
   - 实现 `Game` 子类（OnInit/OnCreateDevice/OnDrawOrDispatch/OnPresent）
   - 版本号存于 `Globals::VERSION`（`Globals::SetGlobals`）
4. 设置环境变量 `LUMA_GAME_NAME_BIN_PATH` 指向游戏 exe 目录（后构建事件拷贝二进制）
5. 设置 VS 调试命令为游戏 exe（DRM 游戏可能不支持附加）
6. 游戏目录安装 ReShade 6.6.0+
7. 用 DEVELOPMENT 模式运行，dump shader → 按哈希编写替换 shader
8. 完成开发后在 Publishing 模式测试，向原仓库提交 PR（CI 自动构建打包发布）

## 6. 用户故事

1. 作为 mod 作者，我想用模板项目快速接入新 DX11 游戏，以便复用 Luma 的 HDR/超分能力
2. 作为 mod 作者，我想用 DEVELOPMENT 模式自动 dump 游戏着色器，以便定位并替换渲染 pass
3. 作为 mod 作者，我想按 shader 哈希替换任意 pass，以便重写后处理管线
4. 作为 mod 作者，我想通过 shader defines 暴露可调参数，以便用户无需改代码即可调整画面
5. 作为 mod 作者，我想在 Publishing 模式获得与游戏二进制目录对应的打包产物，以便发布 Nexus Mods
6. 作为 mod 作者，我想在支持的游戏里集成 DLSS/FSR 超分，以便提升性能
7. 作为玩家，我想通过 ReShade 内置 UI（ImGui）调整设置，以便不退出游戏调整画面
8. 作为玩家，我想让老游戏获得 HDR 输出（scRGB swapchain + 显示合成），以便在 HDR 显示器上获得正确亮度和色彩
9. 作为玩家，我想让游戏纹理/LUT 从 8-bit 升级到更高精度，以便减少色带
10. 作为分析者，我想用 Graphics Analyzer 在任意 DX11 游戏捕获 draw 调用与状态变化，以便分析渲染管线（无需完整 mod）
11. 作为维护者，我想让 CI 自动构建全部游戏模组并打包 ZIP 发布，以便持续集成
12. 作为开发者，我想在 Debug 构建打断点调试（保留符号），以便定位渲染问题

## 7. 测试策略

- **无单元测试套件**：项目以图形/视觉验证为主
- **CI 验证**：`.github/workflows/build_and_release.yml` 构建 4 配置 × 2 平台矩阵，失败不阻断（`continue-on-error`，保证其余模组仍可发布）
- **发布流程**：Publishing 模式实机测试 → PR → CI 自动打包各 mod 的 `Luma` 文件夹为 ZIP
- **兼容性开关**：`CHECK_GRAPHICS_API_COMPATIBILITY`、`DISABLE_RESHADE`（无 ReShade 依赖测试）等调试宏

## 8. 开发环境要求

- Windows 11（Windows 10 亦可）
- Visual Studio 2026（2022 可用）
- Windows 11 SDK 10.0.26100.0
- VC++ 最新运行时（`_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR` 可绕过版本检查）
- Prey 专属：VCPKG_ROOT 环境变量 + vcpkg manifest
- 禁止使用 "Edit and Continue"（\ZI）——会破坏代码补丁生成

## 9. 相关参考

- 与 RenoDX（`clshortfuse/renodx`）类似，Luma 从中获得部分灵感；Luma 更侧重深度 modding（整技术替换、DLSS、超宽屏），简单 mod 移植相对容易
- 核心代码热点：`core.hpp` 与各游戏 `main.cpp`
- 原始上游：`Filoppi/Luma-Framework`；本地 `origin` 指向 fork `ColoeusEdward/Luma-Framework`
