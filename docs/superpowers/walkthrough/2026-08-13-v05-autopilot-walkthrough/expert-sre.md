# v0.5 设计走查专家评审：SRE（无人值守运维）

> 角色：sre — 无人值守运维专家（心跳/监控/报警、cron 与常驻双跑、会话生命周期、writer/reviewer 不可达恢复、长期运行可靠性）。
> 评审对象：`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/input-design.md`（v0.5 草案），依据 v0.4 spec（run-state-authority）与 AGENTS.md。
> 评审视角声明：SRE 对任何自动化系统的第一问题是「失败时它如何被看见」。v0.4 已经把「状态权威 + 锁定 + 审计」做到了单命令级可靠；v0.5 的真正难点不是让 autopilot 正确动作，而是让「autopilot 没动作 / 动作了但没生效 / 监控者自己死了」这三种失败模式可观测、可报警、可恢复。

---

## 1. 三轮走查发现

### R1 用户故事 / AC：无人值守的「完成」定义与健康信号

**【严重】「无人值守推进到完成」存在完成边界缺口：Arena completed ≠ 代码交付。**
证据：v0.4 spec 明示「Terminal actions change Arena state only: no merge, push, worktree cleanup, or tmux teardown」。auto approve 把 run 推到 `completed` 后，代码仍停留在未合并的 worktree 分支上——无人值守场景下，operator 看到 `completed` 会误以为「活干完了」。草案 §0 的目标句「完全无人参与地推进到完成」对「完成」没有定义。
建议：AC 中显式声明完成边界（v0.5 的「完成」= Arena 状态 `completed`，交付/合并为范围外后续动作），并在 runbook 中写明 `completed` 之后的处置；可考虑增加 post-completed 通知钩子（如 relay 到人工通道），让「状态完成」与「人工收尾」之间有明确的交接信号。

**【严重】autopilot 动作矩阵只按 state 键控，缺少 pane 活性维度——最常见的无人值守故障在状态机里不可见。**
证据：v0.4 中 `reviewer_unreachable` 只能由 T9 `escalate` 产生；reviewer pane 在 `submitted`/`validated` 期间死亡不会改变任何状态。草案动作矩阵没有任何行覆盖「active/submitted + reviewer pane dead」或「changes_requested + writer pane dead」——这意味着无人值守下最典型的故障（模型 pane 死亡）会无限期静默停摆，autopilot 每 30s 扫描一次却一行都匹配不到。`status` 已有 pane liveness 观测能力（v0.4 spec：check tmux session and pane liveness），`list` 没有，草案也没说 autopilot 会探测。
建议：每轮扫描加入 pane 活性探测，并扩展动作矩阵为「state × pane 活性」二维：
- RP=reviewer 且 pane dead（submitted/validated）→ 自动 `escalate --reason-code reviewer_unreachable`（T9 对该状态合法）后按决策 B 处理，或直接报警；
- RP=writer 且 pane dead（changes_requested/human_changes_requested）→ 报警（v0.4 `resume` 只覆盖 reviewer，writer 无自动恢复路径，必须先报警）；
- 增加 progress-stall 检测：同一 run 的 `state_revision`/`WAITING_SINCE` 停滞超过 per-state 阈值（如 review_pending > 30min）→ 报警。WAITING_SINCE 是现成的停滞信号，扫描时零成本可得。

**【主要】relay 提醒无冷却机制：`--relay-after` 超时后每轮扫描（默认 30s）都可能重复向 writer pane 发送提醒。**
证据：v0.4 README 明示「tmux cannot know whether an interactive model is mid-turn」；relay 是 best-effort。30s 一轮的重复消息会打断模型 mid-turn，且「提醒丢了 → 永远没人管」没有升级路径。
建议：autopilot 记录 per-run+reason 的 `last_relayed_at`（可并入 autopilot.tsv 或独立状态），冷却期内不重发（如 30min）；并定义升级链：relay 后仍无状态进展超过阈值 → 提升为报警（exit 2 / 通知）。

**【主要】AC 缺少 alerting 契约与「监控者自身存活」闭环。**
证据：草案只有心跳写入方（autopilot.tsv）与 --once 退出码，没有定义谁消费心跳、`--once` 退出码进 cron 后如何报警、watch 进程死亡后谁发现。无人值守系统第一原则：必须监控监控者。
建议：AC 增加 heartbeat freshness 消费方（如 cron 检查 `last_scan_at` 年龄 > 2×interval 即报警的一行命令/`--health` 子命令）；把 `--once` + cron/launchd 定位为受支持的主路径（有 supervisor、掉电补跑语义清晰），`--watch` 定位为便捷工具并文档化其 supervisor 要求。

**【主要】`--once` 聚合退出码语义未定义优先级，且 2 与 v0.4 退出码协议语义重叠易混淆。**
证据：草案 §2.3 说「corrupt/conflict/incomplete 记录错误，聚合退出码」，§2.2 又说「2=发现需人工介入」——多 run 混合时（一个 corrupt + 一个 blocked）到底返回哪个？且 v0.4 协议中 2 = 非法迁移/损坏，运维侧 cron 规则无法区分「需要人工」与「系统错误」两种严重级别。
建议：为 autopilot 定义独立退出码协议并文档化优先级（如 0=正常；2=需人工介入；3=运行错误（corrupt/conflict/incomplete）），corrupt/conflict 应优先于 blocked 上报；与 v0.4 码表的关系在 spec 中单独成节。

**【次要】长期运行的环境因素未覆盖：机器 sleep/时钟跳变导致 interval 漂移与超时误判；autopilot.log 无轮转。**
证据：草案 `--interval 30` + 基于本地时钟的 WAITING_SINCE 比较；笔记本 sleep 8h 后唤醒会立即触发所有超时路径（relay 风暴/误报警）；append-only log 长期运行无界增长。
建议：文档化 sleep 行为（唤醒后先静默扫描一轮再判定超时，或接受立即触发但靠冷却限流）；log 增加大小上限+轮转（或复用审计侧的归档目录）。

### R2 技术追踪 / 契约状态：锁、心跳与审计

**【严重】autopilot 全局锁无心跳/过期机制：watch 挂死时 cron `--once` 永久 exit 4，自动化静默失效且无报警。**
证据：lib/lock.sh 的活性判定是 `kill -0 <pid>`，60s grace 只覆盖 mkdir→owner 元数据窗口；长驻 watch 进程无锁心跳 renewal。若 watch 因 relay/tmux 阻塞挂死（不退出、PID 存活），`--once` 永远拿到 live lock → exit 4；而 exit 4 的 cron 报警恰好因为 `--once` 根本没完成扫描而不会产生——监控死循环（详见质疑 3）。
建议：全局 autopilot 锁的 owner 定期刷新（renewal 时间戳），扫描方对「锁年龄超过 N×interval」判定为僵尸锁并报警/接管；或更简单：文档化单一运行者约定（watch 与 cron --once 二选一，以 --once 为主），并在锁 owner 元数据中写入 autopilot 实例标识（pid+启动时间+state root）便于排障。

**【主要】watch 与 cron --once 双跑语义未定义：锁只保证互斥，不保证「谁该干活」，互斥失败还表现为 exit 4。**
证据：草案 §2.4.4 说「复用 lib/lock.sh 防多实例并发」，但未定义双实例并存时的行为（--once 遇活锁是重试、报警还是直接退出？）。锁顺序本身安全（autopilot 全局锁 → run lock，与人工 resolve 的 run lock 无环），但运维侧需要明确预期。
建议：定义主运行者（primary runner）约定 + 测试双实例互斥（第二个实例 exit 4 且输出「autopilot already running (pid …)」）+ 文档化「watch 运行中无需再跑 --once」。

**【主要】审计链的崩溃窗口：resolve 已提交但 autopilot.log 未 append 时动作日志缺失；必须明确 log 是观测文件而非权威。**
证据：草案 §2.3 动作日志 append-only；autopilot 在 resolve 成功与 log 写入之间崩溃会留下「状态已 completed、日志无记录」。若 operator 以 autopilot.log 做审计，这是一个缺口；但 v0.4 审计权威是 SHA 绑定 decision 记录 + run-state 的 `last_transition_actor=autopilot`，log 缺失不破坏权威链。
建议：spec 明示「autopilot.tsv/autopilot.log 均为观测文件，权威审计 = run-state 的 last_transition_actor + SHA 决策记录（与 v0.4 不变）」；测试覆盖「resolve 已提交、log 缺失」场景断言状态权威、日志可补记；动作日志在动作后 append（best-effort）即可，但心跳必须在每轮扫描**结束**后原子写（tmp+mv），证明「完整扫描」而非「扫描开始」。

**【主要】无 kill switch / 熔断：auto approve 在 30s 内自动执行，运行中没有暂停手段。**
证据：草案护栏只有 opt-in 配置；一旦发现 autopilot 行为异常（如 reviewer 被提示词绕过误 APPROVE），operator 只能改配置+杀进程，无法瞬时熔断。auto 模式放大了同 UID 伪造威胁的即时性（v0.4 F5：reviewer 同 UID 可伪造证据；auto 模式下伪造的 APPROVE 30s 内被自动批准，无人工窗口）。
建议：增加 state root 级 pause 标志（如 `touch <state_root>/.autopilot.pause`，autopilot 每轮检查，存在即跳过动作只记录）作为 kill switch；可选 `auto_approve_delay`（approval_pending 后等待 N 分钟再批准）为人工干预留窗口；增加连续失败熔断（同一 run 连续 N 次动作失败 → 停止该 run 并报警）。

**【次要】单机假设未声明：锁活性基于 PID，跨主机共享 state root（NFS/同步目录）会误判活锁或误释放。**
证据：lib/lock.sh `kill -0 <pid>` 是主机本地语义；两台主机共享 state root 时 A 机的锁会被 B 机判为死 PID 而 rm -rf。
建议：spec 明示「state root 仅支持单机访问，多机共享 out of scope」。

**【次要】mode 绑定时机应显式化：start 时写入 manifest，运行中修改 project.conf 不影响存量 run。**
证据：草案 §2.1「start 时写入 run manifest 的 mode 字段；旧 manifest 无字段 = human」——这是对的（审计稳定性），但 spec 未明说「改配置只影响新 run」。
建议：明示 + 测试覆盖「start 后改 approval_mode，存量 run 的 manifest mode 不变」。

### R3 集成 / 错误：兼容性、故障隔离与并发

**【主要】status 加 Mode 行 / list 加 MODE 列与「v0.4 50 节零改动」目标存在张力。**
证据：tests/run.sh 对 list 表头有 `require_match 'REPOSITORY RUN_ID PROFILE GATE RUN_STATUS PHASE PARTY REASON_CODE WAITING_SINCE AUTHORITY ANOMALY'` 断言；status 诊断句有 `require_match 'waiting on reviewer for review_pending'` 断言。追加列若放在表头**末尾**，现有 require_match（子串匹配）仍会通过，但 row contract 是 v0.4 spec 钉死的公共契约（下游解析器可能按位置索引解析），「零改动」不能等同于「零契约影响」。
建议：将 AC7 的「50 节零改动」改为「50 节零语义改动 + 允许最小适配（新增列/行断言）」，并把 list/status 输出变更作为契约 bump 与 spec+测试同步提交（决策 A 表态见 §3）。

**【主要】单 run 动作失败隔离缺失：一个坏 run 可能拖死整个 watch 循环，或造成竞态风暴。**
证据：草案无「动作失败后怎么办」；若 resolve 因并发返回 exit 2/4，或状态文件 corrupt 返回 exit 2，watch 循环若无 per-run 错误隔离与失败计数，可能崩溃退出（无人值守下=静默停机）或无限重试刷屏。
建议：per-run 错误隔离（异常只记录到 autopilot.log/聚合退出码，循环继续）；同一 run 连续失败 N 次（如 3 次 exit 2/4）后暂停该 run 并报警；扫描循环自身遇到致命错误（state root 不可读、权限错误）必须「响亮失败」：log + 非零退出 + 心跳标注 error，绝不静默空转。

**【主要】并发 human resolve 与 autopilot resolve 的竞态未定义：双方可能同时处理同一 approval_pending。**
证据：autopilot 与人工都可能对 `approval_pending` 执行 resolve approve；run lock 保证只有一个提交成功，但败者拿到 exit 2/4——设计需明确这是良性竞态（log 即可，不算系统错误）。
建议：测试覆盖「autopilot resolve 与人工 resolve 并发，恰一方成功、败者记录 conflict/lock 且状态最终一致」；autopilot 对 exit 2/4 的处置按 R3 第二条（计数+暂停，不视为故障风暴）。

**【次要】自动 resume（若启用）与 trust prompt 的「活但不可用」陷阱：respawn 后 pane 停在 trust prompt，liveness 检查可能通过但模型无法行动。**
证据：v0.4 实测「真实环境会弹 trust prompt，需人工确认」；recover 的 reachability 检查 = 活 pane + 模式 + input on，不验证模型可用。自动 resume 可能制造通过 liveness 却永不 validate 的僵尸 reviewer。
建议：默认 0 是正确选择（决策 B 表态见 §3）；若未来支持 N>0，必须与「resume 冷却」「trust 确认状态探测」「progress-stall 报警」一起设计，且 spec 明示「resume 成功 ≠ 恢复可用」。

**【信息】legacy/旧 manifest 路径的 Mode 显示：旧 manifest 无 mode 字段 → human，但 status 的 Mode 行对 legacy 投影 run 的输出未定义。**
建议：测试覆盖 legacy run 的 status Mode 行与 list MODE 列（`human`），保持向后兼容语义明确。

---

## 2. 三个最尖锐的质疑

**质疑 1：动作矩阵凭什么只按 state 键控？死 pane 不改状态，而「pane 死亡」恰恰是无人值守最典型的故障。**
v0.4 里 `reviewer_unreachable` 只能由人工 `escalate` 产生；reviewer 在 `submitted` 期间死亡、writer 在 `changes_requested` 期间死亡，状态机纹丝不动。草案的 autopilot 每 30s 扫描一次，但对这种静默停摆一行都匹配不到——请问设计者：autopilot 到底有没有在看 pane？如果看，矩阵为什么没有「submitted/validated + reviewer pane dead」与「changes_requested + writer pane dead」的行？如果不看，「无人值守」的承诺建立在什么假设上——pane 永不死亡？

**质疑 2：「无人值守推进到完成」的「完成」到底是什么？**
v0.4 明示终端动作不 merge、不 push、不清理 worktree。auto approve 之后 run 是 `completed`，代码却还躺在 worktree 分支上。如果 Arena completed 就是终点，这个文案是过度承诺（operator 以为活干完了，实际没有交付）；如果要真交付，那 merge/push 属于 v0.5 范围外，谁、用什么机制、在什么审计约束下兜底？草案对「完成边界」没有任何一句话，无人值守场景最怕的就是「状态与事实不一致」。

**质疑 3：谁监控监控者？这个系统有一个监控死循环。**
心跳 autopilot.tsv 只有写入方、没有消费方；watch 挂死 → 全局锁被活 PID 永久持有 → cron `--once` 永远 exit 4（活锁）→ 而 exit 4 的报警依赖 `--once` 跑起来输出结果——它永远跑不起来。心跳陈旧、锁陈旧、`--once` 全灭，三种失败全部静默。请问：operator 从什么信号能发现「autopilot 已经死了 3 小时」？如果没有，这个无人值守系统本身就是需要人值守的。

---

## 3. 决策点表态

**决策 A（list 是否加 MODE 列）：升级 contract，追加列（置于表尾），同步改 spec+测试。**
理由：list 是无人值守的仪表盘，mode 是「这个 run 是否自治、失败时该找谁」的第一信息，不加列意味着 operator 必须逐 run `status` 才能分辨——这正是运维事故的温床。v0.4 冻结 row contract 是版本内承诺，不是永久冻结；追加尾列对按 header 解析的消费者向后兼容（对按位置解析的消费者，这是有意的、一次性的契约 bump，随 spec+测试同 commit 发布即可）。同时 status 的 Mode 行一并纳入测试。反对「完全不变」的理由：把 mode 藏进 status 会让自动化巡检（list 的 ANOMALY 聚合）对「auto 模式 run 卡在需人工状态」失明。

**决策 B（resume 自动重试默认值）：默认 0（只报警），强烈反对默认开。**
理由：v0.4 实测 trust prompt 必须人工确认——自动 resume 无法闭环恢复，只会制造「respawn → 停在 trust prompt → liveness 通过但模型不可用」的僵尸 reviewer 与 pane 风暴；在无人值守下，一个「看起来在动、实际没动」的 pane 比一个明确报警的死 pane 危险得多。正确的无人值守行为是：明确报警 + runbook（人工 resume + 确认 trust + recover 两步）。若未来要支持 N>0，必须与死 pane 自动检测、resume 冷却、trust 确认探测、progress-stall 报警整体设计，且默认值仍应保守。

---

## 4. 一句话总结

**方向成立**——「状态机不动、autopilot 外部编排、复用 run lock 与审计链」是正确架构，v0.4 的原子性/审计资产被完整继承；但当前草案最大的风险是**健康信号缺失**：动作矩阵只看状态、不看 pane 活性与进展停滞，监控者自身无存活报警、无 kill switch，无人值守系统的三类失败（动作没发生、动作没生效、监控者死了）都可能静默——无人值守系统最危险的失败是不报错的失败，必须补上 pane-liveness × progress-stall 二维检测、heartbeat freshness 报警与熔断/暂停机制，否则 v0.5 交付的是「自动化的假象」而非「自动化的可靠」。
