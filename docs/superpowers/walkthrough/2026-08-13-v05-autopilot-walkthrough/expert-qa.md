# Agent Arena v0.5 autopilot 设计走查 — QA 专家评审（qa）

> 角色：测试与质量专家（hermetic 测试矩阵、AC 可测性、边界与回归、fixture 设计）
> 评审对象：`input-design.md`（v0.4 现状事实 + v0.5 设计草案 + 决策点 A/B）
> 基线事实核对：`lib/state.sh`（actor/action 枚举 fail-closed）、`lib/config.sh`（严格解析未知行 die）、`lib/resolve.sh`（Human disposition 契约）、`tests/run.sh`（§0–§49 共 50 节；§29/§47 对 list 列按位置断言；§38 对 state 16-key 计数断言；status 断言均为 grep 型）、`VERSION`=0.4.0、v0.4 spec wire contract。

## R1 — 用户故事与验收标准

| # | 级别 | 发现 | 证据/推理 | 建议 |
|---|------|------|-----------|------|
| QA-01 | **严重** | 草案 §2 声称自动审批审计链 `actor=autopilot`，但 v0.4 wire contract 把 `last_transition_actor` 枚举钉死为 `writer\|reviewer\|human\|system`，且读取端对枚举外值 **fail-closed 判损坏**（exit 2）。v0.5 写出的 actor=autopilot 状态文件会被已发布的 0.4.0 二进制判为 corrupted；同时 §2 又声称"不修改 v0.4 T 矩阵/命令语义、审计链不变"——**枚举扩展本身就是 wire contract 变更**，两个声明自相矛盾。`resolve.sh` 自述 "Human disposition"，autopilot 代办后该自述也不准确 | `lib/state.sh`：`case "$ARENA_STATE_LAST_TRANSITION_ACTOR" in writer\|reviewer\|human\|system) ;; *) arena_state_die 'corrupted state file: invalid last_transition_actor'`；v0.4 spec wire contract 表；input §2"actor=autopilot，SHA 决策记录不变" | 二选一并写进 spec 的 Drift/rollback 段：(a) **扩展枚举加 `autopilot`**（推荐——状态文件是 v0.4 的卖点"最后一次转移执行者"的单一事实源，autopilot 正是该字段该记录的执行者；配套测试：读取端接受 `autopilot`、仍拒绝任意未知值），并显式声明"v0.4.0 无法读取 v0.5 写出的状态，fail-closed，禁止降级回读"；(b) 不改枚举，用 `actor=system` + `reason_detail="autopilot ..."`，代价是状态文件失去执行者粒度，需靠 autopilot.log 补审计——与 v0.4"状态文件为权威"的定位冲突。**不要两头都占** |
| QA-02 | **主要** | AC 覆盖不完备：动作矩阵只覆盖 approval_pending / changes_requested / reviewer_unreachable / block_resolution_required / completed / corrupt，漏掉 (a) **reviewer 侧停滞**（review_pending/decision_pending 长时间无动作时无人报警——v0.4 submit 的 reviewer respawn 是 best-effort，reviewer 死掉却不 escalate 时 run 会静默停摆）；(b) **human 模式下 approval_pending 的报警语义**——v0.5 的原始动机就是"APPROVE 后卡在 approval_pending 等 human"，human 模式下 `--once` 该不该 exit 2？草案矩阵 human 模式全是"只观测"，等于把最需要报警的状态排除在退出码外；(c) intake / human_changes_requested 的 writer 停滞 | input §2.2 矩阵逐行核对；§1 背景"两个设计断点"；v0.4 AC11（submit respawn best-effort） | 补一张 **状态 × 模式 × 动作（observe/alert/relay/act）× 退出码** 的全量真值表（对齐 v0.4 T 矩阵的穷举风格），并为每个"停滞类"状态定义超时默认值与报警语义；human 模式下 approval_pending 建议归入"需人工介入"（exit 2） |
| QA-03 | **主要** | AC7 "v0.4 50 节零改动"断言过强：status 加 `Mode:` 行、config 加 `approval_mode` 键、manifest 加 `mode` 字段、start 写 manifest——全部落在 v0.4 已测代码路径上。现有断言多数是 grep 型或按 key 解析（status 断言全为 `require_match`，加一行安全；§38 的 16-key 计数不受影响，因为 mode 不进 state 文件——这点设计是对的），但"零改动"应改为可核验的**受影响断言清单**，并补新回归：v0.5 解析器对含 `approval_mode` 的 config 正常、对未知行仍 die（严格解析是 v0.4 特性，不能丢） | `tests/run.sh` §29/§38/§47 断言形态；`lib/config.sh` 未知行 `arena_die` | 在 spec 里列出"50 节逐节核对结论表"（每节：语义不变 / 断言随输出扩展更新），把"零改动"改成"零语义漂移 + N 处显式断言更新"，并新增 config/mode 两个兼容性测试 |
| QA-04 | 次要 | AC 编号与 v0.4 AC1–13 撞号，AC→测试映射会混淆（v0.4 spec 用 AC1–AC13 且测试按 section 引用） | v0.4 spec AC 编号；input §2.5 AC1–AC7 | v0.5 AC 用 `v05-ACn` 命名空间，spec 内建 AC→§50–53 映射表 |
| QA-05 | 信息 | "无人值守推进到完成"的承诺范围：auto 模式只移除了 human-approval 环节；writer 调度仍靠 best-effort relay，reviewer 动作仍需模型值守，trust prompt 仍需人工。AC 措辞若按字面验收（任务自动推进到完成）会测不过 | input §0 自陈两个断点只解决一个半；§3 风险第 3 条 | 把 AC 措辞收窄为"自动完成 approval 环节 + 全停滞状态报警"，并在 README 非承诺表加一行（对齐 v0.2 的 AC10 先例） |

## R2 — 技术追踪与契约状态

| # | 级别 | 发现 | 证据/推理 | 建议 |
|---|------|------|-----------|------|
| QA-06 | **严重** | `--once` 退出码协议与 v0.4 协议**语义碰撞且无聚合优先级**：v0.4 全协议 2=非法转移/损坏/冲突（错误语义），草案 §2.3 定义 autopilot 2="发现需人工介入（blocked 等）"（正常但有活要干）。同一码值两条命令语义相反；且"corrupt/conflict 聚合退出码"与"blocked 需人工"都压到 2 时，优先级未定义。此外 autopilot 动作期间 resolve 返回 2（状态已变）/4（锁）/5（residue）是**预期竞态**，草案未定义"哪些 per-run 结果进退出码、哪些只记日志" | v0.4 spec 退出码协议表；input §2.3 | 写一张 autopilot 专属退出码表（与 v0.4 表并列，明确 command-level 而非 run-level）：建议 0=无动作/全部完成；2=至少一个 run 需人工介入或存在 per-run 异常；4=锁竞争；5=incomplete/residue；优先级 5>4>2>0（镜像 list 的聚合模型）；**预期竞态（状态已变、锁瞬时占用、residue 跳过）只写日志，不进聚合退出码**；每个 per-run 结果落 `autopilot.log` 一个 result 分类列（acted/skip-race/needs-human/error） |
| QA-07 | **主要** | relay 提醒**无去重、默认值缺失**：watch 每 30s 扫描，一旦 waiting_since 超过 relay-after，**每轮扫描都会 relay** → writer pane 刷屏（tmux 消息是直接注入 pane 的，模型 mid-turn 时消息堆积）。`--relay-after MIN` 给了 flag 没给默认值；`--interval 30` 有默认而 relay-after 没有，spec 无法测试 | input §2.2 flag 表；v0.4 relay 机制（best-effort 直接 pane 消息） | 默认值 pin 进 spec（建议 relay-after 默认 30min、interval 默认 30s）；观测文件增加 per-run `last_relay_at`，规则"同一 run 每 N 分钟最多提醒一次"；提醒内容幂等（同一状态重复提醒只发一次） |
| QA-08 | **主要** | 全局锁**作用域与生命周期未定义**，与 v0.4 锁假设不匹配：v0.4 锁的 stale 恢复（kill -0 + 删锁重取）假设持有者死于**一次秒级短事务**；watch 是小时级常驻持有——SIGSTOP 的 watch（kill -0 通过）会让 cron `--once` **永久 exit 4**；PID 复用会让死锁被误判为活锁。watch 与 --once 双跑时"锁是否足够"草案自问但没答 | `lib/lock.sh` arena_lock_acquire/release 语义；input §3 风险第 4 条 | 明确锁策略：watch **全周期持有全局锁**（trap EXIT/TERM 释放，SIGKILL 由 dead-PID 恢复兜底）；`--once` **按动作获取**、遇活锁记日志跳过（或按 QA-06 的 4 语义返回）；SIGSTOP/PID 复用写入威胁模型与运维文档（"watch 卡死时 pkill 后重起"）；lock 消息 "transition in progress" 在 autopilot 场景改成 "another autopilot is running" |
| QA-09 | 次要 | `autopilot.tsv` 语义未钉死（草案自问"观测文件还是权威"）：v0.4 spec 已预留"future heartbeat = separate observation file, not a state-field placeholder"——答案必须是**观测文件**；且 last_scan_at 的读改写（scanned/acted/errors 计数）在双实例下会互相覆盖 | v0.4 spec "No last_heartbeat_at in v1" 段；input §3 风险第 5 条 | spec 显式声明：autopilot.tsv 与 autopilot.log 均为观测产物，**任何状态转移命令不得读取**；last_scan_at 用 mktemp+mv 原子替换；计数类字段在全局锁内更新；补一条测试"autopilot.tsv 存在/缺失/陈旧不影响 status 与任何转移的退出码" |
| QA-10 | 次要 | project.conf 前后向兼容未声明：v0.4.0 严格解析器遇到 `approval_mode` 行会 `arena_die`（未知行即死）——升级后回滚 v0.4.0，或另一台机器仍跑 0.4.0，同一 repo 的所有命令全挂。mode 固化时机（start 时写入 manifest，之后改 config 不影响已启动 run）是**好设计**但需文档化 | `lib/config.sh` 未知行 die；input §2.1 | 写进 Drift/risk/rollback：v0.5 配置不被 v0.4.0 读取，回滚需先移除 `approval_mode` 行（fail-closed 且信息明确，可接受但必须声明）；README 明示"改 config 只影响之后 start 的 run" |

## R3 — 集成与错误

| # | 级别 | 发现 | 证据/推理 | 建议 |
|---|------|------|-----------|------|
| QA-11 | **主要** | 并发正确性论证不完整：设计说"resolve 有 run lock + 状态 guard"——这点**成立**（T10 guard 在锁内重查，scan→act 的 TOCTOU 被吸收，这是本设计最强的安全属性），但 autopilot 必须把 resolve 的 exit 2/4/5 当作**预期结果分类处理**，否则会出现"resolve 返回 2 → autopilot 视为自身故障 → 重试风暴或错误报警"。动作结果分类表缺失 | v0.4 T10 guard（锁内重查）+ resolve 退出码；input §2.2 动作矩阵 | 在 spec 里定义 **action result 分类表**：成功（0）/预期跳过-状态已变（2，记日志）/锁竞争（4，下轮再试）/residue（5，下轮再试）/真正错误（config 损坏、mode 不可读），并规定每类的日志与退出码贡献（接 QA-06） |
| QA-12 | 次要 | 时间相关测试 seam 缺失：interval=30s、relay-after=分钟级，hermetic 测试不能真等。草案只保证 "--once 单轮"可测，watch 与 relay-after 无测试路径 | v0.4 测试全部直接写 state 文件（如 §47 or-run fixture）、fake_bin 模式已存在 | 钉进 spec：`--interval`/`--relay-after` 接受 0（测试合法值）；测试用 PATH 注入 fake `date`/`sleep`（既有 fake_bin 模式）；加 `ARENA_AUTOPILOT_MAX_SCANS` 测试护栏 + TERM trap；`--once` 有界运行时间断言；waiting_since 直接写旧值制造超时（既有模式） |
| QA-13 | 次要 | 双 watch 与 --once 并发扫描会对同一 run 同时 relay/同时写心跳计数（QA-07 的 last_relay_at 与 QA-09 的计数都是读改写）——dedup 状态脱离全局锁就失效 | input §2.4 AC6 只提单实例 | dedup 字段与心跳计数的读写必须在全局锁内或原子替换；加一条并发 fixture（两个 autopilot 同跑，断言 relay 不重复、心跳不撕裂） |
| QA-14 | 信息 | 集成验收缺真实环境冒烟：hermetic 只能覆盖 fake 层，v0.4 的"真实 Cursor 冒烟已验证可全自动"是发布依据；v0.5 的 auto 模式（start→submit→validate→decision→autopilot --once→completed + actor 审计行）应作为发布门槛与 AC7 并列 | v0.4 现状事实"评审环已被真实 Cursor 冒烟验证" | Gate 验收增加一条真实环境 auto 全流程冒烟，断言：completed 状态 + `last_transition_actor=autopilot`（或 system）+ autopilot.log 记录一致；与 hermetic 测试分开记录（对齐 v0.2 的"non-claims"先例） |
| QA-15 | 信息 | 心跳 stale 是观测数据的合理用途（last_scan_at 超过 2×interval → watch 死亡 → cron 报警），草案未用；status 可考虑加一行 "autopilot: stale"（只读观测，不进退出码）——可选，但成本低价值高 | input §2.3 心跳；QA-09 | 可选：status 增加 autopilot 心跳陈旧提示（信息级，不改变任何退出码），并在 autopilot.tsv wire contract 里定义列（timestamp/run_id/action/result/exit_class），让观测工具可稳定消费 |

## 三个最尖锐的质疑

**Q1（契约自相矛盾）**：你一边说"actor=autopilot、SHA 决策记录不变、审计链不变"，一边说"不修改 v0.4 T 矩阵/命令语义"。但 v0.4 的 wire contract 把 `last_transition_actor` 钉死在 4 个值，读取端对枚举外值直接判损坏（exit 2）。v0.5 写出的状态文件，0.4.0（已发布）根本读不了——这**就是**契约变更，只是 fail-closed 让它看起来"安全"。请明确裁决：改枚举（写 Drift 声明 + 兼容测试），还是退回 actor=system + reason 标记（放弃状态文件的执行者粒度）？不要既宣称不变又悄悄改了枚举。

**Q2（退出码双标）**：`--once` 的 exit 2 定义为"发现需人工介入"，而 v0.4 全协议 2=非法转移/损坏/冲突。同一码值，一条命令里是"正常但有活要干"，另一条里是"错误"。cron 脚本按 2 分类处理时必然误判；何况草案还要把 corrupt/conflict 也"聚合"进退出码——2 到底代表什么？优先级是什么？预期内的竞态（resolve 返回 2）算不算 2？v0.4 有 5>4>2>0 的明确表，autopilot 必须给一张同样穷举的表，否则 AC4/AC2 不可测。

**Q3（无人值守的承诺与空洞）**：relay 是 best-effort（v0.4 README 明示 tmux 不知道模型是否 mid-turn），你的"提醒 writer"既不能保证送达也不能驱动行动；而矩阵对 reviewer 侧停滞（review_pending/decision_pending 静默停摆）和 human 模式下的 approval_pending 连报警都没有定义。如果 AC 按"任务自动推进到完成"验收，这个设计只覆盖了 approval 一环。请把承诺收窄为"自动完成 human-approval 环节 + 全状态停滞报警"，并补全状态×模式真值表——否则"无人值守"四个字会被验收测试当场打脸。

## 决策点表态

**A（list 是否加 MODE 列）：不加，保持 v0.4 row contract 不变。**
理由：(1) v0.4 spec 钉死 11 列，测试 §29/§47 既断言 header 又**按列位置解析**（`list_column` 用 awk 字段号 5/6/7/8/10/11），加列在任何位置都会破坏位置型消费者（脚本/oracle），v0.4.0 已发布，这是已承诺的外部契约；(2) mode 是 per-run 配置来源信息，最自然的消费点是 status（草案已有 Mode 行）和 autopilot 自己的扫描输出（建议 autopilot 每轮打印 per-run mode/action 摘要——operator 要的"哪些 run 会被自动批准"在这里看，比 list 更贴近动作）；(3) list 是异常导向的运维视图，mode 不改变任何 ANOMALY 语义。若产品确实需要，作为 v0.6 的**显式 contract 升级**处理：列追加到**末尾**、spec+测试同步更新、文档声明消费者 break——而不是在"不破坏 v0.4"的 v0.5 里偷偷改。

**B（resume 自动重试默认值）：默认 0（只报警）。**
理由：(1) **v0.4 实测事实：resume 后真实环境会弹 trust prompt，需人工确认**——auto-resume 只是再 spawn 一个停在 trust prompt 的 pane，reviewer 模型实际仍不可用；T12 recover 的 pane-liveness 检查会"通过"，产生**假恢复信号**（状态机认为 reviewer 可达，但模型从未真正就绪），比不恢复更糟——它会把一个真实的阻塞伪装成正常；(2) 自动 resume 在 run lock 内执行，会与正在手工确认 trust prompt 的人类/其他进程竞争，制造锁噪音；(3) 若将来实现，--resume-attempts>0 必须显式开启，且日志把"respawn 成功"与"trust 已确认"**分开记录**（后者永远为 false，直到人工确认），并把"auto-resume 不解除 reviewer_unreachable"写进 README 非承诺表。

## 一句话总结

**方向成立**——autopilot 作为"状态机外部的守护进程"、复用既有 resolve 通道代办 T10，run lock + 状态 guard 吸收 TOCTOU、SHA 审计链保持权威，这是正确的分层（守护进程可死可重启，状态机不动）；**但最大风险是 v0.5 一边宣称"不破坏 v0.4 契约"一边实际触碰了 actor 枚举、退出码协议、list/config 输出三处钉死契约**——必须把这三处作为显式 drift 声明、逐项补 hermetic 断言（含"读取端接受 autopilot 仍拒绝未知值""--once 退出码优先级""relay 去重""锁作用域"），并把"无人值守"承诺收窄为"自动 approval + 全停滞报警"，否则"50 节零改动"会掩盖契约漂移，验收时被真实环境当场戳穿。
