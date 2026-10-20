UHD 770 单轮应用计算测试候选包
==============================

适用本机：i7-12700 / UHD 770 8086:4680 / x86_64 macOS 15。
这是实验候选包，没有本机运行成功证据。不是 UHD 770 桌面加速正式驱动。
本轮验证显示接管、真实 Vulkan 计算读回，以及前者通过后的 Metal 计算读回。
WindowServer、HiDPI 60 Hz、视频编解码、睡眠唤醒不属于本轮成功判据。

你只需要这样操作
----------------
1. 将整个 ZIP 带进 macOS 并解压。测试使用原来的 1401 U 盘，保持插着。
   先以原有 -nvoff 配置进入正常桌面；不要运行旧版 enable 或清空 NVRAM。
2. 打开终端，输入 sudo /bin/bash -p 后留一个空格，拖入本包根目录的
   Start-UHD770.command，再回车。按提示输入密码。
3. 程序在一次调用中验证包、私有 KC、USB 恢复目标、正常桌面日志（约 5 分钟），
   构建保留其他 /Library/Extensions 驱动的 KC、备份并安装本候选，最后才写入测试开关。
   准备可能需要十几分钟。没有 PREPARED 字样就不要重启测试。
   任一步失败会停止，尽力恢复改动并自动导出报告；不要自行删除 stage 或反复重跑。
4. 看到 PREPARED 后，重启一次，通过同一个 1401 U 盘选择正常 macOS 15，照常登录。
   此前不需要另执行 enable。接管在固件可读后延迟 180 秒。
   启动任务先把 U 盘配置恢复为 -nvoff，供下次恢复启动；不会关闭当前这次测试。
   初始化和恢复检查通过后，普通用户任务自动执行 Vulkan，成功才执行 Metal。
5. 进入系统后给它最多 10 分钟。系统任务会导出
   /Users/Shared/UHD770MVP-session-reports.XXXXXX。
   如果黑屏/无信号，等信号消失后 6 分钟；仍无画面再手动重启。
   同一个 U 盘的下一次正常 macOS 启动应已使用 -nvoff，自动导出留下的日志。
   黑屏不证明主机仍能工作；内核卡死/断电时日志可能不完整。

取回报告与恢复
--------------
把最新的 /Users/Shared/UHD770MVP-session-reports.* 整个文件夹带回 Windows。
如果没有自动导出的文件夹，在正常桌面执行本包 tools/session.sh export：

  sudo /bin/bash -p "/实际包路径/tools/session.sh" export

如果恢复启动仍有问题，回 Windows 执行包内 Restore-UHD770.ps1：

  powershell -NoProfile -ExecutionPolicy Bypass -File ".\Restore-UHD770.ps1"

它只在 FAT32/1401 卷及 config 哈希都匹配时恢复 -nvoff，不改分区或 macOS 文件。
文件被独立修改或有多个匹配 U 盘时会拒绝覆盖。请保留包内 session-target 目录。

需要把 macOS 驱动、固件、用户库和 AuxKC 恢复成安装前版本时，在正常 macOS 桌面：

  sudo /bin/bash -p "/实际包路径/tools/session.sh" restore

按白名单回放原始文件备份；不会在当前系统卸载正在运行的 GPU 驱动，下一次启动生效。
恢复中断后保留 journal，重复 restore 会跳过已完成条目。

具体边界
--------
- 不改 SIP/AMFI，不重置 NVRAM，不自动重启，不开启网络或全局 Metal 注入。
- 不依赖 1401 的临时跳过选项；U 盘原始 -nvoff 配置字节另存并核对哈希。
- 不声称现在正在使用哪个 EFI；明确要求下一次从已核对的同一个 1401 USB 启动。
- 私有 stage/KC 仍是先决检查，但正常成功路径不再每个阶段要求人工返回交日志。
- NMXGPU 使用本机派生 ad-hoc 签名副本；原件保留。CLI 也只签派生副本并记录哈希。
  KC 链接和签名验证不能保证这台黑苹果的信任/加载策略允许实际加载。
- 普通用户任务不能修改 EFI；根启动任务先验证恢复，用户任务才允许运行 probe。
- GPU 初始化失败时后续计算无法运行；超时会停止，不把未运行的测试记为通过。
- 用户态超时不能恢复内核死锁。自动日志与 USB 恢复仍需这次实机验证。
- session-target 包含机器配置，仅供本机使用；不要提交或公开上传整个包。
