# v0.5 spec Gate 1 评审 — statemachine（状态机/一致性/并发专家）

> 评审对象：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`（正式 spec）
> 配套：实施计划 `docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`、走查裁定 `00-findings-summary.md`、v0.4 spec 与 `lib/*.sh` 源码、`tests/run.sh`（50 节，198KB）。
> 方法：逐条对照 B1–B7 / 决策点 A/B / 主要采纳清单 vs spec 契约；逐条核对 v05-AC1–11 的可测性与契约 pin 死程度；对 `lib/lock.sh`、`lib/state.sh`（manifest/intent/枚举校验）、`lib/status.sh`、`lib/resolve.sh`、`lib/common.sh`、`lib/config.sh`、`lib/init.sh` 做源码级核对；对 `tests/run.sh` 的断言方式（grep 基、无行数断言）与 fake tmux 能力做抽查；全库 grep 退出码占用。

## 裁决摘要

**GATE-1：CONDITIONAL PASS**（可进入实现，但必须先修 9 项阻塞级必改项）。

方向性判断与五专家走查一致：**状态机不动 + autopilot 外置 + opt-in 默认 human** 是正确架构，T10 guard 天然吸收 approve 竞态，B1–B7 与决策点 A/B 的裁定采纳度很高（见 Q1 核对表）。但本 spec 在**状态机/并发域内存在 9 处契约缺口**：其中 2 处是源码可验证的硬伤（manifest 读取 fail-closed 与 spec 的 drift 注事实矛盾；writer pane 活性与"status oracle 唯一读入口"矛盾），其余为"实现时必然要再问一次"的未 pin 契约（停滞阈值、exit 5/6 语义、锁 busy 退出码机制、start --mode、mode actor 记录等）。全部有明确的修法路径，无需重写。

---

## 一、裁定忠实度（问题 1）

### 1.1 逐条核对表

| 裁定 | 结论 | 核对依据 |
|---|---|---|
| B1 actor=system+reason 透传 | ✅ 完全落地 | spec「resolve audit pass-through」；已核实 `lib/state.sh` 枚举 `last_transition_actor in writer\|reviewer\|human\|system`、`last_transition_action in ...resolve-approve...`（源码 L6412 附近），`--actor` 默认 human 保持 v0.4 行为；`--reason` 保留仅当提供，v0.4 approve 分支确实清空 `REASON_DETAIL`（`lib/resolve.sh` approve 分支 `ARENA_STATE_REASON_DETAIL=''`） |
| B2 exit 6 新码 | ⚠️ 部分落地 | 协议表 0/4/5/6 + 聚合优先级 6>5>4>0 已写；全库 grep 确认 v0.4 lib 无任何 `exit/return 6`，无碰撞。**但 exit 5 与 exit 6 的触发映射在 spec 内部、spec 与 plan 之间互相矛盾**（见必改项 #4） |
| B3 pane 活性二维 | ⚠️ 部分落地 | state×pane 矩阵已写，reviewer dead→escalate（T9 合法）、writer dead→alert、停滞→alert 均有行。**两个硬伤**：①矩阵无"停滞"行（live pane + 超时）而 AC8 承诺停滞报警——矩阵与 AC 矛盾（必改 #3）；②writer pane 活性 status 不输出（必改 #1） |
| B4 锁回收原子化 | ⚠️ 部分落地 | rename-to-tombstone、单赢家、失败重试语义已写；**但"失败退出 4"与"第二实例退出 4"的机制缺失**：`lib/lock.sh` 所有 die 路径退出 1（必改 #5） |
| B5 mode 切换命令+漂移标记 | ⚠️ 大部分落地 | `mode RUN_ID human\|auto` + 锁 + ⚠ 漂移标记齐全；**但"记录 actor"无处落盘**（autopilot.log schema 无 actor 列），**"status 显示最近切换"未实现**（spec 只加 Mode 行，无 mode_updated_at 展示）——B5 裁定走样（必改 #7） |
| B6 relay 节流 | ✅ 完全落地 | `last_relay_at`、`--relay-after 30`、`[autopilot]` 前缀、`skipped (throttled)`、`--from` 默认 human 均 pin |
| B7 完成边界 | ✅ 完全落地 | capability promise + 非承诺表 + README 项齐全 |
| 决策点 A list 不加列 | ✅ 完全落地 | 列入 out-of-scope v0.6；`--once` TSV 摘要含 mode 列补足 dashboard 需求 |
| 决策点 B resume 默认 0 | ✅ 完全落地 | `--resume-attempts N=0`；启用时 unconfirmed + 仍 exit 6 |
| 承诺收敛（approve 自动 + stop-and-alarm） | ✅ 完全落地 | capability promise 两段式措辞与裁定一致 |
| 观测文件非权威 | ✅ 完全落地 | autopilot.tsv/log 定位 best-effort；审计链仍 run-state+决策归档；三元关联 |
| 扫描走 status oracle | ⚠️ 见必改 #1 | AC7 已写（exit 0/2/4/5 映射、legacy/intent 跳过、live lock defer），但 oracle 输出不含 writer pane 活性，矩阵无法实现 |
| --repo 白名单 | ✅ 完全落地 | `--repo`（默认 cwd repo）/`--all-repos`（显式+记录） |
| --approve-delay | ✅ 完全落地 | 默认 300s；冷却窗口 |
| intent 绑定 | ⚠️ 见必改 #6 | AC3 已写（T1r 派生输入含 mode）；但 `start --mode` 旗标未 pin，S1 裁定"run 级显式 opt-in"半落地 |
| AC 命名空间 v05-ACn | ✅ 完全落地 | 与 v0.4 AC1–13 不撞号 |

### 1.2 新增未裁定设计（需注意，均非方向性错误）

- **autopilot-throttle.tsv**：plan Task 4 引入第三个观测文件（`run_id reason last_relay_at`），spec 观测文件节只列 autopilot.tsv/log，key trace 仅写"record last_relay_at in autopilot observation"——文件 schema 只存在于 plan，未入 spec（建议项 R5）。
- **矩阵 "guard mismatch = error" 行不可达**：v0.4 不变量下 `decided/human/approval_pending` 必为 V=APPROVE∧VR=PASS（state.sh 分层不变量），"other"组合是损坏态（status exit 2）。保留为防御性无妨，但应注明（建议项 R17）。
- **start --mode auto（US2）**：spec 用户故事提到但契约节无旗标定义——见必改 #6。

---

## 二、spec 质量（问题 2）

### 2.1 v05-AC 可测性（hermetic 标准）

| AC | 可测？ | 说明 |
|---|---|---|
| AC1 | ✅ | §50：init 写键、严格解析器拒绝未知行/非法值（die+合法值列表）、manifest 快照、legacy 缺省 human 均可确定性断言 |
| AC2 | ✅ | §50：mode 切换、锁（precheck 路径 exit 4）、终端拒绝 exit 2、status Mode 行与 ⚠ 漂移 |
| AC3 | ✅ | §50：手工构造带 mode 字段的 creation intent + 改 config → 重试 exit 2 |
| AC4 | ✅ | §51：`--approve-delay 0` 通过 / `3600` 拒绝；actor/action/reason_detail 断言；二次 --once 幂等 |
| AC5 | ✅ | §52：human 模式零状态变更（比较 run-state 前后 digest）、exit 6 |
| AC6 | ✅（fixture 需重写） | 见必改 #9b：plan 的"双回收者"fixture 在 v0.4 旧代码上也通过，TDD 失效；需双进程真并发 + 断言输家 exit 4 |
| AC7 | ✅ | 通过构造 state 文件驱动 status 真实退出码（fake tmux + 真实 status） |
| AC8 | ❌ 停滞部分不可测 | pane-dead 部分可测（fake tmux `reviewer-dead`/`dead` 模式已存在）；**停滞部分在阈值未 pin 前无法写测试**（必改 #3；阈值 pin 后可用回填 waiting_since 确定性测试，无需 fake 时钟） |
| AC9 | ✅ | 两次 --once；fake tmux send-keys 记录可断言节流；`skipped-throttled` 日志行 |
| AC10 | ✅ | §52：cancel/reject 永不发出（fake tmux/状态断言）、unconfirmed 路径、exit 6 持续 |
| AC11 | ⚠️ | 断言更新清单**被引用但从未产出**（必改 #9c）；且 manifest 变更会先炸掉 §0–49（必改 #2） |

### 2.2 契约 pin 死程度与开放问题

已 pin 死（无歧义）：autopilot 旗标全集与默认值（--interval 30 / --approve-delay 300 / --relay-after 30 / --resume-attempts 0）、autopilot 退出码表 0/4/5/6 与聚合优先级、autopilot.tsv 列、autopilot.log 列与 result 枚举（7 值）、action 矩阵全部行、`--once` stdout TSV 列、approve 的 actor/action/reason 三件套、`--from` 保持 human、漂移标记格式、锁活性公式（pid alive AND last_seen fresh < 3×interval）、60s grace 保留、tombstone 命名。

**实现时必然要再问一次的开放问题（全部进入必改项或建议项）**：

1. status-5（incomplete transition）到底映射 autopilot exit 5 还是 6？（必改 #4）
2. 停滞阈值是多少？哪些状态算停滞？矩阵为何没有停滞行？（必改 #3）
3. autopilot 锁 busy 时由谁、以什么机制 exit 4？（必改 #5）
4. `start --mode auto` 的旗标契约、与 project.conf 的优先级？（必改 #6）
5. mode 切换的 actor 写在哪？（必改 #7）
6. status 读 project.conf 失败（缺失/非法行）时的行为？（必改 #8）
7. writer pane 活性从哪个 oracle 来？（必改 #1）
8. manifest 加行后 arena_read_manifest 怎么办？（必改 #2）
9. 次要级：approve-delay 基线字段（建议 R1）、resume-attempts 计数范围（R3）、legacy conflict 与 legacy-skip 优先级（R4）、已完成 run 是否记 benign-race（R7）、config 行语法与重复键（R6）、session 缺失是否等同 pane dead（R9）等。

### 2.3 与 v0.4 的一致性（隐性破坏核查）

- 【严重·必改 #2】**manifest 加行 = 全命令炸**：v0.5 spec drift 注声称"unknown rows were already tolerated in manifests"——**与源码相反**。`lib/common.sh arena_read_manifest()` 对未知 key 是 `*) arena_die "unknown manifest key ..."`（fail-closed）。已核实 9 个命令/脚本调用它：status、start、submit、validate、decision、escalate、resolve、relay、repair-state（+pane.sh/preflight.sh）。给 manifest 增加 `mode`/`mode_updated_at` 两行后，**所有这些命令立刻 die（exit 1）**，§0–49 大片红。而 plan Task 1 的文件清单只有 config.sh/start.sh/status.sh/arena.sh + 新建 mode.sh，**遗漏 common.sh（arena_read_manifest 与 arena_write_manifest 签名）**。"零语义漂移"承诺以当前计划实现必然破产。
- 【主要·必改 #8】**status 新增 config 读路径**：v0.4 status 从不读 project.conf（只读 manifest/state/tmux），v0.5 为 Mode 行/漂移标记必须读；`arena_load_project_config` 对缺失/非法行 die（exit 1）。status 的退出码契约"0/1/2/4/5"里 1 本义是 usage——config 损坏被报成 usage 错误，且此前 status 成功（0）的场景现在可能失败。行为未 pin。
- ✅ status 输出加 `Mode:` 行本身安全：已抽查 `tests/run.sh` 全部 status 断言为 `require_match`（grep -F），无行数/整行相等断言，`Gate: cursor` 等子串断言不受新增行影响。
- ✅ exit 6 无碰撞：全库 grep `exit|return 6` 零命中；v0.4 协议 0/1/2/3/4/5/10 与 autopilot 0/4/5/6 数值重叠处（4）语义按命令域隔离（run 锁 vs autopilot 锁），可接受但建议在 README 明示。
- ✅ resolve `--actor` 默认 human + approve 无 --reason 时仍清空 reason_detail：现有测试 `resolve "$ap_run" --action approve` 不带 --reason，断言不破。
- ✅ 锁回收原子化对既有测试行为兼容（单回收者路径等价）；但 plan Task 0 的 fixture 无效（必改 #9b），且失败路径退出码与 spec 承诺不符（必改 #5）。
- ⚠️ v05-AC11 要求"显式断言更新清单"，spec 与 plan 都只是"提到要有"，**清单本体不存在**（必改 #9c）。

---

## 三、可行性（问题 3）

**结论：Bash 3.2 + fake CLI 环境下可行，三处需补测试基建/夹具。**

1. **pane 活性在 fake tmux 下可测**：`tests/run.sh` 的 fake tmux 已支持 `FAKE_TMUX_PANES=normal|ambiguous|dead|reviewer-dead|input-off|copy-mode|synchronized`，字段 5=dead 标志即 pane 活性源，reviewer/writer dead 场景均可确定性构造。唯一缺口：fake 按**全局变量**返回 pane 集，不按 session 名分支——多 run 同时处于不同 pane 状态的矩阵测试（§53 需一 run 死 reviewer、另一 run 活 writer）需要给 fake tmux 增加按 `-t <session>` 分支的小扩展（建议 R12，工作量极小、确定性不变）。
2. **--watch 常驻进程的 hermetic 测试**：
   - 大部分逻辑（矩阵、节流、聚合、幂等）用 `--once` 两次即可覆盖，plan 已采用；
   - last_seen 活性/回收可用**确定性构造**：手工写 owner 文件 `pid=<测试自身 shell 的活 pid>` + `last_seen_at=<陈旧值>` → 第二次 acquire 应回收（无需真 sleep）；
   - **真"双回收者"必须双进程**：两个后台 subshell 同时 mv 同一锁目录，断言恰好一个成功、输家 exit 4——plan 当前单进程 fixture 测不到竞态（必改 #9b）；
   - 建议补 `--max-scans N` 测试钩子或明确"后台启动 + 轮询 autopilot.tsv + kill"方案（R13）；
   - approve-delay 用 0/3600 双值确定性测试；停滞超时在阈值 pin 后用**回填 waiting_since** 测试（无需 fake 时钟，与 spec 的"interval 比较、容忍抖动"一致）。
3. **并发正确性红线已具备**：run 锁串行化 mode 切换与 autopilot 的 resolve（后者自身持锁），锁序 autopilot-lock→run-lock 无环；mode-vs-approve 存在扫描后切换的 TOCTOU 窗口，建议显式列入 benign-race 清单（R8）。长扫描（--all-repos 多 run）下 `last_seen` 若只在整轮扫描后刷新，可能超过 3×interval 被误回收 → 建议按 run 粒度刷新（R2）。

---

## 四、裁决投票（问题 4）

### 投票：CONDITIONAL PASS

理由：架构与 72 条走查裁定的采纳度合格（B1/B6/B7/A/B 及多数采纳项零走样），可测性设计（§50–53）总体成立；但状态机/并发域存在 2 处源码可验证的硬伤与 7 处契约缺口，直接实现会导致 §0–49 回归大面积失败（必改 #2）或矩阵无法落地（必改 #1）。这些问题均可在 spec/plan 层小修解决，不构成方向性错误，故不判 FAIL。

### 必改项（阻塞级，9 项）

1. **【严重】manifest 加行前必须先改 `arena_read_manifest`/`arena_write_manifest`（common.sh）**：spec drift 注"unknown rows were already tolerated in manifests"与源码相反（fail-closed die）；Task 1 文件清单补 common.sh；drift 注改为"manifest reader 扩展两个已知键，其余未知键仍 fail-closed"。
2. **【严重】writer pane 活性与 AC7"status oracle 唯一读入口"矛盾**：v0.4 status 只输出 reviewer pane 活性（`reviewer pane: unreachable` 诊断句），无 writer pane 行；矩阵 changes_requested 行无法实现。二选一必须 pin：(a) status 增加 writer-pane 观测行（drift 注随之改为"status 增两行"，并给出精确行格式与新增断言清单）；或 (b) 放宽 AC7 为"状态读取唯一走 status；pane 活性为观测性探测，允许 autopilot 按 v0.4 `arena_pane_format` 直接探测（观测文件，非权威）"。推荐 (b)（零 v0.4 输出变更）。
3. **【主要】停滞检测契约缺失且矩阵自相矛盾**：AC8/US4 承诺"stalled states（per-state 默认）→ alert exit 6"，但矩阵对 live review_pending/decision_pending 只写 observe、无停滞行，且**阈值一个都没 pin**（findings B3 的示例"review_pending>30min"未采纳为默认值）。必须：pin 每个停滞状态的默认阈值（或增加 `--stall-after MINUTES` 旗标）、在矩阵补停滞行（live pane + waiting_since 超阈值 → alert exit 6，两模式一致）、测试用回填 waiting_since 确定性覆盖。
4. **【主要】autopilot exit 5 与 exit 6 映射冲突**：AC5 与矩阵把 incomplete（status 5）归入 exit 6；协议表称"5=incomplete/residue encountered"；plan Task 3 把 status 5 映射为 incomplete（即 exit 5）；走查 B2 裁定原文"5=incomplete、6=需人工"。四处不一致。必须统一（建议：status-2 corrupt/conflict → 6；status-5 incomplete → 5；approval_pending/blocked/stall → 6），并同步 AC5 措辞与 §52 断言。
5. **【主要】autopilot 锁 busy/回收失败退出码 4 的机制缺失**：spec 承诺"第二实例 exit 4""失败重建 exit 4（retry）"，但 `lib/lock.sh` 的 held-lock die 路径与 plan Task 0 的新代码（`arena_die ...`）都退出 **1**；且 autopilot 锁没有 v0.4 那样的 `arena_state_precheck_lock_live` 预检（autopilot 锁活性是 pid alive AND last_seen fresh，需新的预检函数）。必须 pin：autopilot 锁获取先做活性预检（busy → exit 4 带 owner pid），回收 mv 输家与重建失败均 exit 4；`mode` 命令复用 `arena_state_precheck_intents` 保证 exit 4（当前 die 路径也是 1）。
6. **【主要】`start --mode auto` 未 pin（S1 裁定半落地）**：findings"run 级显式 opt-in（security S1）"要求 `start --mode auto` 或 init TTY 确认；spec 只在 US2 提了旗标，契约节无 start 旗标定义（无默认值/优先级/与 project.conf 冲突规则/是否入 intent）。必须：pin `start [--mode human|auto]`（默认取 config）、与 config 的关系（旗标覆盖 config？二者冲突时 die？）、写入 intent 的字段名（与 mode 命令共用 `mode` 键），或在 spec 明示改用 init TTY 确认方案。
7. **【主要】mode 切换的 actor 记录未 pin + status 未显示最近切换（B5 走样）**：裁定要求"记录 actor/时间，status 显示最近切换"；spec 只写了 `mode_updated_at`（时间）+ autopilot.log 一行（schema `timestamp run_id mode state action result` **无 actor 列**），actor 无处落盘，status 也无切换时间展示。必须：pin actor 落点（如 autopilot.log 增 actor 列并升级断言、或 manifest 增 `mode_updated_by` 行），并决定 status 是否打印 `Mode updated: <ts>`（B5 裁定要求显示）。
8. **【主要】status 读取 project.conf 的新失败模式未定义**：Mode 行/漂移标记使 status 首次依赖 config 解析；config 缺失/含未知行时 `arena_load_project_config` die（exit 1，且 v0.4 下 status 本会成功）。必须 pin 行为（建议：config 不可读时打印 `Mode: <manifest> (config: unreadable) ⚠` 且保持 exit 0；非法值同理），并补一条 §50 断言；否则"status 退出码契约 0/1/2/4/5"的语义被悄悄扩展。
9. **【主要】计划级测试缺陷（3 处）**：
   - §50 drift fixture 自相矛盾：先 `mode mode-run auto` 把 manifest 切成 auto，随后却断言 `'Mode: human (config: auto) ⚠'`——正确实现下必失败；需先做"manifest=human + config=auto"漂移断言，再做切换。
   - Task 0 "two-claimer" fixture 不真并发：顺序调用下第二次 acquire 撞上的是**活**锁（同一 shell 的 pid），v0.4 旧代码同样通过 → 测试空转、TDD 失效；须双进程并发 + 断言输家 exit 4。
   - 断言更新清单缺失：AC11/plan Task 5 反复承诺"显式 assertion-update list"，spec 与 plan 都未产出清单本体；Task 0 与 Task 1 的测试还共用节号 '50.'。须在 plan 补全清单（config 键、Mode 行、manifest 行、autopilot.log 若加 actor 列等）并理顺节号。

### 建议项（非阻塞，17 项）

- R1 status oracle 解析契约 pin：autopilot 需从 status 输出解析 state/`since <ts>`/pane 行，建议 pin 精确解析格式与 approve-delay 基线字段（`last_transition_at` vs `waiting_since`，当前二者在 approval_pending 相等，但契约只能取 status 可输出的那个）。
- R2 last_seen 刷新节奏：长扫描（--all-repos）可能超过 3×interval 被误判死锁；建议每 run 扫描后刷新 last_seen。
- R3 `--resume-attempts` 计数范围 pin（per-run 累计 vs 每次 blocked 片段）。
- R4 legacy run 的 status-2（conflict）与 AC7"legacy 跳过"的优先级 pin（建议：legacy 无论 exit code 一律跳过）。
- R5 autopilot-throttle.tsv schema 从 plan 并入 spec 观测文件节（含写者/并发说明）。
- R6 config 行语法 pin：`approval_mode=auto` 无引号 vs 现有键带引号；重复键 last-wins 还是 die。
- R7 "已完成 run" 是否产生 benign-race 日志行（AC4 措辞 vs 矩阵 skip）pin。
- R8 mode 切换 vs approve 的扫描后 TOCTOU 窗口列入 benign-race 清单并文档化。
- R9 tmux session 整体缺失是否等同"reviewer pane dead"（auto escalate 判定）pin。
- R10 init 对既有 project.conf 不追加 approval_mode 的语义明示（解析器缺省 human 已兜底）。
- R11 autopilot 锁 owner metadata 键名 pin（pid/token/created_at/last_seen_at）。
- R12 fake tmux 按 session 分支 pane 状态（多 run 矩阵测试基建）。
- R13 `--max-scans N` 测试钩子或"后台 + 轮询 + kill"的 --watch 测试方案。
- R14 autopilot 在非仓库 cwd 下 `--repo` 默认值行为。
- R15 `mode` 命令对 creation intent（S1–S6）的预检行为（与转换命令一致：exit 5 retry start）。
- R16 US1"只观测和报警"与矩阵 human 模式也发 relay 提醒的措辞矛盾。
- R17 矩阵 "guard mismatch = error" 行注明不可达（v0.4 不变量保证），纯防御。

### 最关键 1 个问题

**必改 #2：manifest 加 `mode`/`mode_updated_at` 两行会立即炸掉全部 9 个 manifest 读取命令**——`arena_read_manifest` 对未知键 fail-closed（`arena_die`），spec 的"unknown rows were already tolerated in manifests"是与源码相反的错误陈述，且 plan Task 1 漏改 common.sh。这是"零语义漂移"承诺下唯一一个**实现即崩**的点：按现计划执行，§0–49 回归在第一轮就会大面积失败；必须先改 manifest 读写器并修正 drift 注，再谈其他。
