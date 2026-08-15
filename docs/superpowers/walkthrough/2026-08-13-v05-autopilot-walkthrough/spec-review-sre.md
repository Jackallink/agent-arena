# v0.5 spec Gate 1 评审 — SRE（无人值守运维）

> 角色：sre — 无人值守运维专家（心跳/监控/报警、cron 与常驻双跑、`--watch`/`--once` 部署、长期可靠性）。
> 评审对象：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`（正式 spec，下称"spec"）
> 配套：`docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`（下称"plan"）、
> `00-findings-summary.md`（走查裁定来源）、v0.4 spec + `lib/*.sh` 源码（已逐项核对）。
> 方法：按任务书四个核心问题逐条回答；发现按【严重/主要/次要/信息】分级。
> 源码核对记录见文末附录（state.sh L108-109 枚举、resolve.sh、lock.sh、status.sh、config.sh、start.sh intent、relay.sh、list.sh、tests/run.sh fake tmux）。

## 总体结论

spec 对 00-findings-summary 的裁定**忠实度整体很高**：B1–B7、决策点 A/B、采纳清单 15 项全部落地，无新增未裁定设计，承诺收敛与完成边界措辞准确。但作为"无人值守运维"评审，我必须指出：**B3 裁定只落地了一半**——pane 活性维度进了动作矩阵，而"停滞检测"只存在于 AC8 的一句话里，动作矩阵没有任何停滞行、任何阈值都没有 pin 死，且矩阵"live + observe"行与 AC8"停滞即报警"直接矛盾。这是本 spec 最关键的问题：v0.5 的无人值守承诺 = "每个停滞路径都可观测"，而最常见、最无声的停滞（pane 活着但 10 小时不动）恰恰在矩阵里被定义为"observe"。另有 6 个阻塞级契约缺口（详见 Q4）。

**裁决：GATE-1 CONDITIONAL PASS**（7 项必改，均为小改，方向正确、无需重写）。

---

## Q1 裁定忠实度：逐条核对

### 阻塞级裁定（B1–B7）

| 裁定 | spec 落地 | 核对 |
|---|---|---|
| B1 actor=system + reason 透传 | ✅ resolve 契约节：`--actor human\|system`（默认 human）、approve 保留 `--reason`、action 保持 `resolve-approve` | 已核对 state.sh L108-109 枚举确含 system/resolve-approve；resolve.sh 现硬编码 `LAST_TRANSITION_ACTOR='human'`、approve 分支清空 reason_detail，与 spec 所述 delta 一致 |
| B2 exit 6 新码 | ✅ autopilot 专属协议表 0/4/5/6 + 聚合优先级 6>5>4>0 | 与裁定一致；但与动作矩阵存在内部矛盾（见 G2） |
| B3 pane 活性二维 | ⚠️ **半落地**：pane 维度进了矩阵（reviewer/writer dead 行齐），**停滞维度只在 AC8 有文字、矩阵无行、阈值未 pin**；且矩阵 `submitted+live → observe` 与 AC8"停滞即报警"矛盾 | **G1（必改）** |
| B4 锁回收原子化 | ✅ Task 0 + Lock protocol 节：rename-to-tombstone、last_seen 活性、双实例 fixture | 已核对 lock.sh 现为 rm+mkdir 两步，确有竞态；但 plan 的 fixture 并非真并发（见 G7） |
| B5 mode 切换命令 + 漂移标记 | ✅ v05-AC2、mode 契约节（run lock、终态拒绝、autopilot.log 追加） | 切换命令、审计、漂移 ⚠ 齐 |
| B6 relay 节流 | ✅ v05-AC9：last_relay_at、`--relay-after 30`、`[autopilot]` 前缀、skipped-throttled | 已核对 relay.sh from 枚举 writer\|reviewer\|human 不变，前缀方案成立 |
| B7 完成边界 | ✅ Capability promise + Non-promise table（"completed 是 Arena 状态，不是交付"） | 原文照落，无走样 |

### 决策点与采纳清单

- 决策点 A（list 不加 MODE 列）✅：Out of scope + v0.6 显式 contract 升级项，且 `--once` TSV 摘要含 mode 列。
- 决策点 B（resume 默认 0）✅：v05-AC10，`--resume-attempts N=0`，启用记 unconfirmed 且持续 exit 6。
- 承诺收敛 ✅：capability promise 两段式（APPROVE+PASS 自动完成 + 其余 stop-and-alarm），措辞准确。
- 观测文件非权威 ✅：Observation files 节 + round3 崩溃窗口 + reason 三元关联。
- 扫描走 status oracle ✅（但读取路径与 pane 维度冲突，见 G3）。
- `--repo` 白名单 ✅、`--approve-delay` ✅（默认 300s，security M2）、intent 绑定 ✅（v05-AC3）、AC 命名空间 ✅（v05-ACn）、exit 4=defer ✅、human 模式也可报警（exit 6）✅、run 级 opt-in ⚠️（**`start --mode auto` 被引用但从未被定义**，见 G4）、全量真值表 ⚠️（矩阵 + default=observe 基本覆盖，但缺停滞行）、"50 节零改动→零语义漂移" ✅（v05-AC11）、`--once` stdout TSV ✅、时钟跳变/sleep 容忍 ✅（round3 文档化）。

### 遗漏/走样清单

1. 【严重】**停滞检测 = B3 的另一半，矩阵缺失且阈值未 pin**（G1，详见 Q4）。
2. 【主要】**`start --mode auto` 悬空**：US2 与 trust-model note 都引用它作为 run 级 opt-in 手段（security S1 裁定："`start --mode auto` 或 init TTY 确认"），但 Round 2 契约节没有定义这个 flag——没有语法、没有与 project.conf 的优先级、没有与 intent 绑定（v05-AC3 绑定的是哪个 mode？）的说明（G4）。
3. 【次要】**log 轮转裁定丢失**：Round 3 裁定行明确写"容忍区间 + 文档化 + log 上限轮转"（sre R1-5），spec 只落了前两项，`autopilot.log` append-only 无上限无轮转（S3）。
4. 【次要】心跳"谁消费"问题（原始 sre 主要发现）未进采纳清单，spec 靠锁活性 + 部署矩阵缓解：watch 挂死不再能阻塞 cron `--once`（B4 已闭环），无人值守主路径 = cron `--once`（cron 本身是 supervisor）；但"autopilot.tsv 全部陈旧时谁报警"仍无消费方（S1）。

**无新增未裁定设计**：approve-delay、whitelist、TSV 摘要、mode 行日志等均在采纳清单内；未发现 spec 自行发明契约。

---

## Q2 spec 质量（Gate 1 标准）

### 每条 v05-AC 的可测性

| AC | hermetic 可测？ | 说明 |
|---|---|---|
| AC1 | ✅ | §50：init 模板、严格 parser、manifest 落档、legacy 缺省 human。需补：**plan Task 1 文件清单漏了 lib/init.sh**（§50 测试断言 `approval_mode=human` 由 init 写出，init.sh 不改必红）——plan 级缺口（S9） |
| AC2 | ✅ | §50：mode 切换、锁拒绝（exit 4）、终态拒绝（exit 2）、漂移 ⚠。plan 未列 exit-4/exit-2 的 fixture，建议补 |
| AC3 | ✅ | intent fixture：写 intent（mode=human）→ 改 config → 重试 exit 2。v0.4 `arena_creation_intent_write`/`arena_start_verify_intent` 机制已核实支持 |
| AC4 | ✅ | §51：全链路 APPROVE+PASS→completed，断言 actor/action/reason_detail；approve-delay 用 `--approve-delay 3600` + 改写 `last_transition_at` 即可（勿 sleep） |
| AC5 | ✅ | §52：human 模式零 mutation + exit 6 |
| AC6 | ✅ | §53：双实例 exit 4、last_seen 陈旧回收（改写 owner 文件即可）。**但 plan 的"双实例并发回收 fixture"不是并发测试，对旧代码也会通过（G7）** |
| AC7 | ⚠️ | **测不出来，先要钉死 status 退出码 → autopilot 处置的映射**：status 2/5 同时覆盖 corrupt/conflict/incomplete/repair-intent/S1–S6 意图阶段，spec 未定义 autopilot 如何区分"跳过意图阶段"与"error/incomplete"（G2） |
| AC8 | ⚠️ | **测不出来，先要钉死停滞阈值与 pane 读取路径**：矩阵无停滞行、阈值未 pin；writer pane 活性 status 根本不报告（G1+G3） |
| AC9 | ✅ | §53：fake tmux 记录 send-keys，窗口内第二次扫描断言 skipped-throttled |
| AC10 | ✅ | §52：resume-attempts unconfirmed + 持续 exit 6 |
| AC11 | ✅ | 50 节零语义漂移 + 显式断言更新清单。但 **plan 里"断言更新清单"只有元描述没有具体条目**（Task 1 Step 4 括号 + Task 5 Step 1 的一句话），Task 5 前必须枚举（S12） |

结论：**9/11 可直接写测试（AC1–AC6、AC9–AC11）；AC7/AC8 在 G1/G2/G3 钉死后可测**。无结构性不可测 AC。

### 契约歧义（"实现时必然要再问一次"的开放问题）

1. 【严重】**status 2/5 → autopilot 退出码三处打架**：动作矩阵行"corrupt/conflict/incomplete (status 2/5) → error (exit 6)"；协议表"5 = incomplete/residue encountered"；v05-AC5 又把 incomplete 并入 exit 6；plan Task 3 却说"2→error、5→incomplete"。到底 status-5 产 exit 5 还是 6？cron 报警规则（6=page 人、5=重试）完全依赖这个答案（G2）。
2. 【严重】**意图阶段/legacy 跳过机制未定义**：v05-AC7 说"legacy runs and interrupted-start intent stages are skipped"，但 status 的 exit 2 同时覆盖 corrupt/conflict 与 S3/S4 意图阶段，exit 5 同时覆盖 incomplete 与 S1/S2/S5/S6 意图阶段 + repair intent——不查 creation intent 文件（list.sh 已有先例 `arena_creation_intent_path`）根本无法区分"跳过"与"error/incomplete"（G2）。
3. 【严重】**pane 活性读取路径未定义**：v05-AC7 钉死"status oracle as the only read path"，但 status.sh 只报告 **reviewer** pane 活性（且只在不终态诊断句里），矩阵却需要 **writer** pane 活性（changes_requested + dead → alert）。status 给不了这个信息，spec 也没说 autopilot 直接查 tmux（G3）。
4. 【严重】**pane 维度缺第三态**：status 区分"tmux session: not running"与"reviewer pane: unreachable"，矩阵只有 live/dead 两态。无人值守主路径是 cron `--once`，cron 机器完全可能没有 tmux——此时每轮扫描每个 run 的 pane 都是"not running"，auto 模式会把所有 submitted/validated run 自动 escalate 成报警风暴。spec 必须钉死：pane 观测不可用（无 tmux/无 session）时视为 unknown → observe（G3）。
5. 【主要】**停滞阈值未 pin**：v05-AC8 "waiting longer than per-state defaults"——defaults 是什么？没有表、没有 flag（`--stall-after`？）、没有示例值（findings 里的 review_pending>30min 只是例子）。实现者必须自己发明（G1）。
6. 【主要】**`start --mode auto` 无契约**（G4，见 Q1）。
7. 【主要】**status 漂移检查的新失败模式未定义**：漂移标记需要 status 解析 project.conf（status.sh 现在完全不读 config）。project.conf 缺失/损坏/含非法行时 status 怎么办？严格 parser 会 die（exit 1），而 status 是 autopilot 的唯一读入口——一个无关的 config 损坏会让整轮扫描停摆。必须钉死"best-effort：config 不可读 → 只显示 manifest mode、无 ⚠、status 照常 exit 0"（G6）。
8. 【次要】`--once` stdout TSV "same schema as the action log"：action log 是 6 列（timestamp 开头），括号里写的是 5 列 `run_id mode state action result`——哪个对？per-run 还是 per-action 一行？（S8）
9. 【次要】autopilot.log 的 result 枚举没有 mode 切换行的取值（`mode` action 该记什么 result？）（S8）
10. 【次要】autopilot.tsv/log/throttle 文件路径只在 plan 里出现（`autopilot-throttle.tsv`），spec 未 pin `<state_root>/autopilot.tsv|.log`（S7）。

### 与 v0.4 的一致性（隐性破坏排查，已核对源码）

- **resolve 改动零破坏** ✅：v0.4 T10 测试（tests/run.sh）对 approve 只断言 run_status/phase/party/reason_code/verdict/validation_result/waiting_since/last_transition_action，**不**断言 reason_detail 清空或 actor 默认值；`--actor` 默认 human + 无 `--reason` 时清空 = 现状，v0.4 断言全绿。
- **status 加 Mode: 行** ✅：现有断言均为 require_match 子串匹配，追加一行不破坏；但**行位置未 pin**（建议钉在 Tmux session 行后，S10）。
- **config 严格 parser 加键** ✅：v0.4 无 approval_mode 的 project.conf 必须继续解析（缺省 human，AC1 已说），正则从两键扩三键，其余未知行仍 die。
- **manifest 加 mode 行 ⚠️→【严重】spec 事实错误**：spec Drift 节称"unknown rows were already tolerated in manifests"——**假的**。已核对 `arena_read_manifest`（lib/common.sh）对未知 key 执行 `arena_die "unknown manifest key"`。后果：(a) Task 1 必须改 manifest 读取器（plan 文件清单漏了 lib/common.sh）；(b) **v0.4 二进制读 v0.5 manifest 会 fail-closed**，Rollback 节"v0.5-written states remain readable by v0.4 … no state migration is needed"被夸大——run-state.tsv 可回读，但任何命令第一步读 manifest 就死了（G5）。
- **lock 回收改动** ✅ behavior-compatible（60s 无元数据 grace、dead-PID、token 释放全保留；last_seen 检查需 gate 到 autopilot 锁，plan 已说）。
- **list 不变** ✅（决策 A）。
- **唯一隐藏回归向量 = status 新增 project.conf 依赖**（G6）：v0.4 测试里若有"repo 已删/配置损坏但 status 仍可诊断"的场景会被新依赖打破。

---

## Q3 可行性：Bash 3.2 + fake CLI

**结论：可行**，三个疑点都有现成解法：

1. **pane 活性在 fake tmux 下可靠测试** ✅：tests/run.sh 已有 fake tmux 支持 `FAKE_TMUX_PANES=dead/reviewer-dead/normal/ambiguous` 等模式（§24 已测"reviewer pane unavailable"），`list-panes` 输出格式与 status.sh 的 awk 匹配。autopilot 测试只需新增 `writer-dead` 与 `session-missing`（FAKE_TMUX_MODE=offline 已存在）两种模式，零新机制。G3 钉死读取路径后即可写。
2. **`--watch` 常驻进程 hermetic 测试** ✅：循环体 = `--once` 逻辑（plan 主测 `--once` 是对的）；watch 外壳测试 = 后台启动 `--interval 1` + 断言动作发生 + `kill` 后断言锁可回收、heartbeat 行存在。Bash 3.2 下 `kill`/`wait` 足够，测试里用 `timeout` 或超时 guard 防挂死 CI。
3. **时间类测试** ✅：approve-delay/stall/relay-after 一律**改写状态文件时间戳**（WAITING_SINCE/last_transition_at/last_seen_at 均为 epoch，fixture 可直写），不 sleep；spec"interval comparisons, never exact deltas"的容忍策略同时降低了测试 flake。
4. **Task 0 的 rename-to-tombstone** ✅ Bash 3.2 `mv` 即可；**但 plan 的"two claimers"fixture 是伪并发**（同一进程两次顺序 acquire，第二次因 owner pid 活着走 exit 4 分支）——**对旧 rm+mkdir 实现同样通过**，违反 TDD"先红后绿"，也测不出 B4 要修的竞态（G7）。正确 fixture：两个后台进程（`&`）同时 acquire 一个 dead-owner 锁，断言恰一方成功、锁最终 held。

---

## Q4 裁决投票

### 裁决：**GATE-1 CONDITIONAL PASS**

理由：架构方向（状态机不动 + autopilot 外置 + opt-in）在 v0.4 源码层面全部验证成立；B1–B7 与采纳清单 90% 以上忠实落地；无方向性错误、无未裁定设计。但存在 1 个严重裁定缺口（停滞检测）、1 个三处打架的退出码映射、1 个读路径/第三态缺口、1 个悬空 flag、1 个事实错误，以及 1 个无效回归 fixture——全部是小改，修完即可进 Task 0–5。

### 必改项（7 项，阻塞级）

| # | 级别 | 问题 | 修法 |
|---|---|---|---|
| G1 | 严重 | **B3 停滞维度缺失 + 矩阵自相矛盾**：矩阵无停滞行，`submitted/validated + live → observe` 与 AC8"停滞即报警"直接冲突；"per-state defaults"未 pin | 矩阵补停滞行（live pane 但 WAITING_SINCE 超阈值 → exit 6）；钉死 per-state 阈值表（如 review_pending/decision_pending 30min、changes_requested 60min，可与 findings 示例一致）；或加 `--stall-after` 可覆盖（测试友好） |
| G2 | 严重 | **status 退出码 → autopilot 处置映射三处打架 + 意图/legacy 跳过机制缺失**：矩阵（status 2/5→6）、协议表（5=incomplete）、AC5（incomplete→6）、plan（2→error、5→incomplete）不一致；S1–S6 意图阶段与 repair intent 在 status 下与 corrupt/incomplete 同码，无法"跳过" | 钉死映射表：status 0→解析；2→exit 6（corrupt/conflict/需人工）；4→defer；5→exit 5（incomplete，可重试）或统一 6——三处对齐；跳过机制 = 先查 creation intent 文件（`arena_creation_intent_path`，list.sh 先例）与 `.repair.intent`，命中即 skip，不进入矩阵 |
| G3 | 严重 | **pane 活性读取路径未定义 + 缺第三态**：status 只报 reviewer pane；AC7"only read path"与矩阵 writer-pane 需求矛盾；无 tmux/session-not-running 时 auto 模式会 escalate 风暴 | 明示"status 是唯一 run-state 读入口；pane 活性由 autopilot 直接查 tmux（观测维度，复用 arena_find_live_pane/pane.sh），非状态读取"；pane 维度三值 live/dead/unknown，unknown（无 tmux 或无 session）→ observe 零动作 |
| G4 | 主要 | **`start --mode auto` 悬空**：US2/trust-model 引用但无契约；security S1 裁定的 run 级 opt-in 不可实现 | Round 2 契约节补：`start [--mode human\|auto]`（缺省 = project.conf approval_mode；显式 flag > config）；与 v05-AC3 intent 绑定明确"绑定生效值（flag 优先）" |
| G5 | 主要 | **manifest 契约事实错误 + rollback 声明过强**：spec 称"manifest 未知行本就被容忍"为假（arena_read_manifest fail-closed）；v0.4 二进制无法读 v0.5 manifest，rollback"no migration"被夸大 | 改正 Drift 节措辞（manifest 读取器须更新，属显式断言更新清单）；Rollback 节补"v0.5 manifest 带 mode 行，v0.4 工具不可读；降级需删两行或保留 v0.5 工具"；plan Task 1 文件清单补 lib/common.sh |
| G6 | 主要 | **status 漂移检查新失败模式未定义**：status 新增 project.conf 解析依赖，缺失/损坏时 oracle 行为未 pin | 钉死：漂移显示 best-effort——config 缺失/不可读/非法 → 仅显示 `Mode: <manifest>`（无 ⚠、无 exit 变更）；v0.4 测试不受影响 |
| G7 | 主要 | **plan Task 0 双实例 fixture 非并发、对旧代码也绿**：同一进程两次顺序 acquire 测不出 rm+mkdir 竞态，TDD"先红"步骤失效 | fixture 改为两个后台进程并发 acquire dead-owner 锁，断言恰一方成功 + 锁 held + 败方 exit 4；先对旧 lock.sh 验证红 |

### 建议项（非阻塞，12 项）

- S1：README/plan Task 5 补一行"监控者健康"配方：cron 检查 `autopilot.tsv` 的 `last_scan_at` 年龄 > 2×interval 即报警（补齐原始 sre"谁消费心跳"缺口；锁活性只解决了"僵尸 watch 不阻塞 --once"，没解决"全部监控死光"）。
- S2：spec 明示 `mode RUN_ID human` 即运行期 kill switch（operator 发现 auto 行为异常时的瞬时熔断；config 改动对 live run 无效，这是唯一干净手段）。
- S3：`autopilot.log` 加大小上限+轮转（Round 3 裁定原文含此项，spec 漏落）。
- S4：明示 state root 单机假设（NFS/多机共享 out of scope，锁活性基于本地 PID）。
- S5：加一句 watch 循环 per-run 错误隔离与致命错误响亮失败（state root 不可读 → log+非零+heartbeat error，绝不静默空转）。
- S6：`last_seen_at` 刷新节奏：长扫描（多 run）时按 run 刷新或明确"扫描时长 > 3×interval 时可能被并发接管，靠 run lock + 良性竞态兜底"，使 AC6 单实例承诺与实现一致。
- S7：spec 补 pin 观测文件路径（`<state_root>/autopilot.tsv|autopilot.log|autopilot-throttle.tsv`）。
- S8：钉死 `--once` stdout TSV 列（timestamp 有无）与 per-run/per-action 语义；autopilot.log 的 `mode` 行 result 取值。
- S9：plan Task 1 文件清单补 lib/init.sh（§50 断言 init 写 `approval_mode=human`）。
- S10：pin status `Mode:` 行位置（Tmux session 后）+ legacy 投影 run 的 Mode 行输出与测试。
- S11：`--repo` 默认值在非 git cwd 的行为；`--repo` 与 `--all-repos` 互斥 → usage error；mode 命令对 intent-stage/legacy run 的行为。
- S12：plan 在 Task 1 前枚举 v05-AC11 的断言更新清单（当前只有元描述）。

---

## 附录：源码核对记录（证据）

| 声明 | 核对结果 |
|---|---|
| state.sh L108-109 actor/action 枚举含 system、resolve-approve | ✅ 属实（`writer\|reviewer\|human\|system`；`…\|resolve-approve\|…`） |
| resolve.sh 硬编码 actor='human'、approve 清空 reason_detail | ✅ 属实（`ARENA_STATE_LAST_TRANSITION_ACTOR='human'`；approve 分支 `REASON_DETAIL=''`） |
| lock.sh dead-PID 回收 = rm+mkdir 两步竞态 | ✅ 属实（`rm -rf "$lock_path"; mkdir ...`），Task 0 修复必要且充分 |
| manifest 未知行"本就被容忍" | ❌ **不属实**：arena_read_manifest 对未知 key `arena_die`（fail-closed）→ G5 |
| status 只报 reviewer pane 活性、exit 0/2/4/5 | ✅ 属实（`arena_status_reviewer_pane_alive`；无 writer 检查）→ G3 |
| status 不读 project.conf | ✅ 属实（status.sh 无 arena_load_project_config）→ G6 |
| 严格 parser：未知 config 行 die | ✅ 属实（config.sh 正则白名单） |
| creation intent 绑定机制 | ✅ 属实（`arena_creation_intent_write`/`arena_start_verify_intent`，字段差异 exit 2），AC3 可实现 |
| list.sh 已有 intent 文件检查先例 | ✅ 属实（`arena_creation_intent_path` + S3/S4→2、S1/S2/S5/S6→5）→ G2 修法可行 |
| fake tmux 支持 dead/reviewer-dead/offline | ✅ 属实（tests/run.sh，§24 已测 reviewer pane unavailable）→ Q3 可行 |
| v0.4 T10 approve 断言不覆盖 reason_detail/actor | ✅ 属实（仅断言 run_status/phase/party/reason_code/verdict/validation_result/waiting_since/action） |
| relay.sh from 枚举 writer\|reviewer\|human | ✅ 属实，`[autopilot]` 前缀方案不破坏枚举 |
