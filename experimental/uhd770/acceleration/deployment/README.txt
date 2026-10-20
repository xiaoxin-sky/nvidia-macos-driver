UHD 770：目标机预检与自动日志准备包
================================

本轮目标
--------
先把 macOS 15 上的安装条件、真实内核依赖和日志路径核实完整，再开启 GPU。
本工具不包含驱动安装/启用命令；不会修改 EFI、NVRAM、安全设置或当前内核集合，
也不会运行 Vulkan/Metal。无需 Python、Xcode、Homebrew 或网络。
原始三份候选 tar 完整保留。固件来自固定 linux-firmware 提交，含许可及逐文件校验。

你现在只需要做的事（不重启、不测试 GPU）
--------------------------------------
1. 在 Windows 中将本准备包 ZIP 作为文件拷到能带入 macOS 的位置；不要先在
   Windows 解开候选 tar。此前的 UHD770-MVP-candidate ZIP 不是本准备包。
2. 在 macOS 中解开本准备包 ZIP，打开终端。先输入下面的前半段并保留一个空格：

     sudo /bin/bash -p

   把本准备包 tools/preflight.sh 拖到终端，回车并输入 macOS 密码。
   完整形式示例（路径请以实际解压位置为准）：

     sudo /bin/bash -p "/你的实际路径/tools/preflight.sh"

3. 程序会先打印 Report: /Users/Shared/UHD770MVP-preflight.XXXXXX。
   通常数十秒；各命令有超时，整体预算 150 秒。保留整个报告文件夹，带回 Windows。
   遇到 missing/timeout 也保留原文件；它代表未知，不代表核验通过。
   此步骤只在原有系统读取状态；没有加载新驱动。如果旧驱动本来就启用，它仍可能
   自行接管显示；脚本没有把它关闭或重新启用。

先做上述预检即可。下面是工具的后续执行顺序，不要求现在照着全部运行。

后续阶段 A：私有暂存与目标机链接预检（收到报告后再安排）
------------------------------------------------------
只在实际启动参数包含 -nvoff 的桌面上执行：

  sudo /bin/bash -p "/实际包路径/tools/manage.sh" stage

输出固定在 /Library/Application Support/UHD770MVP，已存在则拒绝覆盖。
只复制清单列出的文件，重新校验归档与解压后内容，保留原始证据。
固件暂存在 components/firmware，尚未放入内核读取的 /Library/NullMoth/firmware。
NMXGPU/NMXAccel 暂存在 components/Library/Extensions，尚未放入 /Library/Extensions。
Metal 运行库尚未放入 /Library/GPUBundles，因此 runner 此时不能完成实机测试。

NMXGPU 原包未签名。工具只给 kc-preflight/repository 内的派生副本进行 ad-hoc
签名，记录原件和派生哈希。components 与原始 tar 不改变。
它用本机实际 Boot/System KC 在自己的 kc-preflight 目录建立临时 AuxKC，核实
两个 bundle ID 和符号依赖。该 KC 永远不复制到 /Library/KernelCollections。
链接成功不代表系统信任策略允许加载，更不代表 GPU 工作。
失败时保留现场，不要自行删除/retry，也不要开启驱动；导出结果用于统一分析。

后续阶段 B：先验证自动日志（不必重启）
-----------------------------------
  sudo /bin/bash -p "/实际包路径/tools/manage.sh" install-recorder
  sudo /bin/bash -p "/实际包路径/tools/manage.sh" recorder-status

注册 com.uhd770.mvp.capture 后立即采集一次；以后启动时也采集。
每次独立会话默认 300 秒，日志在系统盘 /private/var/log/UHD770MVP。
有阶段标记、boot UUID、有限日志流、dmesg/NMXGPU/NMXAccel 快照及超时标记。
脚本不调用 GPU 用户接口，也不安装/加载驱动。先用正常桌面核实日志链是否可靠。
collector 的 OS 调度、launchd 启动及断电/重启持久性仍需目标机验证。
文件同步是尽力而为；硬件级内核死锁仍可能只留下最后一次写入的阶段。
风扇在转、没有信号、采集器没有写完都不能单独证明 panic 或系统仍能响应。

取回日志或停止采集器
--------------------
  sudo /bin/bash -p "/实际包路径/tools/manage.sh" export
  sudo /bin/bash -p "/实际包路径/tools/manage.sh" remove-recorder

export 生成新的 /Users/Shared/UHD770MVP-reports.XXXXXX，包含启动采集、stage/KC
文本证据，不含大型 KC 二进制。复制这个文件夹即可。remove 不删除已有日志。
未来普通用户 GPU 测试结果另在 ~/Library/Logs/UHD770MVP；它不属于 root export。
届时应同时复制该用户目录的完整会话。当前阶段不运行这些测试。

真正启用前还缺的门槛
--------------------
- 针对实际启动 EFI 验收独立 opt-out：-nvoff 优先、移除 nmxintel/nmxdiagdelay，
  并确保 NVRAM.Delete 刷新 boot-args。不依赖 1401 临时 NVRAM，不清空全部 NVRAM。
- 为 /Library/Extensions、固件、/Library/GPUBundles 和活系统 AuxKC 建立匹配的
  事务安装/备份/恢复操作；本包尚未实现，也没有以私有 stage 冒充完成安装。
- 把本机签名/安全策略与当前预检结果关联。工具不会替你关闭 SIP/AMFI。
- 核实自动日志至少完成一轮，再安排单次、有界、只验证一个阶段的硬件测试。

内核原有 attach guard 在 framebuffer 成功发布后清除，不能防之后的 GPU 卡死。
参考 EFI（若包内存在 reference-efi）来自保存的备份，仅为离线 opt-out 副本。
PLAN.json 记录其来源 SHA256；它未核实为当前实际启动 EFI，不能直接覆盖使用。
其中可能含机器标识，不要将该目录上传到公开仓库。

开发与构建边界
--------------
Windows 组包：
  python experimental/uhd770/acceleration/deployment/prepare_kit.py \
    --candidate /path/to/verified-candidate --firmware /path/to/firmware \
    --output /path/to/NEW-preflight-kit [--config-backup /path/to/SAVED-config.plist]

固件清单 firmware.json 与固定 drm-kmod 的 DMC/GuC/HuC 名称表同步维护。
准备工具复用 kit/assemble.py 的归档验证；改归档策略要同步其 fixture。
日志/probe 的独立 fixture 不运行真实 GPU；CI 只允许定向 shell/Python 检查。
准备包有 hardware_ready=false、gpu_executed=false，不能作为硬件加速成功证据。
