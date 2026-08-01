# Luma-Framework 通用占位模组（_Demo）设计文档

> 日期：2026-08-01
> 目标仓库：`E:\Code\pj\Luma-Framework`
> 状态：已批准（用户 2026-08-01）

## 背景

用户请求按照 Luma-Framework 规格为新游戏添加模组，目标游戏为《装甲恶鬼村正》（`D:\MCode\TempTool\装甲恶鬼村正\装甲恶鬼村正`）。

经调研确认：

- 该游戏是 **Direct3D 9** 游戏（`Muramasa_chs.exe` 为 PE32 x86，导入 `d3d9.dll`，2009 年 Nitroplus 引擎，`.npa`/`.ngs` 资源封包）
- Luma-Framework **仅支持 DirectX 11**（核心头文件全部基于 `d3d11.h`，ReShade Addon DX11 API），仓库中无任何 DX9 代码
- 因此 Luma 模组无法注入该游戏

用户决策：

1. 目标改为**新建通用占位模组项目**（不指向特定游戏）
2. 占位项目需**做好 DLSS 接入准备**（`ENABLE_NGX`）
3. 使用本机 VS Build Tools 2026（18.7.11925.98，符合 Luma 要求）本地构建验证

## 设计

### 1. 项目定位

在 `Source\Games\_Demo\` 下新建通用占位模组项目，演示 Luma 模组结构（DLL + ReShade Addon），作为未来接入任意 DX11 游戏的起点。命名 `_Demo`（下划线前缀符合 Luma 辅助项目惯例，如 `_Template`、`_Generic Mod`）。

### 2. 文件清单

| 文件 | 内容 |
|---|---|
| `Source\Games\_Demo\Demo.vcxproj` | 基于 `_Generic Mod` 复制，改项目名/GUID，8 配置全部追加 DLSS 依赖 |
| `Source\Games\_Demo\Demo.vcxproj.filters` | 同步改名 |
| `Source\Games\_Demo\main.cpp` | 精简 Generic Mod 骨架，`#define ENABLE_NGX 1` |
| `Luma.sln` | 新增项目条目 + 16 行配置映射 + NestedProjects 归入 Games 文件夹 |

### 3. DLSS 接入配置（照抄现有 DLSS 游戏模式）

**vcxproj（每个 Configuration/Platform 组合，共 8 组）：**

- `ClCompile\AdditionalIncludeDirectories`：追加 `..\..\External\NGX`
- `Link\AdditionalLibraryDirectories`：追加 `..\..\External\NGX\libs`
- `Link\AdditionalDependencies`：
  - Debug（Development-Debug）：`nvsdk_ngx_d_dbg.lib`
  - Release（Development-Release / Test-Release / Publishing-Release）：`nvsdk_ngx_d.lib`
- 保持 `_Generic Mod` 原有的 ReShade include 路径、编译选项（`stdcpplatest`、`/utf-8`、`PROJECT_NAME`、`DEVELOPMENT=1` 等）

**main.cpp：**

```cpp
#define ENABLE_NGX 1
```

（`DLSS.h` 在 x64 且检测到 `nvsdk_ngx.h` 时自动定义 `ENABLE_NGX`，显式定义确保意图明确、y 依赖完整。）

**无需额外工作：**

- NGX SDK 已存在于 `Source\External\NGX\`（`nvsdk_ngx*.h` + `libs\nvsdk_ngx_d.lib`/`nvsdk_ngx_d_dbg.lib` + `bin\dev\rel\nvngx_dlss.dll`），无需拉取
- CI（`build_and_release.yml`）自动扫描 vcxproj 中的 `nvsdk_ngx` 关键字，命中即打包 `nvngx_dlss.dll` 进发布 ZIP，无需手工配置

### 4. main.cpp 骨架内容

参考 `_Generic Mod`，保留核心结构，删减游戏专属内容：

- `#define GAME_DEMO 1`——游戏宏（占位项目专属，不与 Generic Mod 的 `GAME_GENERIC` 冲突）
- `#define ENABLE_NGX 1`、`#define ENABLE_FIDELITY_SK 0`、`#define GEOMETRY_SHADER_SUPPORT 0`
- 精简版 `Game` 子类：`OnInit`（设置 cbuffer 槽位 13/12）、`OnCreateDevice`、`OnDrawOrDispatch`（返回 `None`，不拦截）、`OnPresent`、`PrintImGuiAbout`
- `DllMain`：`Globals::SetGlobals`（含版本号 1）+ `CoreMain`
- 不写 DLSS 实际调用逻辑（`SR::SettingsData`/`DrawData`/jitter/相机参数等运行时接入留待真机调试）

### 5. 解决方案文件修改

- `Project(...) = "_Demo", "Source\Games\_Demo\Demo.vcxproj", "{GUID}"` 条目
- `ProjectConfigurationPlatforms` 段：8 配置 × 2 平台 = 16 行 ActiveCfg/Build.0
- `NestedProjects` 段：`{GUID} = {02EA681E-...}`（Games 文件夹）
- GUID 需新生成，避免与现有项目冲突

## 构建验证

1. `git submodule update --init Source/External/reshade`（ReShade 头文件必需）
2. MSBuild 构建 `Development-Release|x64` 与 `Development-Debug|x64`
3. 通过 = DLSS 链接正确、项目结构正确；失败则修复（多为 include/lib 路径）

## 测试策略

- 无单元测试（Luma 项目惯例，以构建 + 实机视觉验证为主）
- 本任务以 **4 配置 × 2 平台全部能编译** 为验证标准（`msbuild Luma.sln /p:Configuration=... /p:Platform=...`）

## 明确不做（YAGNI）

- 不接入《装甲恶鬼村正》（DX9 不兼容）
- 不启用 FSR（`ENABLE_FIDELITY_SK 0`，只做 DLSS 准备）
- 不写 DLSS 运行时调用逻辑
- 不配置 `LUMA_DEMO_BIN_PATH` 环境变量与 VS 调试启动命令（无目标游戏）
- 不添加游戏专属 shader / defines

## 遗留事项

- 未来接入真实 DX11 游戏时：配置 `LUMA_DEMO_BIN_PATH`、替换 shader、按需启用 FSR
