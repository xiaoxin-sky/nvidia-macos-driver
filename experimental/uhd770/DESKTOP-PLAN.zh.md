# UHD 770 桌面合成与加速：调研结论与移植计划（2026-10-28）

范围：只读调研，没有改动驱动，也没有上机。依据是三份材料：
- VedCloud/Meteor-Lake-Xe-LPG-Metal-Graphics 仓库：README、`desktop-sources/` 的构建与发布脚本、`NullMoth-Xe/` 的补丁清单；
- 本仓库上游 NullMoth 的 `docs/HOW-IT-WORKS.md` 和 `kexts/`；
- 我们自己 r25–r28 的报告和插件源码（fd917ea）。

注意：参考项目的代码只读了关键文件的开头和说明，没有逐行读完。下面的结论用于确定方向，动手移植之前，还要逐个文件细读。

## 1. 参考项目实际是怎么做的

### NullMoth 上游（本仓库的来源）
- 只有 NVIDIA 显卡走完整的 GPU 桌面路线，涉及 NVRMFB（IOFramebuffer，基于 NVKMS 做模式设置）、NVAccel、NVRMAGDC。
- 对 Intel 和 AMD 是"headless"方式：应用在 GPU 上渲染，结果复制进 WindowServer 读取的 IOSurface；WindowServer 自己仍然在 CPU 上合成。这和我们 r25 日志里插件拒绝 WindowServer 的表现一致（`headless GPU: no device for WindowServer`）。
- 本仓库里已经有 `kexts/NMIntelFB/intelfb.cpp`，适用于显示版本 12–20 的 Intel 显卡，包括 Alder Lake。它直接接管固件已经点亮的显示模式：找到正在扫描输出的 pipe，确认主平面是线性 32 位 XRGB，再通过显存窗口（BAR2 加 GGTT 偏移）把这块画面发布成 IOFramebuffer。它**不写显示引擎的任何寄存器**；遇到不认识的配置，就让 start() 失败并记日志，屏幕保持原样。
  - 它原本是为笔记本内屏写的，台式机外接显示器能不能用还没验证。
  - 许可证是 PolyForm-Noncommercial-1.0.0。

### Meteor Lake 笔记本（Latitude 5350，已实现流畅的 GPU 桌面）
- **不让 i915 做模式设置。** 屏幕继续由固件（GOP）点亮的那块帧缓冲扫描输出。
  - `latitude_scanout.h` 会核对 GOP 地址、stolen 内存（DSM/GSM）和 GGTT 页表，确认它们指向同一块连续的扫描输出区域。
- **帧缓冲 kext：LatitudeMTLFB。** 它由 `NullMoth/kexts/NMXVGAFB/nmxvgafb.cpp` 加上 `-DLATITUDE_MTL_PANEL` 编译而来，负责 GPU 身份、gamma、EDID 和共享内存上报。
  - 0.3.19 加入了"scanout copy"：把 WindowServer 在 GPU 上合成好的画面复制进固件扫描输出的那块缓冲。
- **内核 1.0.15 在 stolen 内存里预留了固件开机画面**，避免 i915 启动时把正在显示的帧缓冲覆盖掉（他们为此出过一次 panic，在 1.0.13）。
- **插件：** 新增 `nvmtl_desktop_policy.h`，按厂商、设备 ID 和进程名放行 WindowServer。WindowServer 的 GPU 提交改成串行。之后还做了命令池生命周期、隔离不确定的完成状态、管线缓存等优化（0.3.x 系列）。
- **推进方法：** 先建立应用级测试门槛（22 个用例），再一次只改一个变量地调 WindowServer，调试时抓取 GPU ring。
- **安全设置：** `csr-active-config=0x0A43`、AMFIPass、`amfi_get_out_of_my_way=0x1`。

### NullMoth-Xe（Panther Lake 虚拟机，GPU 合成 120 Hz）
- 47 个补丁打在 nvidia-macos-driver 2.0.2（d96eaca）上，新增 NMXVGAFB 和 NMXAGDC，并改了插件和 NMXAccel。显示走 virtio-gpu，不能直接用在实机上。
- 其中**插件和 NMXAccel 的部分**和硬件无关，可以参考，例如：
  - 0016：WindowServer 的 commitAndWaitUntilSubmitted；
  - 0025：集成显卡上的 IOSurface 纹理；
  - 0027：Apple GL 渲染器；
  - 0042：WindowServer 的 To_Accelerated；
  - 0045：沙盒进程使用 GPU；
  - 0046：给 WindowServer 预留显存槽。

## 2. 对我们的意义：风险更低的路线

原先以为第 6 步必须让 i915 接管显示、自己做模式设置，这是最可能黑屏的一步。两个参考项目都说明可以绕开：

> 屏幕继续由固件点亮的模式扫描输出，帧缓冲 kext 只是把这块画面发布给 macOS；WindowServer 在 GPU 上合成，结果写进或复制进这块扫描输出缓冲。

这样不需要改显示引擎寄存器，最坏情况是帧缓冲 kext 拒绝启动，回到现在的 `-igfxvesa` 画面。

## 3. 建议的移植顺序（每步都能退回安全启动）

| 步骤 | 内容 | 风险 | 是否要上机 |
|---|---|---|---|
| A | 第 4 步的 Metal 测试套件（纹理/混合/深度/1920×1080/IOSurface），已写好待提交 | 低 | 1 次 |
| B | 细读 NMIntelFB、NMXVGAFB/LatitudeMTLFB 的扫描输出接管代码和 `latitude_scanout.h`，确认 ADL-S 台式机外接显示器下 GOP、stolen 内存、GGTT 的对应关系 | 无 | 否 |
| C | 只读诊断：在测试启动里记录固件点亮的 pipe、平面格式、地址和 stolen 内存范围，不写任何寄存器 | 低 | 1 次 |
| D | 移植"预留固件开机画面"（参考 1.0.15），确认 i915 启动后画面不被覆盖 | 中 | 1–2 次 |
| E | 帧缓冲 kext 接管固件模式，发布成 IOFramebuffer；仍然由 CPU 合成，先验证"能显示、能退回" | 中 | 1–2 次 |
| F | 插件放行 WindowServer（参考 `nvmtl_desktop_policy.h` 和串行提交），每次只改一个变量 | 高 | 多次 |
| G | 流畅度和稳定性：命令池、管线缓存、长时间运行、睡眠唤醒 | 中 | 多次 |

## 3.1 B 步结论（2026-10-28）
- **我们的 NMXGPU 里已经有一套 i915 模式设置的显示桥**：`override/src/nmx_fb_bridge.c`（DRM 客户端：探测接口、分配 XRGB8888 缓冲、指向每个点亮的 CRTC）、`override/i915/nmx_i915_scanout.c`（GGTT 固定和 CPU 窗口映射）、`xnu/nmx_fb.cpp`（NMXGPUFB，一个 IOFramebuffer）。
  - 硬件提交被推迟到 WindowServer 打开它、调用 `enableController` 之后。r29 的注册表里是 `nmxdiag-display-state = awaiting-native-open`，WindowServer 仍在用固件画面，所以这套代码一直没有真正生效。
  - 走这套代码就是"i915 自己做模式设置"，也就是高风险路线。r9 测试期间出现过黑屏和 `IOFramebuffer::powerStateWillChangeTo` 的 panic（见 MAINLINE-CHECKPOINT.txt 第 4 节）。
- **NMIntelFB 的接管方式**：遍历 pipe A–D，找到 TRANSCONF 和平面 1 都启用的那个；要求平面格式是线性的 XRGB8888（format 8、tiling 0），读出宽高、步长、SURF（GGTT 偏移）和时序，统计 250 ms 内的 vblank 次数来测刷新率，再通过 BAR2 加 SURF 把表面发布出去。全程只读。
- **C 步诊断的设计**：在 NMXGPU 的 `port.before`（i915 接管之前）和 `attach.complete` 之后，各做一次只读快照，包括每个 pipe 的 TRANSCONF、PLANE_CTL/SIZE/STRIDE/SURF、HTOTAL/VTOTAL、100 ms 内的 vblank 次数、表面的 GGTT 页表项（BAR0+8 MiB），以及 BDSM（stolen 内存基址）和 BAR2 范围。结果写进内核日志（`NullMoth display-snapshot …`）和 NMXGPU 的注册表属性（`nmxdiag-display-firmware` 和 `nmxdiag-display-attached`）。两次快照对比，能看出固件画面在哪里、i915 接管后有没有被改动。

## 3.2 C 步结果（r30，2026-10-29）
- 固件只点亮了 **pipe A**：1920×1080，时序 2200×1125（约 148.5 MHz，即 1080p60），100 ms 内有 6 次 vblank。
- 主平面：PLANE_CTL 0x84000008，即启用、XRGB8888、线性（tiling 0）。步长 0x78×64 = 7680 字节，正好是 1920×4。这符合 NMIntelFB 的接管条件。
- 表面在 GGTT 偏移 0，页表项 0x7c800001 指向物理地址 0x7c800000，也就是 BDSM（stolen 内存起点）。固件画面就在 stolen 内存最前面。BAR2 显存窗口是 0x4000000000，大小 256 MiB。
- i915 接管后：
  - pipe A 仍然启用，尺寸、步长、表面地址和时序都没变，vblank 也照常计数。
  - 但有几处寄存器被改过：pipe A 的 TRANSCONF 低位 0x24 被清掉，PLANE_CTL 的 bit 3 被清掉；pipe D 的 TRANSCONF 从 0 变成 0x24。所以接管之后，i915 并不是完全没写显示寄存器。用户确认整个测试过程中屏幕没有闪烁或短暂黑屏。
- 诊断本身的局限：没点亮的 pipe 的 SURF 也是 0，所以它们打出的页表项其实是 pipe A 的，没有意义。
- 对 D 步的意义：固件画面占着 stolen 内存的开头，i915 的 stolen 分配器有可能把这块再分出去，参考项目 1.0.13 的 panic 就是这个原因。下一步应确认 i915 有没有把这块预留下来，并在测试前后读画面内容的校验值，确认没被覆盖。

## 3.3 D 步：先确认，再决定要不要移植（2026-10-29）
- 上游 i915 本身就会原地接管固件画面：`intel_display_driver_probe_nogem` 之后调用 `intel_initial_plane_config`（`display/intel_plane_initial.c`），用 `i915_gem_object_create_region_at(stolen, phys_base, size, I915_BO_PREALLOC)` 把那块 stolen 内存预留成一个 GEM 对象，固定在 GGTT 偏移 0，再挂到主平面上。注释里写明了目的：防止 ring 等其他 stolen 分配压到上面。
  - 如果预留失败，它会调用 `intel_plane_disable_noatomic` 关掉主平面。r30 接管后主平面仍然开着，这间接说明预留成功了，但日志里没有直接证据，因为 drm 调试输出是关的。
- 参考项目 1.0.15 补的那一步，在我们这里可能已经由上游代码完成。所以先做只读确认（r31），确认之后再决定是否需要移植。
- r31 的诊断：i915 接管完成后，记录每个活动 pipe 主平面的 framebuffer、GGTT 偏移、它在 stolen 里的范围、是否带 PREALLOC 标记，以及 stolen 里一共有多少个分配、其中多少个和画面那块重叠（正常应该只有画面自己，也就是 1 个）。结果写进内核日志（`NullMoth display-i915`）和注册表属性 `nmxdiag-display-i915`。全程只读，不写任何寄存器。

### D 步结果（r31，2026-10-29）
- 四个测试阶段全部通过，没有 panic，和 r30 比没有回归。固件快照和接管后的快照都和 r30 一致。
- `nmxdiag-display-i915`：
  `dsm=0x7c800000+0x4000000 usable=0x3e00000; pipe A fb=1920x1080 pitch=7680 ggtt=0x0 stolen=0x0+0x7e9000; stolen-nodes=2 overlapping-fb=1`
  - stolen 内存共 64 MiB，可用 62 MiB。
  - i915 把固件画面原地接管成了 pipe A 主平面的 framebuffer：位于 stolen 偏移 0，大小 0x7e9000，正好等于 1920×1080×4；GGTT 偏移仍是 0。
  - stolen 里另外只有一个分配，而且和画面不重叠（overlapping-fb=1，只有画面自己）。
  - 报告里没有 `prealloc`，这是诊断代码判断条件写错了，不说明预留失败：stolen 对象创建时会把标记覆盖成只剩 `I915_BO_ALLOC_CONTIGUOUS`（`gem/i915_gem_stolen.c` 的 `__i915_gem_object_create_stolen`）。原地预留走的是 `drm_mm_reserve_node`，上面的偏移和大小已经证明了这一点。
- 结论：固件画面已经由上游 i915 保护好了，D 步**不需要移植**参考项目 1.0.15 的补丁。可以进入 E 步。
- 对 E 步的意义：i915 的主平面已经持有一个指向固件画面的 framebuffer 对象。比起另外写一个读寄存器的帧缓冲 kext（NMIntelFB 的做法），E 步可以让我们现有的 NMXGPUFB 直接发布这个已有的 framebuffer（通过 BAR2 显存窗口加 GGTT 偏移 0 访问），不分配新缓冲，也不做模式设置。

## 3.4 E 步：设计（2026-10-29，未实现）
**现状为什么不行。** NMXGPUFB 是 NMXGPU 的子服务，要等 i915 接管完成才发布（`nmxdiagdelay=60`，约开机 60 秒后），这时 WindowServer 早已打开 IGPU 上的固件帧缓冲 `.Display_boot`（IONDRVFramebuffer）。r29–r31 的注册表里，NMXGPUFB 下面一直没有 `display0`（IODisplayConnect），状态一直是 `awaiting-native-open`，也就是从来没有被打开过。

**上游的做法。** NMIntelFB 开机时直接匹配 IGPU：`IOMatchCategory=IOFramebuffer`，`IOProbeScore=60000`，高于 IONDRVFramebuffer，所以它会顶替 `.Display_boot`，成为 WindowServer 开机就用的帧缓冲。NMXGPU 没有设置 IOMatchCategory，用的是默认类别，所以两者能同时挂在 IGPU 上。
- NMIntelFB 的接管条件，r30 快照全部满足：4680 在它的列表里（显示版本 12），pipe A 点亮，XRGB8888，线性，表面在 BAR2+0 范围内。
- 它不写任何显示寄存器。只要有一项不认识，start() 就失败，IONDRVFramebuffer 照常接手。这是开机时就有的退路。

**E 步方案（建议）。**
1. **NMIntelFB 加进构建和测试包**：在 CI 里编译上游 `kexts/NMIntelFB`（真实硬件版本，不定义 `NMINTELFB_VIRTUAL`），和 NMXGPU 一起装进 `/Library/Extensions`，只在测试会话里加载。许可证已确认可接受。
2. **NMXGPU 不再发布第二个帧缓冲**：IGPU 上已经有 NMIntelFB 时，跳过 NMXGPUFB 的发布，记录 `nmxdiag-display-state = owned-by-NMIntelFB`，不再当成失败处理。否则 WindowServer 可能把 NMXGPUFB 当成第二块屏幕打开，`enableController` 就会触发 i915 模式设置，把屏幕切到一块空白缓冲上。
3. **一次上机**：验证开机由 NMIntelFB 接管并正常显示；60 秒后 i915 接管时画面不中断（r30/r31 已证明 i915 原地保留这块画面）；四个计算/渲染测试照常通过。
   - 失败时的退路：start() 拒绝时，IONDRV 照常接手；万一黑屏，等 6 分钟后重启，测试启动已经把 U 盘配置恢复成安全配置（`-nvoff`），这两个 kext 都不会加载。

**实际实现（2026-10-29，r32）。** 不再单独做第三个 kext：部署流程（安装、日志记录、内核集合、签名和测试）都按 NMXGPU、NMXAccel 两个 kext 写死，加一个要改很多地方。改为把上游源码编进 NMXGPU.kext：
- `xnu/nmx_intelfb.cpp` 是上游 `intelfb.cpp` 的副本。改动只有四处：去掉它自己的 kmod 声明；加上和 NMXGPU 相同的启用条件（`nmxintel=1`，`-nvoff` 时不加载）；记录"屏幕归 NMIntelFB"的标志和接管摘要；日志加 `NullMoth` 前缀，因为会话只采集带这个前缀的内核日志。`-nmintelfboff` 仍然可以单独关掉它。
- `kext/Info.plist` 新增匹配项 `NMXIntelFB`：IOClass 为 NMIntelFB，`IOMatchCategory=IOFramebuffer`，探测优先级 60000。
- NMXGPU 接管完成时，如果屏幕已归 NMIntelFB，就不发布 NMXGPUFB，记录 `nmxdiag-display-state = owned-by-NMIntelFB` 和 `nmxdiag-display-intelfb`（pipe、尺寸、步长、表面地址、刷新率、显存窗口）。
- 会话脚本 `session_registry_ready` 把 `owned-by-NMIntelFB` 也当作就绪，相当于原来的"有 NMXGPUFB"。

**r32 结果（2026-10-29）：开机卡死。** 两次测试启动都停在开机文字界面：屏幕上能看到 NMIntelFB 的探测日志，但它 start() 里的日志一行都没出现；这时 i915 还没开始接管显示。会话的开机任务也没来得及运行，U 盘一直是测试配置，最后在 Windows 上用 `Restore-UHD770.ps1` 才恢复。会话日志里没有这两次启动的任何记录。

**r33 的应对。** 在 NMIntelFB 里加了"步骤记号"：探测和 start() 的每一步，都先打印到屏幕（`NullMoth NMIntelFB: step …`），再写进 NVRAM 变量 `nullmoth-intelfb-step`。start() 放弃接管时清掉这个变量；NMXGPU 接管完成时也清掉它。如果某次开机卡在这些步骤里，下次开机就会读到这个变量还在：NMIntelFB 这次不接管，把停在哪一步记进 `nmxdiag-display-intelfb`（`parked: the previous boot stopped at step …`），并清掉变量，下一轮测试会重新尝试。系统按 r31 的方式启动，会话照常恢复 U 盘配置，不需要再回 Windows。前提是这台机器的 NVRAM 写入能跨重启保留。

**风险。** 中等。这是第一次在开机阶段换掉 WindowServer 的帧缓冲。NMIntelFB 原本只在笔记本内屏上验证过，台式机外接显示器上没试过。合成仍然在 CPU 上，桌面性能和现在相同；这一步的价值是让屏幕归我们的驱动所有，为 F 步（WindowServer 走 GPU）打基础。

## 4. 已确认的决定（2026-10-28）
1. 可以像 Meteor Lake 项目那样降低 SIP 和 AMFI 的安全设置，用于 F 步及之后。具体值到那一步再定，改动只写进测试配置，安全配置保持不变，保证 `-nvoff` 恢复路径始终可用。
2. NMIntelFB 的 PolyForm-Noncommercial 许可证可以接受，可以基于它移植帧缓冲 kext。
