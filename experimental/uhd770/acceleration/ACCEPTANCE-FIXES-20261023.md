# UHD 770 r16 验收整改说明（2026-10-23）

对应验收报告：`UHD770-r16-独立验收报告-20261022.md`。
本文件说明 F1–F4 每一条"改了什么、在哪、怎么验证、还差什么"，供独立复核使用。
**不包含任何硬件成功声明**：目标机上仍然没有执行过任何 GPU 计算。

## 一、总体状态

| 发现 | 验收时的判定 | 现在的状态 |
|---|---|---|
| F1 源码审查缺口 | 不满足（仅条件 1 完成） | 两条追踪均完成；七条隐患逐条有处置；**D2 已修复并验证** |
| F2 分析器选错会话 | 拒绝（可复现假成功） | 已修复；9 个回归测试，含验收者构造的场景 |
| F3 记录器时间预算 | 有保留（代码对、慢路径未验证） | 已改为含全部受限步骤的不变式 + 3 项可执行检查；**仍不声称**跑通 805 秒慢路径 |
| F4 说明两份不一致 | 有保留（"唯一文本"不成立） | 权威文本移出被复制目录，包内只允许一份；r19 起逐字节校验 |

软件门禁（T8）**仍未宣布通过**，记录里明确写着这一点。

## 二、F1

### 条件 1：顶层页目录顺序与回滚 —— 完成

`dma-interface-review.json` 的 `ppgtt_root_and_pde.pin_ordering_trace`：

`gen8_ppgtt_create` → `gen8_init_scratch` → `gen8_alloc_top_pd` →（`__alloc_pd` → `alloc_pt_dma` → `map_pt_dma` 内 `i915_gem_object_pin_map_unlocked` 建立 DMA 地址）→ `fill_page_dma`（此处才读 `px_dma`）→ `ppgtt->pd` 赋值；`init_ppgtt_regs` 在上下文创建时才运行。失败路径 `free_pd` 只 put 一次，`gen8_ppgtt_cleanup` 有 `if (ppgtt->pd)` 守卫。

### 条件 2：销毁链 —— 完成（含 request/回调）

`mainline-audit.json` 的 `cleanup.teardown_trace`：close 路径本身几乎不释放任何东西——句柄把对象 kref 降到 0 后只挂 free_list 并排队；上下文由 ordered wq 上的 work 释放；VM 又一个 work；页表/scratch 在 `gen8_ppgtt_cleanup` 里 put；对象结构永远由 RCU 回调释放。

新增 `request_fence_and_callbacks`：`i915_request_put` = `dma_fence_put` → `i915_fence_release`（capture list、batch_res、sw_fence fini、引擎 request_pool 复用或回 slab），信号回调在端口里运行于 taskqueue 线程，fence 锁是睡眠互斥量。

**结论（明确回答）**：最后一次 close **可以**带着 pending 的 release_work / VM work / BO work / RCU 释放返回。

### 条件 3：缺陷处置 —— D2 已修，其余六条各有理由

- **D2（已修）**：`spin_unlock` 与 `spin_unlock_bh` 现在先释放互斥量再开下半部；`spin_unlock_irq`/`spin_unlock_irqrestore` 经由 `spin_unlock` 继承该修复，四条解锁路径在**打完补丁的头文件**上逐一确认。
  - 修复位置：`patches/freebsd.patch` 新增 `spinlock.h` hunk（5,766 → 6,224 字节）。
  - 验证：`check_patch_inputs.py` 全绿；`test_hazard_dispositions.py` 把**实际交付的补丁**应用到临时副本后断言顺序；CI 内核构建编译该头文件。
- **D1**（irqsave 不屏蔽中断）：FreeBSD LinuxKPI 的既有设计，全体驱动共用；端口自己的 MTX_SPIN 锁才真正屏蔽中断。
- **D3**（drain 期间 `queue_work` 丢工作，`flush_work` 对未入队工作立即返回，`i915_gem_drain_freed_objects` 可能自旋）：机制已证，需竞态；改它等于重定义所有 workqueue 用户的 drain 语义。
- **D4–D7**：潜伏，未被本端口触发（按锁恢复中断状态、`mtx_lock_spin` 与 `mtx_lock` 同义、临界区探测按 CPU 采样、`flush_work` 对非 IDLE 状态解引用队列）。

### 条件 4：状态一致 —— 完成

删除/改写了"not traced"、"F1 items … still open"、`delivery-r17.json` 的"still open"；新增 `t8_status` 明确"未宣布通过"。

## 三、F2（分析器）

**问题**：按目录名排序（boot UUID 无序）；收集所有 probe 目录；缺退出码当正常；有标记就算成功。验收者复现：旧成功盖住新失败。

**修复**（`experimental/uhd770/tools/analyze_session_report.py`）：

1. 会话排序：有 evidence 时间戳用它；**没有**则用 `session.txt` 的 UTC 时间转换成同一格式参与排序（这正是"在命名 probe 之前就失败"的会话）；
2. 只认该会话命名的 evidence 目录，缺失 → `incomplete`；
3. 缺 `coordinator_exit` → `incomplete`；
4. 成功必须同时满足：本次会话 + exit 0 + 该会话 probe 日志**行首**标记；
5. 标记存在但退出码非 0 → 失败，并说明"销毁未正常结束"；
6. 列出携带标记的旧会话，明确"不是本次结果"。

**验证**：`test_analyze_session_report.py` 9 项，含验收者构造的两种形状（无 evidence 的最新失败 / 无退出码）。另用真实临时夹具复现过修复前后的差异。

## 四、F3（记录器预算）

`session.sh`：

```
MANUAL_STARTUP_LIMIT=25          启动确认
MANUAL_COORDINATOR_LIMIT=600     协调器上限
MANUAL_OBSERVE_LIMIT=180         清理后观察
MANUAL_LOADED_AFTER_LIMIT=10     协调器退出后的 loaded-kext 快照
MANUAL_CAPTURE_LIMIT=900         单次记录器会话
MANUAL_REQUIRED_LIMIT=815        上面四项之和
守卫：预算必须 ≥ 要求和，否则启动即失败
```

`collector.sh` 接受范围 120..1800（原来 120..600），位数检查 3 → 4。

**可执行检查**（`test_capture_budget.py`，3 项）：预算覆盖所有受限步骤；每个步骤确实使用这些常量；采集器接受写入值。

**明确不声称**：没有夹具会等 805/900 秒，所以"在可达最慢路径验证"这一条按算术与采集器范围验证，而非端到端计时。

## 五、F4（说明统一）

- 权威文本：`experimental/uhd770/acceleration/NEXT-STEPS-source.txt`（**移出** `deployment/`，因为 `prepare_kit` 整目录复制会把它扫进 `tools/`）；
- 打包脚本读取它生成包内根副本；U 盘副本与根指引用同一份字节；
- r18 起验证：包内 `NEXT-STEPS` **只有一份**、`session.sh`/`collector.sh` 与仓库**逐字节一致**；
- `delivery-r17.json` 已记录"r17 的'唯一文本'说法不成立"。

## 六、包

| 版本 | 说明 |
|---|---|
| r16 | 原始交付（内核无 D2 修复） |
| r17 | 预算与说明修正（内核同 r16） |
| r18 | 修掉包内两份说明（内核同 r16） |
| r19 | 预算不变式含 10 秒快照 + 可执行检查（内核同 r16） |
| **r20** | **内核含 D2 修复**（本轮 CI 产物），其余同 r19 —— 打包待 CI 完成后执行 |

## 七、仍然只能由目标机回答的问题

1. `/dev/dri/renderD128` 能否打开（历史 `stage=open result=-19` 尚无新运行证明消失）；
2. ANV 能否创建设备、VM/上下文/队列，GPU 是否真正消费命令；
3. 结果与 HWSP 是否正确写回、CPU 是否可见、物理中断是否到达；
4. 正常销毁后系统是否稳定继续运行。

## 八、明确不做的事

不创建 PR/issue/评论；不要求用户重启；不把 CI 或模型通过说成硬件成功；不修改验收门槛。
