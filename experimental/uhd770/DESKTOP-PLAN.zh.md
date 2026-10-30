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

**r33 结果（2026-10-29）。** 测试启动又卡住了，屏幕最后一行停在 `step probe`。强制重启后，第二次开机 NMIntelFB 读到 NVRAM 记录 `parked: the previous boot stopped at step published`，自动放弃接管，系统进入桌面，会话也把 U 盘恢复成了安全配置：保护机制生效了。由此可知：
- NMIntelFB 的 start() 其实走完了（停在 published），屏幕在那之前就不再刷新了；
- 卡住那次开机，日志采集器在第 15 秒开始记录、第 16 秒有一次心跳，之后再无任何记录，内核日志也是空的。所以是整个系统在接管后十几秒内卡死，不只是屏幕；
- 那时 i915 还在 60 秒延迟里，没有碰显示。

最可疑的原因：NMIntelFB 是在 IOFramebuffer::start **之后**才设显示组编号（`IOFBDependentID`），设的还是 NVIDIA 显示组（`0x4E56524D00000001`，第 4 号）；它的电源处理也是按"和 NVRMFB 共用控制器"写的。NMXGPUFB 在 r9 之后已经确认：这个编号必须在 start **之前**设好，否则电源回调会访问空的控制器。

另外，第二次开机运行测试时被拒绝了，提示 `Next-boot recovery cannot be verified`。原因是开测前那次全局 `sync` 超过了 30 秒（这块 U 盘写得很慢），而 U 盘配置其实在开机时已经恢复并刷盘过了。

**r34 的改动。**
- NMIntelFB 在 IOFramebuffer::start 之前，把显示组设成 IGPU 自己（`kIOFBDependentIDKey` 设为 provider 的注册表 ID，编号 0），和 NMXGPUFB 一样；不再加入 NVIDIA 显示组，也不再声明自己是笔记本内置屏。
- 步骤记号延伸到发布之后：IOFramebuffer 的每类回调第一次发生时，都在线程里写一次 NVRAM（`cb-vbl`、`cb-enable`、`cb-mode`、`cb-irq`、`cb-power-on/off`、`cb-power-attr`、`cb-conn-set`、`cb-aperture`）。万一还卡，下次开机就能看到最后一次交互是什么。NMXGPU 接管完成后，就不再记录。
- 开测前：如果本次开机的恢复记录已经是 `verified`，而 U 盘上现在就是安全配置，就不再执行全局 `sync`。

**r34 结果（2026-10-29）：E 步完成。** 测试启动正常进入桌面，没有黑屏；四个测试阶段全部通过，没有 panic，和 r31 基线比没有回归（当前基线 r34）。
- `nmxdiag-display-state = owned-by-NMIntelFB`。`nmxdiag-display-intelfb`：pipe A，1920x1080，步长 7680，表面 0x0，刷新率 59.98 Hz，显存窗口 0x4000000000。
- WindowServer 确实在用这块帧缓冲：内核日志里依次出现 `cb-enable`（打开）、`cb-mode`（设置模式）、`cb-irq`（注册帧中断）、`cb-vbl`（帧中断开始触发）、`cb-conn-set`。
- i915 接管前后的快照和 stolen 报告与 r31 相同：固件画面仍在原地，没有被其他分配压到。
- r33 和 r34 的差别只在显示组和内置屏标志，所以 r33 卡死的原因基本可以确定，就是 NVIDIA 显示组在 start 之后才设置。
- 桌面仍由 CPU 合成。下一步是 F 步：插件放行 WindowServer，让它走 GPU。

**风险。** 中等。这是第一次在开机阶段换掉 WindowServer 的帧缓冲。NMIntelFB 原本只在笔记本内屏上验证过，台式机外接显示器上没试过。合成仍然在 CPU 上，桌面性能和现在相同；这一步的价值是让屏幕归我们的驱动所有，为 F 步（WindowServer 走 GPU）打基础。

## 3.5 F 步：调研结论与分步方案（2026-10-29，未实现）
**现在为什么 WindowServer 不走 GPU。** 有三处把 AMD/Intel 写死成"只给应用用的 GPU"：
- 插件 `plugin/NVMTLDevice.m` 的 `nvmtl_process_is_allowed`：只要不是 NVIDIA（厂商 ID 不是 0x10de），就拒绝给 WindowServer 建 Metal 设备（`headless GPU: no device for WindowServer`）。
- 插件 `plugin/nvmtl_vk.c` 的 `nvmtl_gpu_headless`：把 AMD/Intel 一律当作 headless，IOSurface 要拷回系统内存。
- 内核 `kexts/NVRM/accel/nvrm-accel.cpp` 的 NMX 版本（NMXAccel）：不去找任何帧缓冲（`fbm = nullptr`），开机就设 `gNvHeadless = 1` 和 `debug.nmxaccel_headless = 1`。

**现成可用的部分。** 同一份 nvrm-accel.cpp 在 NVIDIA 版本里，已经有把画面送到 NMIntelFB 的完整路径：
- 监听 NMIntelFB 的发布（`fbPublished`，按 `IOFBDependentIndex` 分配 head）。
- 用 `sysctl debug.nvaccelfb=1` 把帧缓冲交给 IOAccelerator 的显示机（`found_framebuffer`），然后"上膛"（恢复 `MetalPluginName`）；`=3` 再打开扫描输出闸门。
- NMIntelFB 通过 `callPlatformFunction(nvScanoutInfo)` 交出扫描缓冲的写合并 CPU 映射（phys 为 0）。显示管线不为它建显存资源，每帧在 `performTransaction` 里拷进这块映射（计数器 `debug.nvaccel_iop_ok_h*`）。
- 这些开关都在运行时用 sysctl 打开，重启后自动回到关闭。上游就是这么设计的，理由是"万一卡住，重启就能撤销，不需要动手恢复"。

**参考项目（VedCloud）怎么放行 WindowServer。**
- 插件不再按厂商判断，改为读内核的 `debug.nmxaccel_headless`（AMD/Intel）或 `debug.nvaccel_headless`（NVIDIA），值为 0 时才放行 WindowServer。值由 NMXAccel 决定：只有显示屏真正挂在它名下时才设成 0。
- `nvmtl_desktop_policy.h` 里只对 WindowServer 生效的几条策略（都按设备 ID 8086:7d45 判断）：提交串行化、独立的读回暂存区、启动前设 `INTEL_DEBUG=noccs` 关掉 CCS 压缩，以及首次提交的等待策略。
- 内核和显示部分改动很多（NullMoth-Xe 有 47 个补丁）。其中不少是虚拟机 virtio-gpu 专用的，真机版 LatitudeMTLFB 用的是"把合成好的画面拷进固件扫描缓冲"（scanout copy，0.3.19）。

**构建方面的前提。** `acceleration/stage.py` 用 `git archive` 从固定的前端版本 fd917ea 取 `kexts/NVRM`、`plugin`、`translator`，中间没有打补丁这一步。F 步要先加一个前端补丁（例如 `acceleration/patches/frontend-nmx.patch`），像 Mesa 的补丁那样在暂存时应用。

**分步方案（每步都可退回）。**
| 步骤 | 内容 | 开机行为 | 风险 | 上机 |
|---|---|---|---|---|
| F1 | 加前端补丁机制。NMXAccel 的 NMX 版本也监听 NMIntelFB，让它成为 head 0（显示组编号 0）；开机仍是 headless。插件改成按 `debug.nmxaccel_headless` 放行 WindowServer，并加上 8086:4680 的 WindowServer 策略（串行提交、关 CCS 等）。 | 与 r34 相同，WindowServer 仍走 CPU | 低 | 1 次：确认 NMXAccel 看到了 head 0，四个测试照常通过 |
| F2 | 新增一个手动脚本：登录后依次写 `debug.nvaccelfb=1`（登记显示管线、上膛）和 `=3`（开扫描闸门），记录日志后重启 WindowServer（会注销一次），看桌面是否由 GPU 合成、帧是否被拷进 NMIntelFB。 | 只在运行时打开，重启即恢复 | 高，但重启可退回 | 1–多次 |
| F3 | 如果 WindowServer 因为签名不肯加载插件，就在**测试配置**里放宽 AMFI/SIP（之前已同意，参考值 `csr-active-config=0x0A43`、`amfi_get_out_of_my_way=0x1`）。安全配置保持不变。 | 测试配置 | 中 | 1 次 |
| F4 | F2 稳定后，改成开机自动上膛；之后进入 G 步（流畅度、长时间运行、睡眠唤醒）。 | 测试配置 | 中 | 多次 |

**实现（r35，2026-10-29）：F1–F3 合并成一轮测试。** 用户希望少重启几次，所以 F1、F2、F3 放进同一轮：一次 Start、一次重启，进桌面后先跑 Run-UHD770-Test，再跑新的 Run-UHD770-Desktop。
- 前端补丁 `acceleration/patches/frontend-nmx.patch`，由 `stage.py` 在 Metal 组件暂存时应用：
  - NMXAccel 监听 NMIntelFB，让它成为 head 0；新增自己的开关 `debug.nmxaccelfb` 和 `debug.nmxaccel_iop`，以及拷帧计数器 `debug.nmxaccel_iop_ok*` 等。上膛后 `debug.nmxaccel_headless` 变为 0。开机时仍是 headless，应用照常有 Metal 设备。
  - 插件：Intel/AMD 上只有 `debug.nmxaccel_headless` 读到 0 时才给 WindowServer 设备，不用放行名单；headless 判断也改读这个 sysctl；Intel 上的 WindowServer 在加载 ANV 前设 `INTEL_DEBUG=noccs`，因为 CPU 拷贝读不了压缩表面。
- 测试配置的启动参数加上 `amfi_get_out_of_my_way=0x1`（F3），只在测试配置里，安全配置不变。SIP 的值这次没动。
- `Run-UHD770-Desktop.command`（F2）：要求本次开机已经跑完 Run-UHD770-Test。它通过 launchd 以 root 身份在后台依次写 `debug.nmxaccel_iop=1` 和 `debug.nmxaccelfb=3`，然后重启 WindowServer，在 20 秒和 60 秒时各记录一次开关、计数器和注册表，再记录内核、插件和 WindowServer 的日志，最后拷到 U 盘的 `UHD770-desktop-reports/`。重启即撤销所有改动。
- 参考项目的串行提交、独立读回暂存区等 WindowServer 策略，这一轮还没有移植；先看基本路径能不能通。

**r35–r37 结果（2026-10-30）。**
- r35：上膛成功（NMIntelFB 成为 head 0，CPU 拷贝显示管线，`nmxaccel_headless=0`），但普通 `killall` 发的 SIGTERM 没能让 WindowServer 退出。r36：Start 的采集器自检因为一次启动初期的日志刷新超时而被拒（已修正）。
- r37：四个测试阶段照常通过；Desktop 脚本用 SIGHUP 让 WindowServer 重启（pid 159 → 7497），新的 WindowServer 一直在运行，但屏幕停在内核文字界面，显示管线一帧也没收到（`nmxaccel_iop_ok/fail/empty` 全为 0）。报告 `UHD770-desktop-reports/UHD770MVP-desktop.Yw77NR` 显示三个障碍：
  1. WindowServer 里 ANV 找不到 GPU：插件报 `vk: zero physical devices ... in WindowServer (uid 0 euid 88)`，WindowServer 因此报 `Failed to create MetalDevice for accelerator`。设备节点是 0666，怀疑是 WindowServer 的沙盒不让它访问 `/dev/dri`。参考项目为此在 NMXGPU 加了 IOKit DRM 客户端，并改了 libdrm（补丁 0045、libdrm 0002/0004）。我们这边还没有这套东西。
  2. CoreDisplay 找不到这块帧缓冲的显示管线：`Unable to find display pipe for IOFB service ... 0x10000052c`（即 NMIntelFB）。参考项目补丁 0003 说明：扫描缓冲物理地址报 0（只用 CPU 拷贝）时，CoreDisplay 的 `MPAccessSurfaceForDisplayDevice` 会失败；需要报告真实的物理地址，并设置 `IOFBMemorySize`。
  3. IOAccelerator 要求的每任务 GPU 地址分配失败（`NVTask::allocate: RM refused 8294400 bytes`，1474 次），这是 NVIDIA RM 专用的路径。参考项目补丁 0004 在 AMD/Intel 上改用一个简单的递增编号分配器。

**r38 的改动（2026-10-30）：修第 2、3 个障碍，查清第 1 个。**
- NMIntelFB 回答 `nvScanoutInfo` 时报告真实的扫描缓冲物理地址（BAR2 + SURF，页对齐大小），并设置 `IOFBMemorySize = 1 GiB`（参考补丁 0003）。显示管线因此走"live scanout"路径，为这块缓冲建立 framebuffer resource。
- NMXAccel：Intel/AMD 上的每任务 GPU 地址改用递增分配器；上膛时为每个已登记的 head 补发 `framebuffer_did_power_on`（参考补丁 0004）。
- 诊断：插件在找不到 GPU 时，记录打开 `/dev/dri`、`renderD128`、`card0` 的读写和只读结果（errno）；Desktop 脚本另外采集沙盒拦截记录（`sandbox.txt`），以及 WindowServer 的 display pipe 和 IOPresentment 日志。
- 参考项目其余补丁的取舍：沙盒访问（0045、libdrm 0002/0004）、IOSurface（0025）、commitAndWaitUntilSubmitted（0016）、To_Accelerated（0042）、帧提交顺序（0019–0021）可能很快需要；0024/0026/0027/0043/0046 留到性能阶段；virtio-gpu、NMXVGAFB、NMXAGDC、QEMU、xe/SR-IOV 相关的用不上。每轮只移植当下卡住的那一块。

**r38 结果（2026-10-30）。** 四个测试阶段照常通过。Desktop 脚本重启 WindowServer 后，新的 WindowServer（pid 8918）2 秒后崩溃（SIGSEGV），再次启动的又卡住，约 5 分钟后看门狗报 `no successful checkins from WindowServer ... in 120 seconds` 并 panic（`panic-2026-10-30-055119.txt`）。崩溃报告（用户从 Mac 拷出的 `windowservererror.rtf`）：
- 崩溃线程和主线程都在 QuartzCore 的 CPU 软件渲染器里（`CA::OGL::SW::image_sampler` 等），访问地址 `0x1010`，即读一个像素指针为空的图像。
- WindowServer 已经加载了 NVMTLDriver 和 libvulkan_intel。但插件在它里面找不到 GPU（第 1 个障碍），没有 Metal 设备，于是退回软件渲染。
- 软件渲染去合成挂在 NMXAccel 上的表面，这些表面没有 CPU 映射，就崩溃了。

结论：第 2、3 个障碍修好后，WindowServer 走得更远，但只要第 1 个障碍还在，它就只能用软件渲染，而软件渲染碰不了加速器的表面。所以 F 步接下来的重点就是第 1 个障碍：让 WindowServer 里的 ANV 能打开 GPU。r38 Desktop 记录里的插件诊断（打开 `/dev/dri` 的 errno）和 `sandbox.txt` 这次没有拷进 U 盘，要从 Mac 的 `/Users/Shared/UHD770MVP-desktop.*` 或系统日志里取。

**第 1 个障碍查清了（r38 诊断，用户从 Mac 系统日志取出 `r38.txt`）。** WindowServer 每次启动时：
- 沙盒拒绝它以读写方式打开 `/dev/dri/renderD128` 和 `card0`（`Sandbox: WindowServer deny(1) file-write-data /dev/dri/renderD128`，open 返回 errno 1）；
- 以只读方式打开 `/dev/dri` 目录和 `renderD128` 都成功（errno 0）；`card0` 只读也失败（errno 13，节点权限 0600）。

我们的 libdrm 在枚举设备时（`drm_darwin_query_node`）用 `O_RDWR` 打开节点，失败后就当作没有这个设备，于是 ANV 报"枚举成功但没有设备"。Mesa 的 ANV 打开渲染节点时也用 `O_RDWR`。内核这边不需要改：`nmx_mmap` 和 DRM ioctl 都不检查 fd 的写权限，只读 fd 一样能提交命令、映射显存。参考项目 libdrm 补丁 0004 的说明也是"失败时退回只读（WindowServer）"。

所以第 1 个障碍只需要 userland 两处改动，不需要 IOKit DRM 客户端（那是给 App Sandbox 里的应用用的，比如 Safari；它们连只读都打不开）：libdrm 的枚举和 ANV 的打开在读写被拒（EPERM/EACCES）时都退回只读。

**参考项目补丁评审（2026-10-30，为 r39 一次性筛选）。** 用户希望少重启几次，所以在动手前把 NullMoth-Xe 的 60 个补丁（驱动 47、libdrm 5、Mesa 8）逐个对照我们的代码，判断"WindowServer 第一次用 GPU 合成并显示出来"需要哪些：

| 补丁 | 作用 | 结论 |
|---|---|---|
| libdrm 0004、Mesa 0002/0008 | 沙盒下以只读方式打开节点 | 需要；自己写精简版：`libdrm-nmx-readonly.patch`、`mesa-anv-readonly.patch` |
| 0005 前半 | 帧缓冲用物理连续系统内存响应 `nvAllocVram`/`nvFreeVram` | 需要；没有它，显示表面没有内存，这正是 r38 崩溃的原因 |
| 0005 后半 | 以 60 Hz 重复拷贝最后呈现的一帧 | 需要；我们也走 CPU 拷贝，同样会遇到"呈现早于画面写回"的竞争 |
| 0024 | 缓冲纹理按缓冲自身的内存类型判断 | 需要；ANV 的线性图像只接受部分内存类型，CoreAnimation 的缓冲纹理会得到 nil |
| 0021 | 用 CAS 创建 `gNVSVPendLock` | 顺手修，一行 |
| 0003、0004 | 真实扫描地址、假 GPU 地址、补发上电 | r38 已移植 |
| 0011、0015、0016、0019、0020、0025、0026、0043、0042、0046 | 零拷贝、帧提交排序、IOSurface 直接映射、描述符复用、To_Accelerated、预留显存 | 都是性能或长时间运行用的，留到 G 步 |
| 0007 | 开机自动上膛 | 留到 F4 |
| 0027、0031、0032 | OpenGL 应用和着色器翻译 | 与 WindowServer 无关 |
| 0045、libdrm 0002/0005 | App Sandbox 进程走 IOKit 的 DRM 通道 | 暂不需要：WindowServer 只读打开节点是允许的。但如果它的沙盒还拦截只读 fd 上的 ioctl，就需要了；r39 的沙盒日志会给出答案 |
| 其余 NMXVGAFB、NMXAGDC、virtio、QEMU、xe/SR-IOV | 虚拟机专用 | 不需要 |

**r39 的改动。**
- userland：libdrm 枚举和 ANV 打开渲染节点时，读写被拒（EPERM/EACCES）就退回只读。userland 组件从 r16 起第一次重新编译。
- 内核（NMIntelFB）：`nvAllocVram`/`nvFreeVram` 用物理连续的系统内存，预算 512 MiB。
- 前端（NMXAccel）：显示管线以 `debug.nmxaccel_front_hz`（默认 60）重复拷贝最后一帧，计数 `debug.nmxaccel_front_copies`；`gNVSVPendLock` 改用 CAS 创建。
- 前端（插件）：缓冲纹理按缓冲自身的内存类型判断（`nvk_buffer.memtype1`）。

**r39 结果（2026-10-30）。** 四个测试阶段通过；Desktop 后没有回到登录界面，约 5 分钟后看门狗 panic。日志（报告 `UHD770MVP-desktop.p8uIfe`，从 Mac 取回）：
- WindowServer 加载了 r39 的插件、libvulkan_intel 和 libdrm（UUID 与 r39 编译产物一致）。只读打开 `/dev/dri/renderD128` 成功（errno 0），但沙盒随即拦下这个 fd 上的 ioctl：`deny file-ioctl path:/dev/dri/renderD128 ioctl-command:(_IO "N" 68)`（`NMX_DRM_IOCTL_NODE_INFO`）。ANV 因此枚举到 0 个设备。
- 没有 GPU，WindowServer 退回 CPU 软件渲染，在 SkyLight 的 `layer_blit_byte_ANY` 里写一个基址为空的显示表面（地址 0xdf0）崩溃；它被反复重启、反复崩溃，最终看门狗 panic。r38 是读空纹理（0x1010），r39 变成写，说明 `nvAllocVram` 的系统内存显存起了作用（日志里有多次 8294400 字节的分配）。
- `debug.nmxaccel_iop_empty` 涨到 30，`front_copies` 为 0：IOPresent 来了，但没有可拷贝的帧。
- Desktop 报告没有写进 U 盘：同名卷被 macOS 挂成了 `/Volumes/1401 2`，脚本只认 `1401`。

**r40 的改动（DRM over IOKit，参考 xkpi 0032/0036/0037、libdrm 0002/0003、Mesa 0002）。**
- 内核：新增 `IOAccelNMXDRMClient`（`xnu/nmx_drmuc.cpp`）。NMXGPU 的 `newUserClient` 类型 `'NMXD'` 在内核里打开一次渲染节点，唯一的外部方法在调用者线程上执行一个 ioctl，所以参数里的用户指针和 `NMX_DRM_IOCTL_MMAP` 的映射都属于调用者。WindowServer 的沙盒允许名字以 `IOAccel` 开头的用户客户端。
- 内核：`nmx_xnu_user_wire` 在区间不能为写入锁定时退回只读锁定（WindowServer 只能读别的进程画的 IOSurface）。
- libdrm：`drmIoctl` 改走 `drmNmxIoctl`，ioctl 得到 EPERM 时把这个 fd 切换到 IOKit 客户端，此后它的所有 ioctl 都走那边；客户端按 fd 的 clone minor 配对。
- Mesa：`intel_ioctl` 和 `drm_ioctl` 经运行时查到的 `drmNmxIoctl` 发出；`anv_CreateDevice` 打开设备时也退回只读（r39 只改了物理设备枚举那一处）。
- 部署：Desktop 脚本也认 `1401 N` 卷；快照多记录 `IOAccelNMXDRMClient`。
- 不做：普通沙盒应用需要的 libdrm 0004/0005、NMXAccel 0045（WindowServer 用不到），留到桌面跑通以后。

**r40 结果（2026-10-30）。** 仍未回到登录界面，约 15 分钟后看门狗 panic（报告 `UHD770MVP-desktop.JEkSsB`）：
- IOKit 通道通了：WindowServer 打开了多个 `IOAccelNMXDRMClient`（`IOUserClientCreator = pid …, WindowServer`），沙盒没有拦截它们。沙盒日志里剩下的 `deny file-ioctl` 是每个 fd 的第一次尝试，之后 libdrm 就切换到客户端。
- 插件第一次在 WindowServer 里找到了 GPU，走到了 `vkCreateDevice`，但每次都返回 -3（`VK_ERROR_INITIALIZATION_FAILED`），WindowServer 仍然退回 CPU 渲染并反复崩溃。
- 失败发生在设备 fd 切换到客户端后约 27 ms。在 i915 路径上返回 -3 的只有内核上下文或 VM 的创建（`kernel context creation failed`）和打开设备本身。具体原因 Mesa 只交给 Vulkan 调试回调；插件的回调只写文件，而 WindowServer 的沙盒不让写，所以这次没有留下原因。

**r41 的改动（只加诊断，不改驱动行为）。**
- 插件：调试回调收到的 Mesa 原因同时写进系统日志（`NullMoth: nvk-reason: …`），WindowServer 里也看得到。
- libdrm：`NMX_DRM_IOKIT=1` 时每个 ioctl 从第一次起就走 IOKit 客户端。
- Desktop 脚本：重启 WindowServer 之前，先用 `NMX_DRM_IOKIT=1` 跑一次计算探针（`iokit-probe.txt`）。它不在沙盒里，所以能判断问题出在 IOKit 通道本身，还是 WindowServer 特有的条件（只读 fd、沙盒），并带出 Mesa 的原因。

**r41 同时缩短测试循环（用户计时：拿到新包到测完要 30 分钟以上）。**
- Start：不再等 120 秒的正常桌面录制验证（录制器照样安装，Run-Test 仍会等新的录制）；AuxKC 按输入（内核、系统 KC、扩展目录里每个文件和链接）缓存，输入相同就复用上次装过的 KC，只改用户态的轮次三次 `kmutil create` 一次都不跑。
- Desktop：不再要求先跑 Run-Test，只要求开机任务已确认下一次是恢复启动；按 Start 记下的卷 UUID 找 U 盘（没挂就挂上），每一步都把报告拷进 U 盘，panic 后直接回 Windows 读，不再需要多进一次 macOS 抓日志。
- OpenCore（用户 2026-10-30 同意）：安全配置关掉 `AppleDebug`，`Target` 由 3 改为 1，去掉 `-v`；测试配置仍带 `-v`（`prepare_kit` 自动加）。原配置备份为 U 盘上的 `config.plist.uhd770-before-speedup-20261030`。

**主要未知数。**
- 拷贝路径原本是"NVIDIA 显存 → Intel 内屏"。现在源和目的都在 Intel 这边（ANV 的系统内存表面 → BAR2 扫描缓冲），`performTransaction` 怎么读取源表面，要在 F1 里读代码确认，可能还要改。
- IOAccelerator 显示机对帧缓冲和加速器的配对规则（显示组编号、`IOAccelIndex` 等）还没有逐行确认。
- WindowServer 的沙盒和签名限制（参考项目的补丁 0045 处理了沙盒进程打开 GPU 设备）。

## 4. 已确认的决定（2026-10-28）
1. 可以像 Meteor Lake 项目那样降低 SIP 和 AMFI 的安全设置，用于 F 步及之后。具体值到那一步再定，改动只写进测试配置，安全配置保持不变，保证 `-nvoff` 恢复路径始终可用。
2. NMIntelFB 的 PolyForm-Noncommercial 许可证可以接受，可以基于它移植帧缓冲 kext。
