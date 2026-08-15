# v0.5 走查专家评审：expert-product（产品与工作流）

> 评审对象：`docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/input-design.md`
> 评审角色：product — 产品与工作流专家（human/auto 场景覆盖、配置 UX、切换体验、运营语义、模式开关粒度）
> 依据材料：input-design.md、v0.4 spec（run-state-authority）、`lib/config.sh`/`lib/relay.sh`/`lib/start.sh`/`lib/list.sh`/`lib/status.sh`
> 方法：SDD 三轮白板走查（R1 用户故事/AC、R2 技术追踪/契约状态、R3 集成/错误）

---

## R1 用户故事与验收标准

### R1-1【严重】双模式缺少运行时切换路径：mode 是 start 时的一次性快照，"下班放手 / 上班接管"两个核心工作流不可达

**发现**：草案 §2.1 只定义 `start` 时把 `approval_mode` 落进 run manifest，此后没有任何命令能把一个已存在的 run 从 human 切到 auto 或反向切换。产品上双模式最大的价值恰恰是**运行期切换**：operator 下班前把 run 切 auto 放手、第二天早上切回 human 接管；或者一个 run 本来 auto 跑，operator 发现它重要想收回来人工把关。这些场景 v0.5 全部不可达——只能 cancel 重开，而 v0.4 的 cancel 是终态、重开是全新 run，审计链断裂、waiting_since/round 全部归零。

**证据/推理**：§2.1 全文只有 "start 时写入 run manifest 的 mode 字段"；§2.2 命令列表（autopilot）与 §2.5 AC 草案中没有任何 mode 查看/切换命令；`lib/config.sh` 现有解析只认 `project_name|validation_script` 两个 key，无 mode 读写路径。manifest 在 start 后由 `arena_write_manifest` 一次写入，v0.4 无运行期改写 manifest 的先例（resume/submit 都只读 manifest）。

**建议**：v0.5 增加 per-run 切换命令（如 `agent-arena mode RUN_ID human|auto`），受 run lock 保护、记录切换 actor 与时间（复用 `last_transition_actor` 审计语义），并在 status 中显示 mode 与最近一次切换。若技术评审认为 manifest 不可运行期改写，则必须给出替代契约（mode 独立文件或 state schema v2），而不是回避——回避等于把"双模式"降级为"双启动模式"，产品故事需要重写。

### R1-2【主要】"完全无人参与地推进到完成"承诺边界未定义，AC 缺端到端闭环用户故事

**发现**：v0.5 目标写的是"无人值守自动推进"，但动作矩阵里 auto 模式只自动 approve；changes_requested 依赖 best-effort relay + writer 自觉响应；BLOCKED/reviewer_unreachable 永不自动（resume 默认关）。真实无人值守会停的三个点（writer 无响应、reviewer pane 死亡、BLOCKED）全部不能自愈。产品语义上必须明说：**auto 模式 = 顺利路径的自动放行 + 停滞路径的自动报警，不是任务自愈**。

**证据/推理**：§2.2 动作矩阵 auto 列 = 自动 resolve approve + relay 提醒 writer + 可选 resume（默认 0=关）；§2.4 护栏 3/5 明确 cancel/reject 永不自动、resume 默认关。AC 草案 AC2 只测"auto 自动 approve 幂等"，没有任何"auto 模式完整闭环（submit→validate→decision→auto approve→completed）"或"changes_requested 循环"的验收项。

**建议**：补两个 AC——(a) auto 模式端到端闭环在 hermetic 环境走通（fake CLI 即可，不调模型）；(b) auto 模式下 writer 不响应/relay 失败时的行为（记录错误、不 crash、退出码可报警）。README 与发布说明用词从"完全无人参与"收敛为"自动放行 + 自动报警"。

### R1-3【主要】human 模式"只观测"过弱：提醒/报警应独立于审批模式

**发现**：动作矩阵把 relay 提醒 writer（changes_requested 超时）只给了 auto 模式，human 模式是"只观测"。但 relay 提醒是**通知**不是审批动作，对有人值守的 operator 同样（甚至更）有价值——operator 开着 watch 就是想被及时提醒"writer 卡住了"。把通知能力绑在审批模式上，等于让 human 模式的 watch 失去一半意义。

**证据/推理**：§2.2 矩阵：human 模式列对 changes_requested 写"只观测"；而 §2.3 里 `--once` 退出码 2"发现需人工介入"也是报警语义。报警语义本应与审批模式正交。

**建议**：把"relay 提醒/报警"从审批模式中解耦：human 模式同样对超时 relay 提醒并支持退出码 2 报警；auto/human 只决定**审批动作**（是否自动 resolve approve）。这也让 AC3（human 模式只观测）的定义更干净：human 模式 = 无审批动作，但可提醒可报警。

### R1-4【次要】配置 UX 细节未定：init 注释模板、严格 parser、auto 拼写错误的报错体验

**发现**：草案说 `approval_mode` 在 init 生成时"注释风险"，但没展开。现有 `lib/config.sh` 对未知行直接 `arena_die "invalid project configuration line"`——加入 approval_mode 必须同步 parser 正则与校验，注释模板格式必须匹配 parser（注释行 `#` 跳过是 OK 的，但 `approval_mode=auto  # 说明` 这种行尾注释会被判非法）。用户手改配置把 `auto` 拼成 `Auto`/`aoto` 时，是 start 时才 die 还是 init/config 校验时 die？后者体验好得多。

**证据/推理**：`lib/config.sh` 的正则 `^(project_name|validation_script)="([^"]*)"$` 只认两个 key、非注释行全部 die；§2.1 只说"init 生成时注释风险"。

**建议**：init 生成带注释的 `approval_mode=human` 模板行；`agent-arena init` 或新 `agent-arena config` 提供模式查看/校验；非法值在配置加载即报错并给出合法值列表（沿用现有 die 风格但错误信息要可操作）。

### R1-5【信息】resume 默认 0 正确，但 pane 死亡是无人值守的首要故障源，应进 roadmap 并显式预警

**发现**：resume 默认关与"trust prompt 需人工确认"的 v0.4 实测一致，是正确决策。但 reviewer pane 死亡 = `blocked/reviewer_unreachable` 是无人值守最可能的停滞点，默认只报警意味着无人值守的 MTBF 主要由它决定。

**证据/推理**：§2.2 矩阵 blocked/reviewer_unreachable 行；§1 v0.4 事实"真实环境会弹 trust prompt，需人工确认（v0.4 冒烟实测）"；§3 风险清单。

**建议**：把"gate trust prompt 免人工（会话级信任预授权）"列为 v0.6 前置项并在 README 明示；v0.5 中 `--resume-attempts N` 非 0 时，autopilot 启动输出必须打印"resume 后仍可能有人工确认步骤"的显式警告，防止 operator 误以为全自动。

---

## R2 技术追踪与契约状态

### R2-1【严重】mode 的权威落点与 v0.4 state schema 精确 key 契约正面冲突，草案未给 schema 策略

**发现**：v0.4 spec 钉死 `run-state.tsv` "key set is exactly the sixteen keys; a missing key, a duplicate key, or an unknown key is a corrupted file"，且 AC9 规定 future schema 拒绝（升级 Arena 才可读）。如果 mode 要进 run-state.tsv：加 key → 所有 v0.4 存量 run 变 corrupt；升 schema v2 → v0.4 无法读 v0.5 的 run、且 v0.4 rollback 语义（"stopping new transitions, keep v0.4 read-only interpretation"）被破坏。草案选 manifest 落档恰恰避开了这个冲突，但 manifest 是一次写入的快照——于是 R1-1 的切换需求在契约上无解。**这不是实现细节，是产品决策被 schema 约束绑架**。

**证据/推理**：v0.4 spec R2 十六 key 精确集合 + AC9 future-schema 拒绝；§2.1 "start 时写入 run manifest 的 mode 字段（旧 manifest 无字段 = human）"；manifest 写入仅发生在 start（`lib/start.sh` 中 `arena_write_manifest` 单点）。

**建议**：spec 层明确 mode 权威位置与演进策略，三选一：(a) 接受 manifest 快照 + 新增受锁保护的 mode 切换文件（`.agent-arena/<run>/mode` 或 state root 内），manifest 字段仅作初始值；(b) state schema v2 全量迁移（代价大，v0.4 50 节测试与 rollback 全受影响，不推荐 v0.5 做）；(c) 明示 v0.5 不支持切换（回到 R1-1 的产品后果）。我推荐 (a) 并让 status/list 统一从权威位置读。

### R2-2【主要】autopilot 作用域未定义：project.conf 是 repo 级，autopilot 扫描"每个 run"是 state-root 级——跨 repo 动作放大同 UID 威胁

**发现**：§2.2 "每轮扫描每个 run（读 mode）"没有说扫描哪个 state root、autopilot 在哪个 repo 上下文执行、会不会动作到 operator 当前目录之外的其他 repo 的 auto run。如果 autopilot 默认扫全 state root，任何能跑 agent-arena 的进程开一个 autopilot 就会自动放行**所有 repo** 的 auto run；如果只扫当前 repo，多 repo 无人值守需要 N 个 autopilot 进程，锁与心跳语义都要重想。

**证据/推理**：§3 风险第 1 条（同 UID 威胁）讨论的是"能否开 autopilot"，但没讨论"autopilot 能作用到哪些 run"；`lib/relay.sh`/`lib/status.sh` 均以 run_id 定位，`lib/config.sh` 以 repository 定位，现有命令没有 state-root 级批量语义。

**建议**：autopilot 增加显式作用域（默认当前 repo 的 runs，`--state-root`/`--all-repos` 需显式开启），并在 heartbeat/log 中记录每轮扫描的作用域；README 明确"autopilot 只作用于其启动时的作用域，跨 repo 动作必须显式声明"。

### R2-3【次要】status Mode 行 / list MODE 列 / autopilot.tsv 三者一致性缺失，心跳陈旧告警未定义

**发现**：§2.1 status 加 Mode 行、决策点 A 讨论 list 列、§2.3 心跳 autopilot.tsv（last_scan_at/scanned/acted/errors）。但草案没说：谁读 autopilot.tsv、陈旧心跳如何告警。无人值守最危险的静默失败是 **autopilot 进程死了 operator 不知道**——watch 挂在 tmux 里崩了，run 停在 approval_pending，operator 以为 auto 在跑。产品上必须有"最后一次扫描时间"的告警语义（类似 lock 的 stale 规则）。

**证据/推理**：§2.3 只定义心跳写侧（字段清单），无读侧与陈旧阈值；v0.4 lock 有 60s grace + dead-PID 恢复先例可复用。

**建议**：`status`（或 autopilot.tsv 摘要子命令）输出 last_scan_at 与"autopilot 存活"行；扫描间隔超过 N×interval 时 status/list 报 stale（可复用 lock 的 stale 判定思路）；明确 autopilot.tsv 是观测文件而非权威（写者唯一 = autopilot 进程，锁内更新）。

### R2-4【信息】mode 是 binary 开关、粒度粗：per-run 策略覆盖应显式留给 v0.6

**发现**：auto 模式对同一 repo 下所有 auto run 一视同仁（APPROVE 全放行）。产品上"这个 run 的 APPROVE 自动过、那个 run 要人看"是真实需求（高风险 repo/PR 例外），v0.5 不做可以，但要在 spec 里显式声明 out of scope，避免 operator 拿 project.conf 的 repo 级开关硬凑。

**证据/推理**：§2.1 mode 是 project.conf 单值 + manifest 快照；§2.5 AC 无策略粒度项。

**建议**：spec 加一行 out-of-scope："per-run 策略覆盖（如仅自动 approve 特定 profile/repo、round 上限）属 v0.6"，防止需求蔓延；AC 保持 binary 语义。

---

## R3 集成与错误

### R3-1【严重】relay 提醒无节流去重：changes_requested 超时后每轮扫描都会再次 relay，spam writer pane

**发现**：动作矩阵"active/writer/changes_requested 超时（>relay-after）→ relay 提醒 writer"。超时条件在后续每轮扫描都成立，草案没有任何"上次提醒时间"去重字段——`--interval 30` 意味着每 30 秒向 writer pane `send-keys` 一条消息。v0.4 relay 是 best-effort，但 send-keys 本身是确定性的：**每轮都会真发**。writer 模型 mid-turn 时消息直接打断（v0.4 README 明示 tmux 无法感知 mid-turn），这不是"提醒可能丢失"，而是"提醒必然刷屏"。

**证据/推理**：`lib/relay.sh` 对 live pane 无条件 `tmux send-keys -l` + Enter；§2.2 矩阵无 last_relay_at/去重；§2.3 autopilot.log 只有 timestamp/run_id/action/result，无提醒去重状态。

**建议**：per-run 记录 last_relay_at（可放 autopilot.tsv 或 run 目录），relay 至少间隔 relay-after（或更长，如 2×relay-after）；relay 消息加 `[autopilot]` 前缀；同一 run 同原因重复提醒在 log 中记 `skipped (throttled)`，让 operator 可观察。

### R3-2【主要】auto 模式下 operator 无"知情/接管"优先权：30s 轮询可能抢先于人工完成 approve

**发现**：auto run 到达 approval_pending 后，autopilot watch 每轮自动 approve。operator 若想先看一眼再放行（比如 auto 模式下的重要改动），没有任何 pause/接管机制——他只能眼睁睁看着 30s 内被自动 approve，或提前全局改配置（影响其他 run）。产品上"人工永远可优先于自动化"是双模式工作流的第一原则，草案只有 opt-in 没有 opt-out-at-runtime。

**证据/推理**：§2.2 无 pause 语义；§2.4 护栏只约束"永不自动"的边界（cancel/reject/BLOCKED），没有约束"人工想手动时如何阻止自动"；v0.4 resolve 仍是合法 human 命令，但 autopilot 与人工 resolve 之间没有优先级约定（lock 只保证不双写，不保证人工先手）。

**建议**：至少实现运行期 pause：`autopilot --pause`（touch 一个 pause 文件，watch 轮询检查）或 SIGSTOP；文档明确"人工 resolve 与 autopilot 竞态下，先到者胜，lock 保证原子"；理想是 per-run 临时接管（切 human 即暂停该 run 的自动动作），与 R1-1 的切换命令共用机制。

### R3-3【主要】`--once` 退出码 0/2 二分粒度不足，stdout 无 per-run 摘要，cron 告警语义模糊

**发现**：§2.3 退出码 0=正常、2=需人工介入。但"正常"包含三种截然不同的结果：(a) 本轮无待办（全 completed/等待中）；(b) 自动 approve 了若干 run（有动作）；(c) changes_requested 超时已 relay 提醒（有动作但任务没推进）。cron 环境下 operator 无法区分"一切安好"与"卡住但已提醒"，而后者恰恰是需要升级人工的早期信号（writer 长时间不响应）。

**证据/推理**：§2.3 只给两个退出码；§2.2 矩阵中 changes_requested 超时属于 auto 模式的常规动作，不算"需人工介入"。

**建议**：`--once` stdout 输出 per-run TSV 行（run_id/mode/state/action/result，与 autopilot.log 同构，方便 cron 解析），退出码细化（0=无动作；2=需人工；可考虑 3=发现停滞超时已提醒），并在 README 给 cron 告警示例（grep 退出码 2/3 + 摘要行）。

### R3-4【次要】watch 与 cron --once 双跑的锁冲突 UX 未定义

**发现**：§2.4 护栏 4 说 autopilot 复用 lib/lock.sh 防多实例并发，但没说锁冲突时第二个实例的行为与退出码。v0.4 有先例：锁冲突退出 4（transition in progress）。如果 --once 撞上 watch 返回 4，cron 会把"另一个 autopilot 在跑"当成故障报警。

**证据/推理**：v0.4 lock 协议 exit 4；§2.3 --once 退出码只有 0/2；§3 风险第 4 条只问"锁是否足够"。

**建议**：明确锁冲突退出码（复用 4）并在 autopilot --help/README 写明"watch 与 cron --once 并存时，--once 返回 4 属正常，cron 应忽略 4 或改为只跑 --once 单一形态"；给出推荐部署矩阵（有人值守=watch；无人值守=cron --once，二选一）。

---

## 对设计草案最尖锐的 3 个质疑

1. **mode 快照之后，到底怎么切换？** 草案没有任何 human↔auto 运行期路径，而"下班放手、上班接管、重要 run 收回人工"是双模式产品故事的核心场景。如果答案是"不支持切换"，v0.5 实际交付的是"双启动模式"而非"双运行模式"，目标句"有人值守与无人值守两种场景都被覆盖"就不成立——因为一个 run 的守候方式在 start 时就被钉死了。请给出切换的契约或重写产品承诺。

2. **relay 提醒每轮都会触发，你们打算怎么防止刷屏？** changes_requested 超时是持续性条件，`--interval 30` 下 watch 每 30 秒向 writer pane send-keys 一次。v0.4 的 best-effort 免责声明针对的是"消息可能丢"，不是"消息必然重复"。模型 mid-turn 被打断的代价是真实工作流损失。去重/节流字段（last_relay_at）必须进 AC，否则这个功能上线即事故。

3. **auto 模式下 operator 的知情与接管权在哪？** 护栏把"永不自动"的边界划得很清楚（cancel/reject/BLOCKED），但没回答"operator 想人工把关某个 APPROVE 时如何阻止 autopilot 抢先"。30 秒轮询意味着 operator 看到 status 后可能已经来不及。没有 pause/接管机制，"人工优先"就是空话——而这是双模式协同里 operator 信任自动化的前提。

---

## 决策点表态

### A：list 是否加 MODE 列？—— **加，追加在 ANOMALY 之后，同步升级 spec 与测试**

理由（产品视角）：list 是 operator 的批量 dashboard，是无人值守巡检的唯一入口。没有 MODE 列，operator 无法一眼区分"这个 run 处于 approval_pending 且即将被 autopilot 自动放行"与"这个 run 等人审批"——两种状态的操作含义完全不同（前者无需干预、后者需要人）。auto 模式下巡检的第一问题就是"哪些 run 在自动轨道上、哪些卡在需要我的地方"，MODE 列是回答它的最低成本手段。v0.4 row contract 虽是 spec 钉死，但 v0.5 是 minor 版本升级，追加尾部列保持前缀兼容，现有脚本按位置解析旧列不受影响；spec 记一条 deliberate drift（追加列 + 同步 list.sh 与测试）即可，符合 AGENTS.md 的 drift 纪律。

### B：resume 自动重试默认值？—— **默认 0（只报警），并显式标注实验性**

理由（产品视角）：trust prompt 需人工是 v0.4 冒烟**实测**事实，不是理论风险。默认 1 意味着无人值守下 pane 会被自动拉起、然后卡在 trust prompt——制造"看似在恢复、实际仍等人"的半自动假象，比干脆报警更糟（operator 收到报警会去看，半自动状态可能没人看）。默认 0 让行为可预测：blocked=报警，语义干净。待"gate trust 免人工预授权"落地（R1-5 的 roadmap 项）后，再考虑把默认提到 1。若团队坚持默认 1，至少要求 autopilot 在 resume 后检测 trust prompt 未确认时立即把 run 置回报警态并退出码 2——但这是额外复杂度，不划算。

---

## 一句话总结

方向成立——状态机不动、autopilot 外置、opt-in 默认 human 是正确架构；最大风险是 mode 的**运行期语义缺失**（无切换、无接管、无提醒节流），目前 auto/human 只是 start 时的一次性快照，而真实双模式工作流要求运行时互斥与人工优先，这必须在 spec 层补契约而不是留到实现期。
