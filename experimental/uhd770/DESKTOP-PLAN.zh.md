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

## 4. 已确认的决定（2026-10-28）
1. 可以像 Meteor Lake 项目那样降低 SIP 和 AMFI 的安全设置，用于 F 步及之后。具体值到那一步再定，改动只写进测试配置，安全配置保持不变，保证 `-nvoff` 恢复路径始终可用。
2. NMIntelFB 的 PolyForm-Noncommercial 许可证可以接受，可以基于它移植帧缓冲 kext。
