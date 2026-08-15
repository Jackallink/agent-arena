# v0.5 autopilot 设计走查 — 安全与审批合规专家评审

> 角色：security（威胁模型、auto approve 滥用面、审计链完整性、权限边界）
> 依据：input-design.md（v0.4 现状事实 + v0.5 设计草案 + 决策点 A/B）、v0.4 spec（run-state wire contract / T 矩阵 / resolve 语义）、`lib/resolve.sh`、`lib/state.sh`、`lib/config.sh`、`lib/lock.sh`、v0.2 走查 F5 威胁模型。
> 基线认知：v0.4 的审计链中，`resolve --action approve` 是**唯一一个非 AI、非脚本的人类环节**——它是 F5 威胁模型（writer 同 UID 可伪造，靠 prompt 约束）之下最后一个能力意义上的控制点。v0.5 的所有安全判断都围绕"移除这个环节后，用什么补偿"。

---

## R1 用户故事与 AC 焦点：谁被授权做什么

### S1 【严重】auto 模式移除审计链中唯一非 AI 审批环节，且设计未提供任何等价补偿控制

- **发现**：v0.5 的 auto 模式把"必须由人执行 `resolve --action approve`"（v0.4 AC6 的核心语义）替换为"autopilot 循环自动执行"。这没有新增任何能力防御，只是把 F5 的滥用面从**需要显式、可见、有人在场地执行一条命令**升级为**常驻后台、无人在场、默认持续地自动批准**。设计 §2.4 的安全护栏（opt-in、guard 保证、永不自动 cancel、无 --force）全部是"不新增坏行为"的约束，没有一条是"补偿被移除的人类审批"的约束。
- **证据**：(1) v0.2 走查 F5：writer 与 Cursor 同 UID，`decision`/`validate` 不校验调用者身份，"正式门依赖 writer 遵守 prompt，无法在本地同 UID 下用能力强制"——该威胁模型在 v0.4 靠"resolve 是人来执行"这一流程事实兜底；(2) 同 UID 下，writer 进程自己就能跑 `agent-arena autopilot --once`，或把 `project.conf` 改为 auto 后等 operator 的 watch 扫到——不需要伪造任何东西；(3) 设计 §2.4 的护栏清单与 v0.4 状态机 guard 完全重合（approve 的 guard 在 T10 本就存在），无增量防御。
- **建议**：把"移除人类审批"当作一次**信任模型降级**显式记录进 spec 威胁模型，并至少补齐三件补偿：(a) **run 级显式 opt-in**——`start --mode auto`（或 init 时 operator TTY 确认），而不是仅 repo 级 `project.conf` 一个键（一个键可以被静默 uncomment）；(b) **冷却窗口**（见 M2）；(c) **审计展示层可区分**（见决策点 A）。同时文档化："auto 模式只适合 validation 脚本严格、风险低的 repo"，并把该声明写进 `init` 生成配置的注释。

### M1 【主要】mode 快照与 config 漂移无检测，审计者无法发现"批准依据"中途被改

- **发现**：设计在 start 时把 mode 快照进 run manifest（正确），但没有任何机制检测/展示"manifest mode ≠ 当前 project.conf mode"的漂移。operator 事后把 `project.conf` 改回 human（或攻击者把 auto 改回 human 以洗白）不会影响已开始的 run，审计者从 status/list 无法感知。反过来，`approval_mode` 键被静默加入 `project.conf` 也没有告警。
- **证据**：设计 §2.1 仅描述"start 时写入 manifest 的 mode 字段 + status 输出 Mode 行"，无漂移比较；v0.4 的 status/list 已有 anomaly 显示机制（ANOMALY 列）可复用。
- **建议**：status/list 对 mode 漂移显式告警（如 `Mode: auto (config: human) ⚠`），并新增 AC："run 的生效 mode 以 manifest 快照为准；config 与快照不一致时必须显示漂移标记"。这也顺带解决"auto 模式批准依据可追溯"问题。

### M2 【主要】auto approve 无冷却/观望窗口，且不复核 checkpoint 新鲜度

- **发现**：watch 默认 `--interval 30`，decision APPROVE 落地后 30 秒内即被自动批准。operator 与任何监控都没有介入窗口；同时 auto approve 只依赖状态机字段（verdict=APPROVE ∧ validation=PASS），不复核"writer HEAD 是否仍是 review SHA"（v0.4 T10 亦然，但 v0.4 有人类在最后一步把关）。
- **证据**：动作矩阵 approval_pending → 自动 resolve；`lib/resolve.sh` 的 approve guard 只查 `PH=decided ∧ RC=approval_pending ∧ V=APPROVE`；设计未定义 decision→approve 的最小间隔。
- **建议**：增加 `--approve-delay`（默认 ≥ 决策后 N 分钟，如 5–10），把 decision→approve 时延记入 autopilot.log；在 spec 中明确"auto approve 绑定 state 中的 checkpoint_sha + validation_digest"（state 已存这两字段，批准记录应引用它们）。

### I1 【信息】AC 草案缺少安全/合规相关验收标准

- **发现**：AC1–AC7 全部是"功能正确性"AC，没有一条覆盖：mode 中途修改、模式漂移显示、autopilot 动作与 state actor 一致性、watch 扫描范围白名单、autopilot 心跳 liveness。而 input-design §3 自列的已知风险里至少三条是安全性的。
- **证据**：设计 §2.5 AC 清单逐条核对。
- **建议**：补充 AC8–AC11（mode 漂移检测、actor 契约一致性断言、repo 白名单、心跳 liveness 阈值），每条映射 hermetic 测试。

---

## R2 技术追踪与契约焦点：状态、权限边界、审计链

### S2 【严重】"actor=autopilot"与 v0.4 wire contract 直接冲突——按现设计实现会要么写坏状态、要么在权威记录里把批准伪记成"human"

- **发现**：设计 §2 声称"autopilot 执行 `resolve --action approve`，actor=autopilot"。但 (1) `run-state.tsv` 的 `last_transition_actor` 枚举被 spec 钉死为 `writer|reviewer|human|system`，非法值按**损坏状态 fail-closed**（`lib/state.sh`：`case ... in writer|reviewer|human|system) ;; *) arena_state_die 'corrupted state file: invalid last_transition_actor'`）；(2) 当前 `lib/resolve.sh` **硬编码** `ARENA_STATE_LAST_TRANSITION_ACTOR='human'`，且 approve 分支清空 `reason_detail`——即使传 `--reason "autopilot ..."`，该标记也不会进入权威状态文件。也就是说：按现状实现，autopilot 的批准会在权威审计记录里被记成 **human**（审计撒谎）；按设计字面实现，会写坏状态（fail-closed 安全但功能全断）。无论哪条路，AC7"v0.4 50 节零改动"的承诺都与此矛盾。
- **证据**：`lib/resolve.sh`（actor 硬编码 + approve 清空 reason_detail）；`lib/state.sh`（actor 枚举校验）；v0.4 spec wire contract 的 `last_transition_actor` 表。
- **建议**：显式二选一并写进 spec：**方案 a（推荐）**：autopilot 复用 resolve 路径，actor 记 `system`、action 记 `resolve-approve`，批准归属靠 autopilot.log 佐证（零契约变更）；**方案 b**：正式扩展枚举加 `autopilot`，同步改 spec wire contract + 新增测试（此时 AC7 必须改为"v0.4 50 节中 X 节随契约升级同步更新"）。无论哪种，都必须有 hermetic 测试断言批准后 state 的 actor/action 值，防止审计撒谎回归。

### M3 【主要】watch 扫描范围未定义：全局扫描 = 恶意 repo 可被自动批准走完全程

- **发现**：设计动作矩阵"每轮扫描**每个 run**（读 mode）"，未限定扫描的 repo 集合。若 watch 扫 state root 下所有 run，则任何同 UID 进程（包括被攻破的 repo 的 project.conf、或 writer 自己 init+start 的恶意 repo）只要设 `approval_mode=auto`，就会被 operator 的常驻 watch **无人干预地批准完成**。v0.4 中即使同 UID 伪造，最后一步仍需人执行 resolve；v0.5 全局 watch 把这个"最后一步"也自动化了。
- **证据**：设计 §2.2"每轮扫描每个 run（读 mode）"；state root 默认 `~/.local/state/agent-arena`，同 UID 可写（v0.2 F5）；`lib/config.sh` 严格解析但只约束格式不约束信任。
- **建议**：watch/`--once` 必须显式 `--repo` 白名单（`--all` 才扫全部，且 `--all` 场景在日志里显式记录扫描范围）；心跳记录本次扫描的 repo 集合；新增 AC"扫描范围白名单生效"。

### M4 【主要】autopilot 锁粒度含糊，watch+cron 双跑时心跳会双写、审计对账会乱

- **发现**：设计说"autopilot 自身有锁（复用 lib/lock.sh，防多实例并发）"，但没说锁的粒度。per-run 锁只能串行化单个 run 的动作，挡不住两个 autopilot 实例同时扫不同 run；而心跳文件 `autopilot.tsv` 是单行汇总（last_scan_at/scanned/acted/errors），双实例并发写会撕裂/覆盖。已知风险 §3 已问"锁是否足够"，但设计未答。
- **证据**：`lib/lock.sh` 是 per-path 锁（mkdir + owner 元数据 + dead-PID 恢复），可作全局锁（state root 级路径）；设计 §2.3 心跳为汇总字段。
- **建议**：**全局单实例锁**（state root 下 `autopilot.lock`），心跳在锁内原子写（mktemp+mv）；`--once` 遇持锁时退出码区分"忙"（另一实例在跑）与"错误"，避免 cron 误报警。

### M5 【主要】autopilot.log 无完整性绑定，批准动作的"归属证明"全部落在可伪造的 TSV 上

- **发现**：v0.4 的权威是 **SHA 绑定**的 decision/validation 记录；而 autopilot 的批准动作只记录在 append-only TSV（`autopilot.log`）+ state 的 `last_transition_at/actor/action`，两者同 UID 下都可改（log 可 truncate/伪造，state 是 revision 计数链而非哈希链）。"这次批准是 autopilot 干的、批准时 validation 确实是 PASS、批准的是哪个 SHA"在权威链上没有可验证的证据。
- **证据**：设计 §2.3（append-only TSV）；v0.4 spec（SHA 绑定 decision/validation 为权威）；`lib/state.sh` 无批准记录哈希字段。
- **建议**：autopilot 批准采用**两步审计对**：先写 intent 记录（timestamp/run_id/state_revision 基线/checkpoint_sha/validation_digest），再执行 resolve，后写 result 记录（新 state_revision）。审计工具可交叉核对 intent/result 与 run-state；并在文档中明确"log 是佐证，state + SHA 决策记录是权威"。未来（v0.6 的 journal 迭代）再把批准记录纳入哈希链。

### I2 【信息】心跳文件是观测快照，不能承担"存活证明"，且可被伪造

- **发现**：`autopilot.tsv` 若只存 last_scan_at，崩溃后残留陈旧时间戳，监控无法区分"进程活着但没扫"与"进程死了"；同 UID 进程可把时间戳刷成 now 假装存活。
- **证据**：设计 §2.3（心跳字段清单）；v0.4 spec 已明示"heartbeat 是 future separate observation file，不是 state-field"。
- **建议**：心跳含 pid + 启动时间 + interval，监控按 `>3×interval` 判死；`status`/`list` 可显示 autopilot 健康（信息级增强，不阻塞）。

---

## R3 集成与错误焦点：无人值守的失败路径与报警通道

### M6 【主要】自动 resume 制造"假活"pane：trust prompt 无法自动确认，reachability 检查会被误导

- **发现**：v0.4 冒烟实测：respawn 后 gate **必弹 trust prompt，需人工确认**；spec 明文"Arena cannot verify its confirmation, so recover's reachability check remains the pane-liveness test"。autopilot 一旦开了 `--resume-attempts`，respawn 后 pane 是 live 的但模型从未认证——后续 recover/relay/决策会把这个"假活" pane 当可达 reviewer 使用。自动 resume 是比 resolve 更重的会话级副作用（spawn 一个持有 repo 写权限的 gate CLI 会话），且无人值守时无人确认 trust prompt。
- **证据**：v0.4 spec T12 与 resume 语义（"trust prompt after a respawn is a HUMAN prompt"）；设计 §2.2 动作矩阵（`--resume-attempts` 默认 0=关）。
- **建议**：即使未来放开 resume-attempts，也必须先实现"trust prompt 未确认检测"（pane 内容/进程状态探测）并在确认前**不得**将 pane 视为可达；未实现前维持默认 0（见决策点 B）。每个 resume 尝试都必须写日志（attempt N of N，失败原因）。

### M7 【主要】常驻 watch 的"报警"没有通道：发现需人工介入时可能静默卡死

- **发现**：`--once` 的退出码 2 是 cron 报警通道；但默认的常驻 `--watch` 发现 blocked/需人工介入时只写心跳 errors 汇总——无人值守场景下"报警"报给谁？supervisor 无从得知。已知风险 §3 已点"relay best-effort 可能丢失"，watch 模式的报警缺失使"无人值守"在失败路径上变成"无人知晓"。
- **证据**：设计 §2.3（--once 退出码语义）；§2.2（watch 常驻循环，无通知机制描述）。
- **建议**：watch 支持 `--exit-on-action-needed`（发现需人工介入即以非零码退出，供 launchd/systemd 拉起报警）或可选的外部通知回调（命令钩子）；两者都要 AC + 测试。

### M8 【次要】--once 退出码 0/2 过粗：corrupt/conflict 与 blocked 混在同一语义下

- **发现**：corrupt/conflict（系统/数据异常）与 blocked（业务等待人工）都是"非正常"，但前者应触发运维告警、后者是预期的人工交接。合并为 2 会造成 cron 报警风暴（blocked 是常态）或掩盖 corrupt（被 blocked 淹没）。
- **证据**：设计 §2.3 退出码表；v0.4 已有 0/1/2/3/4/5/10 的分级习惯。
- **建议**：复用 v0.4 分级语义：2=需人工介入（blocked），3=系统/数据异常（corrupt/conflict），0=正常；或至少让输出可 grep 分类。

### I3 【信息】`--resume-attempts N` 的 N 语义未定义

- **发现**：重试间隔、N 次后的回退策略（报警？停住？）、每次尝试的日志要求均未定义；作为唯一"会 spawn 会话"的自动动作，参数契约含糊。
- **建议**：定义 interval 语义（与 --interval 的关系）、N 次后回退为报警、每次尝试落日志；在 B 决策未定的情况下先写进 spec 待定节。

---

## 发现汇总

| 级别 | 数量 | 编号 |
|---|---|---|
| 严重 | 2 | S1（移除唯一非 AI 审批环节无补偿）、S2（actor=autopilot 与 wire contract 冲突/审计撒谎） |
| 主要 | 7 | M1（mode 漂移无检测）、M2（无冷却窗口）、M3（watch 扫描范围未定义）、M4（锁粒度/心跳双写）、M5（log 无完整性绑定）、M6（自动 resume 假活）、M7（watch 报警无通道） |
| 次要 | 1 | M8（--once 退出码过粗） |
| 信息 | 3 | I1（AC 缺安全项）、I2（心跳 liveness/伪造）、I3（resume-attempts 语义） |

---

## 三个尖锐质疑

1. **如果同 UID 的 writer 自己就能跑 autopilot，auto 模式相对 v0.4 新增了哪一条防御？** 设计 §2.4 的护栏全是"不新增坏行为"，而 v0.4 的 F5 靠"最后一步必须人执行"兜底。既然这个兜底在 auto 模式被移除，要么把"auto 授权"做成更强的承诺（start 时 operator TTY 确认 + run 级 `--mode auto` 显式参数，而不是 project.conf 一个可静默 uncomment 的键），要么明确接受 F5 并把全部筹码押在"审计可区分性"上——设计必须选一个，不能两个都含糊。

2. **"无人值守推进到完成"的"完成"边界是什么？** v0.4 明文 terminal actions 只改 Arena 状态：不 merge、不 push、不清理 worktree。那么 autopilot approve 之后，产物还在 review worktree 里，收尾仍要人——"完全无人参与地推进到完成"是否名不副实？而如果 v0.6 要给 autopilot git 写权限以真正闭环，那将是另一个数量级的安全问题（无人类监督的自动 merge/push）。v0.5 至少应在 spec 中把"autopilot 永不触碰 Git"写成硬边界。

3. **三无链的责任归属：AI 决策 + 脚本验证 + 循环批准，全链无人类时，坏结果谁负责？** 当 validation 脚本过宽或 reviewer 被误导时，auto 链会把坏结果自动变成 completed 且无人在场。是否应要求：auto 模式的 run 必须把"validation 脚本哈希 + mode 快照 + 批准记录"三者绑定（使事后审计至少能证明"当时批准的是什么"），并且 operator 在启用 auto 时显式承担该风险（init/start 输出的风险确认）？

---

## 决策点表态

### A：list 是否加 MODE 列？—— **加（升级 contract，同步改 spec + 测试）**

- **理由**：从审计合规视角，这是**必须**的。list 是审计者第一眼工具；没有 MODE 列，一个 auto 模式自动批准的 completed run 与人工批准的 completed run 在展示层完全不可区分——S1 说"移除人类审批"，如果连展示层都不补偿，审计链在"批准方是谁"这个问题上就是断的。status 加 Mode 行（设计已含）只覆盖单 run 深度审计，list 的 MODE 列覆盖广度巡检，两者都需要。
- **成本**：追加一列 + 同步 row contract 与测试，是确定、可控的正成本，远低于"审计不可区分"的合规风险。顺带建议：MODE 列对 auto run 可显示 `auto`，配合 ANOMALY 列已有的异常语义，未来若加"批准方"信息（human/autopilot）可作为 v0.6 增强，不阻塞本决策。

### B：resume 自动重试默认值？—— **默认 0（只报警），且是硬默认**

- **理由**：三点。(1) trust prompt 无法自动确认是 v0.4 **实测事实**，自动 resume 必然制造"pane live 但模型未认证"的假活状态，并误导 recover 的 reachability 检查（M6）；(2) resume 是会话级副作用（spawn 持 repo 写权限的 gate CLI），权限面大于 resolve 的 state-only 副作用，无人值守自动 spawn 违反最小权限直觉；(3) 默认 1 次"尝试后报警"的收益只是省一次人工点击，而代价是引入一个已知的假活路径。要放开，前置条件是 trust-prompt 检测实现 + 对应 hermetic 测试，v0.5 不应承担。

---

## 一句话总结

**方向成立**——"状态机不动、autopilot 作为外部编排层"是正确边界，护栏清单的方向也对；**最大风险是 auto 模式在零补偿控制的情况下移除了审计链中唯一非 AI 的审批环节**——放行前必须先解决 S2（actor 契约冲突，按现设计会审计撒谎或写坏状态）、M3（watch 扫描范围白名单）、M1/M2（mode 漂移检测与冷却窗口）与决策点 A（审计展示可区分）。
