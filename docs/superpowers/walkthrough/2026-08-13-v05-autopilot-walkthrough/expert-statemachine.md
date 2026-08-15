# v0.5 走查专家评审：statemachine（状态机 / 一致性 / 并发）

> 角色：状态机、一致性、并发专家。评审对象：`input-design.md` 的 v0.5 草案（human/auto 双模式 + autopilot 外部编排层）。
> 依据：v0.4 spec（`docs/superpowers/specs/2026-08-13-run-state-authority.md`）、`lib/lock.sh` 实现、`AGENTS.md`。
> 总体判断：**"状态机不动、autopilot 在外部执行"是正确架构**——T10 的 guard（RP=human + PH=decided + RC=approval_pending + V=APPROVE）天然挡住竞态重放，autopilot 作为 `resolve` 的普通调用方不新增任何转移权限。但草案在退出码契约、锁复用、心跳/崩溃恢复、resume 半开语义上有 4 个必须先钉死的缺口。

---

## R1：用户故事 / 验收标准

### 发现 R1-1【主要】"无人值守推进到完成"承诺过度，AC 层面应收敛为可验证契约

- **发现**：草案目标写"任务完全无人参与地推进到完成"，但动作矩阵里真正自动的状态转移只有一行（approval_pending → resolve approve）。changes_requested / human_changes_requested 的推进依赖 best-effort relay 唤醒 writer；blocked 两个 RC 都永不自动。因此 auto 模式在状态机层面只保证"APPROVE+PASS 路径无人值守完成"，其余路径的终态是"报警（exit 2）+ 等待"。
- **证据**：draft §2.2 动作矩阵仅一行自动动作；v0.4 事实"relay：双向 tmux 消息，best-effort（README 明示 'tmux cannot know whether an interactive model is mid-turn'）"；draft §3 自列风险"提醒可能丢失，writer 无人响应时任务仍会停住"。
- **建议**：把 AC1–AC7 的措辞从"自动推进"改为可验证的两段式契约：**(a) auto 模式保证 APPROVE+PASS 路径无人值守到达 completed；(b) 其余任何非终态，autopilot 必须在当轮以明确退出码报警（stop-and-alarm），不允许静默挂起**。这同时回答了 §3 的"承诺是否过度"：承诺不成立的是"推进"，成立的是"不静默"。把 (b) 写成测试：模拟 changes_requested 超时 + relay 不可达，断言 autopilot --once 返回人工介入码。

### 发现 R1-2【次要】动作矩阵非穷尽，缺显式"只观测"行

- **发现**：矩阵只列了 approval_pending / changes_requested / reviewer_unreachable / block_resolution_required / completed / canceled / corrupt 几类。`active/intake`、`active/submitted/review_pending`、`active/validated/decision_pending`（reviewer 正在工作）、以及 `active/decided/writer/human_changes_requested`（reject 后）没有对应行；且"changes_requested"是否覆盖 v0.4 的两个 RC（changes_requested 与 human_changes_requested）未说明。
- **证据**：v0.4 T 矩阵存在两个 writer 侧 RC；draft §2.2 只写了一个。
- **建议**：补全为穷尽矩阵（14 个状态 × 2 模式），并为未列出的状态声明 **default = 只观测、零副作用**；relay 行显式覆盖两个 RC。这直接服务 AC3"human 模式只观测不动作"——"不动作"需要能被测试枚举。

### 发现 R1-3【次要】AC2"幂等"语义不清：幂等只存在于扫描层，动作层是"失败重放"而非零写

- **发现**：`resolve --action approve` 在已完成 run 上重放是非法转移（exit 2），不是 v0.4 意义上的零写幂等（T3 同 SHA retry、重复 escalate 才是）。若 autopilot 把动作的 exit 2 一律记为 error，则任何"扫描读到旧态后恰逢他人先完成"的良性竞态都会污染 error 计数与 --once 聚合码。
- **证据**：v0.4 T10 无零写重试路径（Retry 列为 —）；v0.4 exit 2 = illegal transition；draft AC2 写"actor 审计、幂等"。
- **建议**：把"幂等"定义为**状态层去重（read-then-act，重复扫描自动跳过）+ guard 兜底（陈旧动作被 T10 拒绝）**；动作结果的分类必须区分：exit 0=已动作、exit 2/3/5=良性竞态（state moved/stale/residue，下一轮重扫）、exit 2 且 status 诊断为 corrupt=真实错误。分类规则写进 AC 与动作日志 result 枚举。

### 发现 R1-4【信息】威胁模型：auto 不新增权限，但 opt-in 是社会护栏而非技术护栏

- **发现**：同 UID 下任何进程本就可手工执行 `resolve --action approve`（v0.4 F5 基线），autopilot 只是把同样的命令自动化；auto 模式不扩大权限面，但移除了"人工显式输入命令"的摩擦，且 `approval_mode` 配置本身可被同 UID 进程改写——护栏完全落在"opt-in 配置 + prompt 约束"上。
- **证据**：draft §2.4 护栏 1（opt-in）；v0.4 spec 威胁模型（writer 同 UID 可伪造，靠 prompt 约束）。
- **建议**：接受该基线（与 v0.4 一致），但把两条写进文档：(1) 每个自动动作的 reason 必须带实例标识（见 R3-2），保证审计可追溯到 autopilot.tsv 心跳行；(2) init 生成 project.conf 时 approval_mode 行必须带醒目注释并默认 human（草案已提，升为 AC 断言：解析缺省/非法值一律 human，fail closed）。

---

## R2：技术追踪 / 契约状态

### 发现 R2-1【严重】`autopilot --once` 退出码 2 与 v0.4 exit-code 协议语义冲突

- **发现**：draft §2.3 定义 --once 退出码"2=发现需人工介入（blocked 等），供 cron 报警"，但 v0.4 协议已钉死 **exit 2 = illegal transition / corrupted state file / legacy evidence conflict / invalid enum**。同一个码在 autopilot 语境下表示"需人工"，在其余命令语境下表示"非法转移/损坏"——cron 报警与状态诊断不可区分，操作者看到 exit 2 无法判断是"该去处理 blocked"还是"autopilot 自己撞上了冲突"。
- **证据**：v0.4 spec "Output and exit-code protocol" 表 exit 2 定义；draft §2.3 原文。
- **建议**：给"需人工介入"分配新码（如 6，避开 0/1/2/3/4/5/10 全部已用码），或复用 list 的聚合语义（5>4>2>0 优先级，最高级胜出）并显式写协议表；同时定义 lock-busy（4）在 --once 下是"deferred"而非报警（见 R2-4）。新增码必须同步进 spec 的 exit-code 协议表与 §50–53 测试，保证全仓唯一解释。

### 发现 R2-2【严重】AC6"autopilot 自身锁（复用 lib/lock.sh）防多实例并发"在当前实现下不成立：dead-PID 回收存在互斥破坏竞态

- **发现**：`arena_lock_acquire` 在"锁被 dead PID 持有"分支执行 `rm -rf <lock>` 后直接 `mkdir`。两个并发回收者（如 watch 与 cron --once 同时发现同一个死锁）都可能经历"检查死 PID → rm -rf → mkdir 成功"，各自写入自己的 owner——A 的锁目录可能被 B 的 rm 连带删掉，随后 A/B 同时进入临界区，互斥被破坏；A 稍后 release 时还会因 token 不匹配 `arena_die`，把一次成功的转移包装成失败。v0.5 引入"常驻 watch + cron --once + 人工命令"三方竞争后，该窗口被显著放大，且 AC6 声称的"单实例"保证不成立。
- **证据**：`lib/lock.sh` 代码（dead-PID 分支 `rm -rf "$lock_path"; mkdir "$lock_path" 2>/dev/null || arena_die ...`；release 要求 token 匹配）。v0.4 50 节测试不覆盖"两个回收者同时回收同一死锁"。
- **建议**：在 v0.5 落地前修复回收协议为原子化：**rename-to-tombstone**（读到 dead PID 后 `mv <lock> <lock>.reap.<token>`——rename 原子，只有一方成功；失败方重新 mkdir 竞争），再 mkdir 重建；或至少把"rm 后 mkdir 失败"改为 exit 4 重试而非继续。为 autopilot 锁新增专门 fixture：双实例并发回收同一死锁，断言恰好一个实例获得锁。

### 发现 R2-3【主要】PID 复用使 dead-PID 判定失效；心跳必须并入锁活性协议，且 autopilot.tsv 权威性必须钉死

- **发现**：(1) 锁活性只判 `kill -0 $pid`；常驻 watch 崩溃后其 PID 若被系统回收给无关进程，锁将永久"活"，cron --once 永久 exit 4，直到人工删除——无人值守场景恰恰无人来删。(2) draft §2.3 的心跳 autopilot.tsv（last_scan_at/scanned/acted/errors）既无 staleness 判定、也无多实例归属（watch+cron 双跑时单行心跳互相覆盖，无法回答"谁在扫"），而 v0.4 spec 已明确 heartbeat 是"future, separate observation file"。
- **证据**：`lib/lock.sh` `arena_lock_owner_alive` 仅 `kill -0`；draft §2.3 心跳字段为单行汇总；v0.4 spec out-of-scope 段落。
- **建议**：三件事一起做：(a) autopilot 锁目录内由持有者在**每次扫描完成时刷新 owner 内的 `last_seen_at`**，竞争者活性判定改为 `pid alive AND last_seen 新鲜（< 3×interval）`，任一不满足即可按回收协议接管——把心跳从"观测文件"升级为"锁活性协议的组成部分"；(b) autopilot.tsv 改为**每实例一行**（instance token = host:pid:nonce + 该实例 last_scan_at/acted/errors），watch 与 cron 各自成行，staleness 按行判定；(c) 文档钉死：autopilot.tsv 与 autopilot.log 都是观测文件、**永不参与状态机判定、永不被任何状态转移读取**，权威仍只有 run-state.tsv + SHA 绑定证据。

### 发现 R2-4【主要】扫描循环对 status exit 4（live lock）无定义处理，会把正常转移误计为错误

- **发现**：autopilot 每轮扫描 run 时若恰逢转移进行中，`status` 返回 exit 4（transition in progress）。draft 的矩阵只有"corrupt/conflict/incomplete → 记录错误，聚合退出码"，未定义 4。若按"记录错误"处理，每次 submit/validate/decision 都会向 error 计数与动作日志注入噪音，甚至让 --once 聚合码误报。
- **证据**：v0.4 协议"status 看到 live lock 打印 transition in progress 并退出 4"；draft §2.2 矩阵行。
- **建议**：扫描/动作两处都定义 **exit 4 = defer（本 run 本轮跳过，下轮重扫；不计数、不报警）**；动作侧 resolve 遇 4 同样 defer。聚合码只反映 2/3/5 的真实问题。

### 发现 R2-5【次要】mode 未纳入 T1r creation intent 的 derived-input 绑定，中断 start 可被不同 mode 静默重试

- **发现**：草案只在 start 时把 mode 写入 manifest，但 v0.4 的 creation intent 绑定"派生创建输入"（base SHA、writer branch、adapter 路径、worktree 路径）用于阻止参数漂移的失败重试；mode 作为 config 派生输入若不入 intent，中断的 start 在 approval_mode 已变更后重试会静默通过，产出一个与操作者当前意图不符的 run（manifest 记录旧 intent 之外的模式）。
- **证据**：v0.4 spec T1 意图绑定清单（无 mode）；draft §2.1 "start 时写入 manifest 的 mode 字段"。
- **建议**：mode 加入 intent 绑定集合，重试参数与 intent 不一致时 fail closed（exit 2，与现有规则同路径）；并在 AC1 测试中加一条"interrupted start + mode 变更重试被拒"。

### 发现 R2-6【信息】mode 的 run 级不可变语义应显式声明

- **发现**：manifest mode 是 run 级快照，autopilot 每轮"读 mode"应读 manifest 而非 project.conf，否则运行中途改配置会造成扫描视角漂移。
- **证据**：draft §2.1（manifest 字段、旧 manifest=human）与 §2.2（每轮扫描读 mode）。
- **建议**：写明"mode 在 run 创建时固化，配置变更只影响新 run"；status 的 Mode 行读 manifest，与 autopilot 读取源一致。这与 v0.4"run-state 单一事实源"精神一致，也避免审计歧义。

---

## R3：集成 / 错误与边界

### 发现 R3-1【主要】auto-resume 是"spawn-and-stall"陷阱：trust prompt 使动作必然停在半开，且可能反复产生纯副作用

- **发现**：v0.4 实测事实是真实环境 respawn 后弹 trust prompt、需人工确认。因此 autopilot 的自动 resume 不会产生任何状态转移，只会制造一个停在 trust prompt 的半开 pane；而 recover 的 reachability 判定（role=reviewer、mode=reviewer-agent、not dead、input on）很可能把"停在确认提示的 pane"判为可达——于是后续流程（若有人工 recover）会面对一个并非就绪的 reviewer pane，且 --resume-attempts 的每次尝试都是带 run lock 的副作用（resume 在锁内 respawn，见 v0.4 路径追踪）。
- **证据**：draft §1 "真实环境会弹 trust prompt，需人工确认（v0.4 冒烟实测）"；draft §2.2 动作矩阵 reviewer_unreachable 行；v0.4 spec "resume respawn INSIDE the lock" + recover reachability 判据。
- **建议**：(a) 维持默认 0（见决策点 B）；(b) 启用时，把 --resume-attempts 语义定义为"spawn 次数上限"并在 autopilot 自有观测中记录 per-run 已 spawn 次数与结果=unconfirmed，防止每轮重复 spawn；(c) 动作日志中 unconfirmed 结果必须触发当轮人工介入码（resume 不等于解除 blocked）；(d) 在 reachability 判据或 recover 前置说明中显式处理"pane 存在但停在 trust prompt"这一中间态（至少 status 诊断要能区分，测试里用 fake 状态模拟）。

### 发现 R3-2【主要】动作日志与审计链的权威边界必须写明：日志可丢，审计不丢

- **发现**：autopilot 崩溃可能发生在 resolve 成功提交之后、动作日志追加之前——日志缺一条，但 run-state 已记录 last_transition_actor=autopilot 且 reason 应含实例标识。若不写明边界，审计者可能误以为日志缺失 = 未发生动作。
- **证据**：draft §2.3 "动作日志 append-only TSV：timestamp run_id action result"；v0.4 审计原则"SHA 绑定 decision/validation 记录为权威"。
- **建议**：文档与 AC 写明：**autopilot.log / autopilot.tsv 是 best-effort 观测，权威审计链仍是 run-state + decision 归档**；`--reason "autopilot <instance-token> <scan-ts>"` 必须携带实例标识，使日志行 ↔ 心跳行 ↔ run-state 三元可关联。相应地，动作日志的写入顺序（act → log → heartbeat）与崩溃恢复说明补进 §2.3。

### 发现 R3-3【次要】relay 提醒无节流：每轮扫描都会对超时 run 重复发消息

- **发现**：草案没有"上次 relay 时间"记录，且 relay 是 best-effort 消息——常驻 watch 下，一个超时的 changes_requested run 会在每个 interval 收到一次提醒（消息轰炸），而 run-state 的字段（WS 等）不应为此改动。
- **证据**：draft §2.2 relay 行；v0.4 WS 重置规则（AC7：仅 party/reason 变化时重置）。
- **建议**：autopilot 自有观测记录 per-run `last_relayed_at`（放 autopilot.tsv 每实例行或独立 relay 记录），relay-after 内不重复；该记录纯观测、零状态机影响。测试：relay 可送达（fake pane）时断言每个 interval 至多一次提醒。

### 发现 R3-4【次要】超时与心跳依赖墙上时钟，需显式声明时钟跳变的操作风险

- **发现**：relay-after 超时（now − WS）、心跳 staleness、锁 grace（60s）全部基于 `date +%s`；系统时钟回拨会同时造成超时误判与心跳"未来时间戳"。v0.4 已有 WS <= last_transition_at 不变量约束写入侧，但读取侧（autopilot 的超时判定）无保护。
- **证据**：draft §2.2 --relay-after；v0.4 lock grace 规则与 WS<=LTA 不变量。
- **建议**：在设计中写明超时/新鲜度判定容忍时钟抖动（如 staleness 判定用区间而非瞬间值），并把"时钟跳变导致误报警"列为已接受操作风险；本地单机工具可接受，但不要假装不存在。

### 发现 R3-5【次要】autopilot 扫描应走 `status` oracle 而非直接解析 run-state.tsv

- **发现**：草案未说明扫描如何读取 run 状态。若 autopilot 直接读 run-state.tsv，等于重复实现 corruption 判定、legacy 投影、live-lock 感知、S1–S6 意图阶段分类，且容易与权威读路径漂移。
- **证据**：v0.4 spec：status 是零写 oracle，legacy 走只读投影；interrupted start 永不投影为 legacy。
- **建议**：每 run 用 `status`（含退出码协议 0/2/4/5）作为唯一读入口，意图阶段（S1–S6）与 legacy run 一律跳过；corrupt（exit 2）与 incomplete（exit 5）按矩阵记录。这也让 R2-4 的 defer 语义自然落地（status exit 4 → defer）。

---

## 三个最尖锐的质疑

1. **"幂等"到底指什么？** 草案 AC2 声称 auto approve 幂等，但 T10 在 completed 上重放是 exit 2 非法转移，不是零写。autopilot 如何区分"良性竞态（他人先完成）"与"真实冲突（corrupt）"？若不能，--once 的错误聚合与动作日志会被陈旧动作噪音淹没——请给出动作结果的四分类（acted / deferred / benign-race / error）并写进 AC。

2. **AC6 的单实例保证在现实现下是否成立？** `lib/lock.sh` 的 dead-PID 回收是 `rm -rf` + `mkdir` 两步，两个并发回收者可以都成功，互斥被破坏；PID 复用又可能让死锁永久"活"。autopilot 把锁的使用者从"人工短命令"变成"常驻 watch + cron --once 并发"，这个 v0.4 未覆盖的竞态窗口正是 v0.5 最该修的。为什么不在 v0.5 里顺手把回收协议改成原子 rename-to-tombstone，并给 autopilot 锁加专门的双实例回收测试？

3. **auto-resume 是不是一个"看起来自动、实际永远停在半开"的伪动作？** trust prompt 需人工确认是 v0.4 实测事实，所以自动 resume 不产生状态转移、只产生副作用；而 reachability 判据很可能把停在确认提示的 pane 判为可达，让后续人工 recover 面对一个并不就绪的 reviewer。既然如此，默认值之外是否应该干脆把"自动 resume"从动作矩阵中移除，改为"报警 + 精确的两步指引"，直到存在可判定 trust prompt 状态的机制？

---

## 决策点表态

### A：list 是否加 MODE 列 —— **不加（保持 v0.4 row contract 不变）**

理由：v0.4 spec 将 list 的 11 列 row contract 钉死为 oracle 权威契约，v0.5 的核心原则是"状态机不动、命令语义不动"；为展示一个 per-run 配置字段去改动权威契约，性价比最低。mode 的可观测性已由 `status` 的 Mode 行覆盖（草案 §2.1），而 list 是给脚本消费的聚合视图——契约变更会让所有下游解析器与 composite-key 排序承担无谓风险。若未来确需扩展，必须走显式升级路径：**追加列只能放末尾、不影响 composite-key 排序、同步 bump row contract 版本并更新 spec+全部测试**，且要有一个独立的迁移提交，而不是夹在 autopilot 功能里。

### B：resume 自动重试默认值 —— **默认 0（只报警）**

理由：trust prompt 人工确认是 v0.4 冒烟实测事实，自动 resume 在真实环境必然停在半开、不产生状态转移，默认 1 只会引入一次确定的副作用与一次必然的后续报警；这与草案自己的护栏家族（cancel/reject 永不自动、无 --force/--yolo、auto 必须 opt-in）一脉相承：**auto 模式默认不执行任何无状态转移的副作用动作**。想要自动化的用户可显式 `--resume-attempts N`，且每次 spawn 都记录为 unconfirmed 并触发人工介入码（R3-1）。

---

## 一句话总结

**方向成立**——外部编排层 + 状态机零改动是正确架构，T10 guard 已保证并发安全；**最大风险是"无人值守"承诺超出状态机实际保证（仅 APPROVE+PASS 路径），以及 autopilot 复用未修复回收竞态的锁 + 退出码 2 语义冲突**，前者让用户误信、后者让报警失真，两者都必须在 AC 与测试中先钉死再谈 0.5.0。
