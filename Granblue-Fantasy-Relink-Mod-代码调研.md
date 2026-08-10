# Granblue Fantasy Relink Mod 代码调研

> 调研日期：2026-08-01
> 代码位置：`Source/Games/Granblue Fantasy Relink/`（main.cpp 1512 行 + includes/ 4 个实现文件）
> 作者署名：`PrintImGuiAbout` 注明由 Izueh 开发，开源免费

## 1. 模块概述

Granblue Fantasy Relink（GBFR）mod 是 Luma Framework 的完整参考实现之一：**DLL 注入型 ReShade Addon**。它通过 D3D11 层注入游戏进程，把游戏的**低分辨率渲染 + TAA 管线替换为 DLSS/FSR 超分辨率管线**，并将 tonemap 从 TAA 之前重排到超分之后（HDR mod 的关键）。

### 1.1 文件构成

| 文件 | 职责 |
|---|---|
| `main.cpp` | 入口与生命周期：`Game` 子类、shader hash 登记、`OnDrawOrDispatch` 分流、UI 设置 |
| `includes/hooks.cpp/.hpp` | 游戏函数 inline/mid hook、RVA 地址解析、jitter 捕获与打补丁 |
| `includes/upscale.cpp/.hpp` | 从游戏 shader 绑定中提取超分输入（颜色 t3 / 运动矢量 t23 / 深度 t5） |
| `includes/postprocess.cpp/.hpp` | 被拦截后处理 pass 的捕获/重放（tonemap、motion blur、cutscene、outline） |
| `includes/ui_scale.cpp/.hpp` | UI 相位检测、UI 绘制重定向到全分辨率合成纹理、输出合成 |
| `includes/common.cpp/.hpp` | 纹理按需创建/复用工具函数、`GameDeviceDataGBFR` 状态结构 |
| `includes/cbuffers.h` | `cbSceneBuffer` 场景常量缓冲镜像定义 |
| `includes/safetyhook.*` / `Zydis.*` | 第三方 inline/mid hook 库（safetyhook + Zydis 反汇编器） |

### 1.2 构建宏（main.cpp 顶部）

| 宏 | 作用 |
|---|---|
| `ENABLE_NGX 1` / `ENABLE_FIDELITY_SK 1` | 启用 DLSS（NGX）与 FSR |
| `JITTER_PHASES 8` | jitter 相位数为 8（2 的幂，打补丁后相位掩码要求） |
| `PATCH_JITTER_TABLE_INIT` | 在 TAA 组件初始化时用预计算 Halton 序列重写游戏 jitter 表 |
| `PATCH_SCENE_BUFFER 0` | 场景缓冲补丁开关（当前禁用，代码保留） |
| `ENABLE_UI_VIEWPORT_SCALING_HOOK 0` | UI viewport 缩放 hook 开关（当前禁用；启用时需要 `DispatchRenderPassViewport` + `UIRenderOrchestrator` 两个 RVA） |
| `ENABLE_POST_DRAW_DISPATCH_CALLBACK 1` | 启用 `execute_secondary_command_list` 事件回调（deferred context 流程必需） |
| `CHECK_GRAPHICS_API_COMPATIBILITY 1` | 图形 API 兼容性检查 |
| `DEVELOPMENT` / `TEST` | 调试模式：draw 追踪、期望跳过日志、ESC 暂停快照 |

## 2. 工作原理

### 2.1 入口与框架架构

`DllMain`（`main.cpp:1408`）是入口，Luma 框架本身是 ReShade Addon，因此同时具备两类能力：

1. **ReShade 事件系统**：`reshade::addon_event::execute_secondary_command_list` 回调拿到游戏每个 command list 的执行时机（`main.cpp:110`）。
2. **SafetyHook 直接改写**：inline hook（函数入口跳转）与 mid hook（函数中间机器码位置插入）修改游戏自身函数。

### 2.2 游戏识别：Shader Hash 门卫

游戏的渲染管线由大量 shader 组成。`DllMain` 登记了一批游戏 shader 的 hash（`main.cpp:1417-1438`，如 TAA=`478E345C`、Tonemap=`60F0256B`、MotionBlur=`45841F6D`、TemporalUpscale=`6EEF1071` 等）。框架在每次 draw/dispatch 前把当前 shader hash 与名单比对——`OnDrawOrDispatch` 是这扇门，命中哪个 shader 就走对应的处理逻辑。这些 hash 通过对游戏 dump/反编译获得；`forced_shader_names`（仅 DEVELOPMENT/TEST）提供 hash→名称的可读映射。

### 2.3 Jitter Hook：DLSS 的命根子

DLSS 需要每帧的抖动采样偏移（Halton 序列）来积累时域信息。mod 的策略是**让 DLSS 使用与游戏完全一致的 jitter**：

- **`OnJitterWrite`**（mid hook，`hooks.cpp:96`）：在游戏写入 jitter 的机器码位置拦截寄存器（rcx/rax），缓存当前帧 jitter 值（原子写入，线程安全）。
- **`Hooked_TemporalAntiAliasingComponentInit`**（`hooks.cpp:207`）：TAA 组件初始化后，用 `constexpr` 预计算的 Halton 序列**重写游戏的 64 项 jitter 表**（`PATCH_JITTER_TABLE_INIT`），保证双方 jitter 完全一致。同时从中读取 `jitter_phase_index`（`ctx.rsi + 0x24`）缓存相位索引——注释特别指出不能用 `g_frame_counter`（逻辑线程先于渲染线程 +1，有 off-by-one）。
- **`PatchJitterPhases`**：把游戏代码中相位掩码的立即数（`and cl, 3Fh`）直接改写为 `JITTER_PHASES-1`（无 `PATCH_JITTER_TABLE_INIT` 时的备选路径）。

所有目标地址以 **RVA 硬编码**（`hooks.hpp`），相对 exe 基址（`GetModuleHandleA(nullptr)` + RVA）解析，并保留新旧两个游戏版本（`V1_3_2` 宏切换）的地址表。

### 2.4 分辨率劫持

**`Hooked_InitializeDX11RenderingPipeline`**（`hooks.cpp:197`）每帧被调用，是分辨率控制的核心：

1. 接收屏幕参数（来自 `g_outputWidth/g_outputHeight`，即当前输出分辨率）——顺带更新 `device_data->output_resolution`。
2. 按 `render_scale`（如 75%）计算渲染分辨率，并用 `Math::FindClosestIntegerResolutionForAspectRatio` 保持宽高比整数对齐。
3. **改写 `g_renderWidth/g_renderHeight` 全局变量**为低分辨率——游戏帧图看到 render ≠ output 就会走时域上采样路径。
4. `g_outputWidth/g_outputHeight` 保持不动，UI 仍按全分辨率绘制。

可选 hook `Hooked_DispatchRenderPassViewport`（`ENABLE_UI_VIEWPORT_SCALING_HOOK`）：UI 管线（`OnUIRenderOrchestratorEntry` 记录的状态对象指针）的 viewport 被强制改成输出分辨率，避免 UI 被缩小。

### 2.5 核心：OnDrawOrDispatch 分流逻辑

每帧每个 draw call 都经过 `OnDrawOrDispatch`（`main.cpp:115`），按命中的 shader 分流：

**Bloom draw**：从 `PSGetShaderResources(25, 1)` 提取深度缓冲。

**MotionBlur / MotionBlurDenoise**（`main.cpp:148-177`）：游戏顺序是 运动模糊 → TAA。当开启 `tonemap_after_taa` 时：
- Denoise pass 直接跳过（不再需要为模糊输入去抖动）。
- 运动模糊本身运行两次（不同参数），`CaptureMotionBlurReplayState` 记录每次的 draw 状态，用 `Skip` 跳过原始 draw，标记 `motion_blur_pending`，稍后在主线程用自定义 shader 重放。

**Tonemap**（`main.cpp:179-217`）：
- 从 `t2` SRV 抢走游戏的 **AdaptLuminance 曝光纹理**（提取底层纹理，供 DLSS 作为 exposure hint）；从 `t3` 抢走 **Bloom 纹理**。
- 标记 `tonemap_draw_pending`，原 draw 保留（`None`），真正的替换发生在 `RunLatePostProcessPasses`。

**Cutscene 系列**（Gamma/ColorGrade/OverlayModulate/OverlayBlend，`main.cpp:219-249`）：要求 `tonemap_after_taa` 且同一 device context。`CaptureCutscenePostPassReplayState` 记录状态 → `PassThroughToRenderTarget` 跳过原 draw → 标记 pending → 稍后重放。条件里检查 `tonemap_detected_context == native_device_context` 是为了确保只在 tonemap 已经捕获过的正确上下文中拦截。

**Outline CS**（`main.cpp:251-268`）：`CaptureOutlineReplayState` 记录计算 shader 状态，从 CS 深度 SRV 提取深度，`PassThroughToComputeUAV` 跳过原 dispatch，标记 pending。

**TAA**（`main.cpp:270-411`）——最关键的**分叉点**：
- **启用 SR 且 render_scale ≠ 1**：**完全替换游戏 TAA draw**。`ExtractTAAShaderResources` 从 t3 取颜色、t23 取运动矢量、t5 取深度；`SetupSROutput` 把 TAA 输出 RTV 换成支持 UAV 的超分输出纹理（含 DLSS 最小分辨率检查）；HDR 模式下先跑 `DrawNativePreSREncodePass`（PreSR 编码）。然后 `FinishCommandList` 把之前所有 draw 封进 `partial_command_list`（**流水线截断**）。
- **未启用 SR 且 render_scale ≠ 1**：把 TAA 输出 RTV **偷换成自己的临时纹理**跑一遍原 draw，再换回自己的输出纹理 RTV（`SetupTempTAAOutput`），拿到 TAA 输出供后续使用。
- **render_scale == 1**：TAA 原样运行，超分交给 TUP 路径。

**Temporal_Upscale（TUP）**（`main.cpp:413-505`）：同样在 SR 启用时替换，把 TUP 的 RTV 变成超分输出目标。注释说明 TAA 与 TUP 在并行 deferred context 上录制，`sr_source_color` 在录制时刻不可靠，因此 PreSREncode 延迟到 `OnExecuteSecondaryCommandList`（TAA 列表已在 immediate context 执行后）再画。

**UI 相位检测与输出**（`main.cpp:509-547`，详见 `ui_scale.cpp`）：
- `DetectUIPhase` 判断游戏当前是否在画 UI；是则将 UI draw 重定向到全分辨率合成纹理（`RedirectUIDrawToScaledTarget`）。
- Output pass：deferred context 上捕获状态、封列表、`Skip`；immediate context 上保留游戏原生 draw，仅当 UI 已重定向时**覆盖源 SRV**（把 `scaled_texture_srv` 塞进 slot 0）让游戏原样画完。

### 2.6 双上下文流水线：deferred context 关键路径

GBFR 用 deferred context（多线程渲染）录制命令，再在 immediate context 上 `ExecuteCommandList` 重放。mod 的策略（`main.cpp:551-649`，`OnExecuteSecondaryCommandList`）：

1. TAA/TUP 在 deferred context 上执行时，mod 调用 `FinishCommandList` 把**之前的 draw 全部截断**为 `partial_command_list`（游戏此时尚未画 TAA）。
2. 游戏继续录制剩余命令（`remainder_command_list`）。
3. 当剩余列表要执行时（事件回调中比对指针），mod **先执行 partial 列表**（让 TAA 输出就绪），然后**插入自己的超分 + 后处理 pass**（`RunLatePostProcessPasses`），再让游戏继续画 UI 等。
4. UI 输出同理：`output_partial_command_list` + `ReplayOutputDraw` 合成全分辨率 UI 与 SR 结果。

两个时序问题的处理：
- **jitter 读取时机**：partial 列表重放后、DLSS 与所有自定义 pass 之前（注释：此时游戏必已写入当前帧投影 jitter）。
- **同资源 RTV/SRV 危害**：封列表前先把 `scaled_texture_rtv` 从 RTV 绑定解绑，否则 D3D11 会静默置空同资源的 SRV 绑定。

### 2.7 收尾：RunLatePostProcessPasses

所有自定义 pass 的实际执行点（`postprocess.cpp:1029`），按序：

1. **PreSR Encode**（HDR 模式）：把线性 HDR 颜色编码成 DLSS 需要的格式。
2. **SR 实例更新**：`SR::SettingsData` 填好输入输出分辨率、DRS 关闭、HDR 标志、运动矢量缩放（GBFR 的 MV 未抖动，`mvs_jittered=false`，`mvs_x/y_scale` 为负渲染分辨率）、DLSS 渲染预设；曝光纹理传给 DLSS（`auto_exposure=true` 兜底，注释说明 DLSS 期望 1x1 曝光纹理）。
3. **DLSS/FSR 实际绘制**：`SR::SuperResolutionImpl::DrawData`（source_color、output_color、motion_vectors、depth_buffer、pre_exposure、exposure、jitter）→ `sr_implementations[device_data.sr_type]->Draw(...)`。
4. **替换后的后处理链**：用 `Luma_GBFR_*` 自定义 shader（`OnInit` 里注册：`Luma_GBFR_Tonemap`、`Luma_GBFR_CutsceneGamma`、`Luma_GBFR_CutsceneColorGrade`、`Luma_GBFR_CutsceneOverlayBlend_PS`、`Luma_GBFR_PostSREncode`、`Luma_GBFR_UIEncode`、`Luma_GBFR_PreSREncode`、`Luma_GBFR_FullscreenUV_VS`、`Luma_GBFR_UIBackgroundCopy`）重放被拦截的 pass。

### 2.8 TonemapAfterTAA 模式：为什么需要整套拦截

游戏原始顺序：运动模糊 → TAA → **tonemap**。HDR 模式下，tonemap 会把 HDR 信息压到 SDR，DLSS 就没有 HDR 输入可用。mod 的解法：**跳过游戏的 tonemap draw，推迟到 SR 之后执行**——这就是 `TONEMAP_AFTER_TAA` shader define（`main.cpp:62-64`，默认开启，可在 UI 关闭）和整套"捕获-跳过-重放"框架存在的意义。`cb_luma_global_settings.GameSettings.IsTAARunning` 与 `UpdateLumaInstanceDataCB` 中 `JitterOffset` 的换算（x/y 2.0f/分辨率、y 取负）把 jitter 以 NDC 归一化单位传播给所有自定义 shader 调用。

### 2.9 每帧状态重置与故障保护

`OnPresent`（`main.cpp:720`）是每帧的收尾/重置点：
- 所有 pending 标志、replay state、纹理引用、context 指针清空（`Reset`/`store(nullptr)`）；`remainder_command_list`、`draw_device_context` 复位。
- **MIP LOD bias**：SR 启用时 `texture_mip_lod_bias_offset = SR::GetMipLODBias(render_y, output_y)`（输出分辨率下为 -1），否则为 0——补偿低分辨率渲染导致的纹理模糊。
- `render_scale_changed` → `force_reset_sr`（SR 状态强制重置）。
- **SR 未绘制检测**：`!device_data.has_drawn_sr` → `force_reset_sr`（DLSS 状态机失步的兜底）。
- DEVELOPMENT 模式 ESC 键暂停快照（记录分辨率、jitter、TAA 设置对象字节位，用于调试）。

### 2.10 设置与 UI

- `LoadConfigs`（`main.cpp:866`）：从 ReShade 配置读 RenderScale 与全部色彩分级参数（Exposure、Highlights、ShadowContrast、Gamma、Saturation、Dechroma、BloomStrength 等）。
- `DrawImGuiSettings`（`main.cpp:890`）：ImGui 滑块（Render Scale 50–100%、色彩分级树节点），改动即写回配置。
- `DrawImGuiDevSettings` / `PrintImGuiInfo`：仅 DEVELOPMENT/TEST——直接读取引擎全局（TAA 设置对象字节位判断 TAA 启用/超分禁用/DRS 状态）、jitter 相位、地址表，并断言 `table_jitter == camera jitter` 的一致性。
- `PrintImGuiAbout`：作者信息（Izueh）、ko-fi 捐赠链接、HDR Den Discord、GitHub。

### 2.11 其他机制

- **格式升级**：swapchain 升级到 scRGB（`SwapchainUpgradeType::scRGB`）；`texture_upgrade_formats` 列出 r8g8b8a8_unorm/typeless、r11g11b10_float、r10g10b10a2_unorm 四类纹理格式，`texture_format_upgrades_2d_size_filters` 限定仅升级 swapchain 分辨率与纵横比的 2D 纹理。
- **`PatchSceneBufferInHook`**（`hooks.cpp`，`PATCH_SCENE_BUFFER 0` 未启用）：用计算 shader 把 `cbSceneBuffer` 复制到临时 UAV、修改后再 CopySubresourceRegion 写回——场景缓冲注入的保留实现，HDR 链需要时启用。
- **DLL 卸载**（`main.cpp:1498`）：`DLL_PROCESS_DETACH` 时释放全部 hook、注销事件回调。

## 3. 设计决策

1. **Jitter 一致性优先**：DLSS 与游戏 TAA 必须共享同一 jitter 序列，否则时域积累互相抵消。通过重写游戏 jitter 表 + 寄存器级捕获实现，而非让 DLSS 自选序列。
2. **流水线截断而非管线注入**：利用 deferred context 的 `FinishCommandList` 在 TAA 前自然截断，让自定义 pass 在 TAA 输出就绪后插入——避免用 ReShade 的 addon 管线注入机制（与游戏的并行录制模型冲突）。
3. **事件回调比对指针而非包装函数**：`OnExecuteSecondaryCommandList` 通过 `ui_finish_command_list` / `output_remainder_command_list` / `remainder_command_list` 的指针相等判断"哪个列表在何时执行"，避免嵌套包装 deferred context。
4. **捕获-跳过-重放（Capture-Skip-Replay）模式**：对 motion blur / cutscene / outline 等 pass，录制完整 draw 状态（shader、SRV、RTV、顶点缓冲、常量），跳过原 draw，稍后按需重放——让自定义 shader 复用游戏的原生输入。
5. **延迟执行 PreSREncode**：TAA 与 TUP 在并行 deferred context 录制，`sr_source_color` 不可靠——编码 pass 延迟到列表重放后（`RunLatePostProcessPasses`）执行。
6. **只改数据不改代码路径**（分辨率）：改写 `g_renderWidth/g_renderHeight` 让游戏帧图自走上采样路径，`g_outputWidth/g_outputHeight` 保持不动，UI 依然全分辨率。
7. **RVA 硬编码 + 版本切换**：所有 hook 目标与全局变量以 RVA 硬编码，`V1_3_2` 宏切换新旧二进制地址表；游戏更新导致地址失效时只改常量表。
8. **原子状态 + SEH 保护**：跨线程状态（pending 标志、context 指针、jitter 缓存）全部原子变量；`IsTAARunningThisFrame` 用 `__try/__except` 防暂停/重建期间的悬空指针，保留最后已知值。

## 4. 测试策略

- **无单元测试套件**：与整个 Luma 项目一致，以图形/视觉验证为主（实机运行看画面）。
- **运行时断言与日志**：`ASSERT_ONCE_MSG`（如 jitter 表值 ≠ 相机投影 jitter 的校验）、`LogExpectedCustomDrawSkipped`（TEST/DEVELOPMENT 下记录"预期跳过但未发生"的 draw）。
- **DEVELOPMENT 调试工具**：ESC 暂停快照、`PrintImGuiInfo` 地址/状态表、draw 追踪日志。
- **手动验证路径**：无 SR / SR（DLSS/FSR）/ render_scale == 1 / 切分辨率 / 切 HDR 开关 / 过场动画（cutscene）各分支的组合测试。

## 5. 不在范围内

- 场景缓冲注入（`PATCH_SCENE_BUFFER` 的 `PatchSceneBufferInHook`）——已实现但默认禁用。
- UI viewport 缩放 hook（`ENABLE_UI_VIEWPORT_SCALING_HOOK`）——已实现但默认禁用（当前用 RTV/SRV 覆盖方案）。
- 新版（PR #149 / v2.0.2）之外的游戏版本适配——`V1_3_2` 宏已含旧版地址表，但仅维护两个版本。

## 6. 进一步说明

- 代码注释质量极高：每个 hook、每个时序决策、每个"为什么不用 X"都有解释（如 g_frame_counter off-by-one、RTV/SRV 危害、DLSS 曝光纹理 1x1 限制），是理解 Luma 框架 deferred context 流程的最佳入口。
- 与 Prey mod（单线程、无 TUP 路径）相比，GBFR 是"多 deferred context + 截断重放"这一复杂模式的代表；新游戏接入时优先参考 `_Template` 与 Prey，只有遇到类似 GBFR 的并行录制结构才需要本模式。
- `ui_scale.cpp` / `postprocess.cpp` 中的"捕获-重放"结构可提炼为框架级工具（当前每个游戏各实现一份）。
