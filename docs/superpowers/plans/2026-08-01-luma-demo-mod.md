# _Demo 占位模组实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Luma-Framework 仓库新建 `_Demo` 通用占位模组项目（DLSS 接入就绪），并验证 4 配置 × 2 平台全部能编译。

**Architecture:** 复制现有 `_Generic Mod` 项目的 vcxproj/filters 为 `_Demo`，替换 ProjectGuid/ProjectName，按现有 DLSS 游戏（Batman Arkham Knight）的精确模式给 x64 的 4 个配置追加 NGX 依赖；main.cpp 改为精简骨架（`GAME_DEMO` + `ENABLE_NGX 1`）；Luma.sln 添加项目条目与配置映射。

**Tech Stack:** C++（stdcpplatest）、MSBuild（VS 2026 Build Tools 18.7）、HLSL、NGX SDK（`Source/External/NGX`）、ReShade Addon API。

## Global Constraints

- 项目位于 `Source\Games\_Demo\`，项目名 `_Demo`，文件 `Demo.vcxproj` / `Demo.vcxproj.filters` / `main.cpp`
- 复制来源：`Source\Games\_Generic Mod\Generic Mod.vcxproj`（保留 8 配置 × 2 平台全结构、`stdcpplatest`、`/utf-8`、`PROJECT_NAME="$(ProjectName)"`、`DEVELOPMENT=1` 等）
- 新 ProjectGuid 必须唯一（不得与现有 56 个项目冲突，含 `{08143144-3ABB-D7B3-815C-7B798924E8E6}`）
- **NGX 只加在 x64 的 4 个配置**（Development-Debug|Test|Publishing|Development-Release 的 x64），Win32 4 个配置不加（NGX 仅支持 x64；`DLSS.h` 在非 `_WIN64` 时自动禁用 `ENABLE_NGX`）——照抄 Batman Arkham Knight.vcxproj 已验证的逐配置模式
- x64 配置 Link 追加：Debug 用 `nvsdk_ngx_d_dbg.lib`，其余 3 个 Release 用 `nvsdk_ngx_d.lib`；Include 追加 `..\..\External\NGX`；LibraryDirs 追加 `..\..\External\NGX\libs`
- main.cpp：`#define GAME_DEMO 1`、`#define ENABLE_NGX 1`、`#define ENABLE_FIDELITY_SK 0`、`#define GEOMETRY_SHADER_SUPPORT 0`；不含 DLSS 运行时调用逻辑
- 构建验证标准：`msbuild Luma.sln /p:Configuration=<cfg> /p:Platform=<plat>` 全部 8 组合成功（`Development-Debug`、`Development-Release`、`Test-Release`、`Publishing-Release` × `x64`、`Win32`）
- ReShade 子模块已就绪（`Source/External/reshade` v6.7.3，嵌套子模块已克隆）；DKUtil 子模块无需初始化（仅 Prey 用）
- 提交信息风格参照仓库惯例（`git log --oneline` 为简短单行，如 `docs: add _Demo placeholder mod design spec`）

---

### Task 1: 创建 _Demo 项目文件（vcxproj + filters + main.cpp）

**Files:**
- Create: `Source\Games\_Demo\Demo.vcxproj`
- Create: `Source\Games\_Demo\Demo.vcxproj.filters`
- Create: `Source\Games\_Demo\main.cpp`

**Interfaces:**
- Consumes: `Source\Games\_Generic Mod\Generic Mod.vcxproj`（复制源）、`Source\Games\_Generic Mod\main.cpp`（骨架参考）、NGX SDK 位于 `Source\External\NGX\`（头文件 + `libs\nvsdk_ngx_d.lib`/`nvsdk_ngx_d_dbg.lib`）
- Produces: `Demo.vcxproj`（含 `ProjectGuid {XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}` 占位待替换）、`Demo.vcxproj.filters`、`main.cpp`——供 Task 2 填入唯一 GUID 和供 Task 3 构建

- [ ] **Step 1: 复制源文件并改名**

```bash
cd E:/Code/pj/Luma-Framework
mkdir -p "Source/Games/_Demo"
cp "Source/Games/_Generic Mod/Generic Mod.vcxproj" "Source/Games/_Demo/Demo.vcxproj"
cp "Source/Games/_Generic Mod/Generic Mod.vcxproj.filters" "Source/Games/_Demo/Demo.vcxproj.filters"
```

- [ ] **Step 2: 生成新 GUID**

```bash
powershell -Command "[guid]::NewGuid().ToString().ToUpper()"
```

- [ ] **Step 3: 改写 Demo.vcxproj**

用 Write 工具整体重写 `Source\Games\_Demo\Demo.vcxproj`，内容 = `Generic Mod.vcxproj` 全文，但做以下修改（在 Step 2 拿到 GUID 后填入）：

1. `<ProjectGuid>{08143144-3ABB-D7B3-815C-7B798924E8E6}</ProjectGuid>` → `<ProjectGuid>{新GUID}</ProjectGuid>`
2. `<ProjectName>_Generic Mod</ProjectName>` → `<ProjectName>_Demo</ProjectName>`
3. 每个 `PostBuildEvent` 中 `LUMA_GENERIC_MOD_BIN_PATH` → `LUMA_DEMO_BIN_PATH`（共 8 处，`IF DEFINED LUMA_DEMO_BIN_PATH ( xcopy /Y "$(TargetDir)*$(SolutionName)-$(ProjectName).addon" "%LUMA_DEMO_BIN_PATH%" || exit /B 0 )`）
4. **x64 的 4 个 ItemDefinitionGroup**（Condition 为 `Development-Debug|x64`、`Publishing-Release|x64`、`Test-Release|x64`、`Development-Release|x64`）：
   - `ClCompile\AdditionalIncludeDirectories`：`..\..\External\reshade;%(AdditionalIncludeDirectories)` → `..\..\External\reshade;..\..\External\NGX;%(AdditionalIncludeDirectories)`
   - `Link\AdditionalDependencies`：空 → `nvsdk_ngx_d_dbg.lib`（Development-Debug）或 `nvsdk_ngx_d.lib;`（其余 3 个，与 Batman 的 `nvsdk_ngx_d.lib;` 带分号格式一致）
   - `Link\AdditionalLibraryDirectories`：空 → `..\..\External\NGX\libs;%(AdditionalLibraryDirectories)`
   - Win32 的 4 个配置**保持不变**（无 NGX）
5. `ClCompile Include="..\..\Core\unity_build.cpp"` 与 `main.cpp` 保持原样

- [ ] **Step 4: 改写 Demo.vcxproj.filters**

用 Write 工具写入（与 Generic Mod 的 filters 相同，仅文件名变化，内容一致）：

```xml
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="4.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
    <ClCompile Include="main.cpp" />
    <ClCompile Include="..\..\Core\unity_build.cpp" />
  </ItemGroup>
</Project>
```

- [ ] **Step 5: 编写 main.cpp**

用 Write 工具写入 `Source\Games\_Demo\main.cpp`（精简 Generic Mod 骨架，不包含 DrawImGuiSettings 和 texture 升级 UI 逻辑）：

```cpp
#define GAME_DEMO 1

#define ENABLE_NGX 1

#define ENABLE_FIDELITY_SK 0
#define GEOMETRY_SHADER_SUPPORT 0

#include "..\..\Core\core.hpp"

struct DemoGameDeviceData final : public GameDeviceData
{
};

class DemoGame final : public Game
{
   static DemoGameDeviceData& GetGameDeviceData(DeviceData& device_data)
   {
      return *static_cast<DemoGameDeviceData*>(device_data.game);
   }

public:
   void OnInit(bool async) override
   {
      luma_settings_cbuffer_index = 13;
      luma_data_cbuffer_index = 12;
   }

   void OnCreateDevice(ID3D11Device* native_device, DeviceData& device_data) override
   {
      device_data.game = new DemoGameDeviceData;
   }

   DrawOrDispatchOverrideType OnDrawOrDispatch(ID3D11Device* native_device, ID3D11DeviceContext* native_device_context, CommandListData& cmd_list_data, DeviceData& device_data, reshade::api::shader_stage stages, const ShaderHashesList<OneShaderPerPipeline>& original_shader_hashes, bool is_custom_pass, bool& updated_cbuffers, std::function<void()>* original_draw_dispatch_func) override
   {
      auto& game_device_data = GetGameDeviceData(device_data);

      return DrawOrDispatchOverrideType::None; // Don't cancel the original draw call
   }

   void OnPresent(ID3D11Device* native_device, DeviceData& device_data) override
   {
   }

   void PrintImGuiAbout() override
   {
      ImGui::Text("Demo Luma mod - placeholder project", "");
   }
};

BOOL APIENTRY DllMain(HMODULE hModule, DWORD ul_reason_for_call, LPVOID lpReserved)
{
   if (ul_reason_for_call == DLL_PROCESS_ATTACH)
   {
      const char* project_name = PROJECT_NAME;
      const char* cleared_project_name = (project_name[0] == '_') ? (project_name + 1) : project_name; // Remove the potential "_" at the beginning

      uint32_t mod_version = 1;
      Globals::SetGlobals(cleared_project_name, "Demo Luma mod", "https://github.com/Filoppi/Luma-Framework/", mod_version);

      game = new DemoGame();
   }

   CoreMain(hModule, ul_reason_for_call, lpReserved);

   return TRUE;
}
```

- [ ] **Step 6: 验证文件内容**

Run:
```bash
cd E:/Code/pj/Luma-Framework
grep -c "LUMA_DEMO_BIN_PATH" "Source/Games/_Demo/Demo.vcxproj"
grep -c "nvsdk_ngx" "Source/Games/_Demo/Demo.vcxproj"
grep -n "ProjectGuid\|ProjectName" "Source/Games/_Demo/Demo.vcxproj"
```
Expected: 第一行 `8`（8 处 PostBuildEvent）；第二行 `8`（4 配置 × include+libs 各一次 = 8）；第三行显示新 GUID 和 `_Demo`。同时确认 Win32 4 配置中无 `nvsdk_ngx` 出现（`grep -c "nvsdk_ngx"` 仅来自 x64 组）。

- [ ] **Step 7: Commit**

```bash
git add "Source/Games/_Demo/"
git commit -m "feat: add _Demo placeholder mod project with DLSS-ready config"
```

---

### Task 2: 将 _Demo 加入 Luma.sln

**Files:**
- Modify: `Luma.sln`（3 处：项目条目、配置映射、NestedProjects）

**Interfaces:**
- Consumes: Task 1 的 `Demo.vcxproj` 与其 `ProjectGuid {新GUID}`
- Produces: 完整解决方案条目，供 Task 3 直接构建

- [ ] **Step 1: 添加项目条目**

在 `Luma.sln` 中，找到 `Project(...) = "_Generic Mod", ...` 的 `EndProject` 行（第 41 行附近），在其后插入：

```
Project("{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}") = "_Demo", "Source\Games\_Demo\Demo.vcxproj", "{新GUID}"
EndProject
```

- [ ] **Step 2: 添加配置映射**

在 `GlobalSection(ProjectConfigurationPlatforms)` 中（`{08143144-3ABB-D7B3-815C-7B798924E8E6}` 即 _Generic Mod 的 16 行之后），插入 16 行（注意 `_Demo` 是普通 DLL 项目，Win32 配置是真实平台，非 Prey 式 x64-only 映射）：

```
		{新GUID}.Development-Debug|Win32.ActiveCfg = Development-Debug|Win32
		{新GUID}.Development-Debug|Win32.Build.0 = Development-Debug|Win32
		{新GUID}.Development-Debug|x64.ActiveCfg = Development-Debug|x64
		{新GUID}.Development-Debug|x64.Build.0 = Development-Debug|x64
		{新GUID}.Development-Release|Win32.ActiveCfg = Development-Release|Win32
		{新GUID}.Development-Release|Win32.Build.0 = Development-Release|Win32
		{新GUID}.Development-Release|x64.ActiveCfg = Development-Release|x64
		{新GUID}.Development-Release|x64.Build.0 = Development-Release|x64
		{新GUID}.Publishing-Release|Win32.ActiveCfg = Publishing-Release|Win32
		{新GUID}.Publishing-Release|Win32.Build.0 = Publishing-Release|Win32
		{新GUID}.Publishing-Release|x64.ActiveCfg = Publishing-Release|x64
		{新GUID}.Publishing-Release|x64.Build.0 = Publishing-Release|x64
		{新GUID}.Test-Release|Win32.ActiveCfg = Test-Release|Win32
		{新GUID}.Test-Release|Win32.Build.0 = Test-Release|Win32
		{新GUID}.Test-Release|x64.ActiveCfg = Test-Release|x64
		{新GUID}.Test-Release|x64.Build.0 = Test-Release|x64
```

- [ ] **Step 3: 添加 NestedProjects 映射**

在 `GlobalSection(NestedProjects)` 中（`{08143144-3ABB-D7B3-815C-7B798924E8E6} = {02EA681E-...}` 行之后）插入：

```
		{新GUID} = {02EA681E-C7D8-13C7-8484-4AC65E1B71E8}
```

- [ ] **Step 4: 验证解决方案条目**

Run:
```bash
cd E:/Code/pj/Luma-Framework
grep -c "_Demo" Luma.sln
grep -c "{新GUID}" Luma.sln
```
Expected: 第一行 `1`（1 个项目条目，注意 `_Demo` 只出现在项目名）；第二行 `17`（条目 1 + 配置 16）。再跑一次 VS 无关的语法检查：
```bash
grep -c "Project(" Luma.sln
```
Expected: `57`（56 + 1 新增）。

- [ ] **Step 5: Commit**

```bash
git add Luma.sln
git commit -m "build: add _Demo project to solution"
```

---

### Task 3: 构建验证（8 配置 × 2 平台）

**Files:**
- 只读验证，无文件修改（除非修复构建错误）

**Interfaces:**
- Consumes: Task 1 的 `Demo.vcxproj`、Task 2 的 `Luma.sln`
- Produces: 全部 8 组合构建成功的验证结果

- [ ] **Step 1: 确认 MSBuild 可用**

```bash
"/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe" -products * -requires Microsoft.Component.MSBuild -property installationPath
```
Expected: 输出 `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools`（已安装，18.7.11925.98）。若 vswhere 找不到 MSBuild，用 `C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\MSBuild\Current\Bin\MSBuild.exe` 全路径。

- [ ] **Step 2: 构建 Development-Release|x64**

```bash
MSBUILD="C:/Program Files (x86)/Microsoft Visual Studio/18/BuildTools/MSBuild/Current/Bin/MSBuild.exe"
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Development-Release //p:Platform=x64 //t:"_Demo"
```
Expected: `_Demo` 项目编译+链接成功（`Luma-_Demo.addon` 生成于 `Binaries\x64-Development-Release\`）。用 `//t:"_Demo"` 限定目标，避免构建全部 53 个项目。若需验证解决方案级集成，可去掉 `//t:"_Demo"` 跑一次完整构建（其他游戏项目可能因本机环境失败，只看 `_Demo` 行）。

- [ ] **Step 3: 构建 Development-Debug|x64（验证 nvsdk_ngx_d_dbg.lib 链接）**

```bash
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Development-Debug //p:Platform=x64 //t:"_Demo"
```
Expected: `_Demo` 编译+链接成功，无 `LNK1104 cannot open file 'nvsdk_ngx_d_dbg.lib'` 错误。

- [ ] **Step 4: 构建 Test-Release|x64 与 Publishing-Release|x64**

```bash
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Test-Release //p:Platform=x64 //t:"_Demo"
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Publishing-Release //p:Platform=x64 //t:"_Demo"
```
Expected: 两者均成功（分别验证 `TEST=1` 和 `NDEBUG` + WPO 配置下的 NGX 链接）。

- [ ] **Step 5: 构建 Win32 平台（无 NGX 配置）**

```bash
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Development-Release //p:Platform=Win32 //t:"_Demo"
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Development-Debug //p:Platform=Win32 //t:"_Demo"
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Test-Release //p:Platform=Win32 //t:"_Demo"
"$MSBUILD" "E:/Code/pj/Luma-Framework/Luma.sln" //p:Configuration=Publishing-Release //p:Platform=Win32 //t:"_Demo"
```
Expected: 4 个 Win32 配置全部成功（无 NGX 依赖，验证 32 位工具链与 `WIN32` 宏路径）。

- [ ] **Step 6: 验证产物**

Run:
```bash
cd E:/Code/pj/Luma-Framework
ls Binaries/x64-Development-Release/ | grep -i demo
ls Binaries/Win32-Development-Release/ | grep -i demo
```
Expected: 各输出 `Luma-_Demo.addon`（x64 和 Win32 各一个；Debug 构建产物在 `Binaries\x64-Development-Debug\` 类似路径）。

- [ ] **Step 7: 记录结果（无提交——构建产物不入库）**

无需 git 操作。如某配置失败，回到 Task 1 修复 vcxproj 后重跑；全部通过则计划完成。
