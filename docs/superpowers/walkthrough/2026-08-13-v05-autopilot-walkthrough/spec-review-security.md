# v0.5 spec Gate 1 评审 — security（安全与审批合规）

> 评审对象：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`（正式 spec）
> 配套：实施计划 `docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`、走查裁定 `00-findings-summary.md`、v0.4 spec 与 `lib/*.sh` 源码。
> 角色：security — 审计链、信任模型、auto 滥用面、契约枚举。
> 方法：逐条核对 B1–B7、决策点 A/B、主要采纳清单在 spec 中的落地；对照源码验证每个契约断言的现实基础；按四个核心问题组织。

---

## 问题一：裁定忠实度（B1–B7、决策点、承诺收敛、主要采纳清单）

### 逐条核对表

| 裁定 | 落地情况 | 判定 |
|---|---|---|
| B1 actor=system + reason 透传 | `resolve` 增 `--actor human\|system`（默认 human）+ approve 保留 `--reason`→`reason_detail`。已核对 `lib/state.sh`：`last_transition_actor` 枚举含 `system`、`last_transition_action` 枚举含 `resolve-approve`；`lib/resolve.sh` 现硬编码 actor='human' 且 approve 清空 reason_detail——spec 的改动是纯增量，零 wire-contract 变更成立。**但同一原则未覆盖 escalate（见【严重】F2）** | ⚠ 部分 |
| B2 exit 6 新码 + 聚合优先级 | 协议表 0/4/5/6、优先级 6>5>4>0、避开 v0.4 0/1/2/3/4/5/10 ✓。**但 status exit 5 的三类来源与"skip/5/6"分类未 pin（见【严重】F5）** | ⚠ 部分 |
| B3 pane 活性二维 | state×pane 矩阵存在，reviewer-dead→escalate、writer-dead→alert 行存在。**但 B3 裁定原文"WAITING_SINCE 停滞超阈值（per-state 默认）→ 报警"在矩阵中整体丢失：submitted/validated + live pane 全部标 observe，无停滞行、无阈值表**（见【严重】F1） | ✗ 走样 |
| B4 锁回收原子化 | rename-to-tombstone + last_seen_at + 双实例 fixture 均写入 spec/plan ✓。**但"failed rebuild exits 4"与 plan 代码片段（arena_die=exit 1）矛盾、fixture 非真并发（见【主要】F8/F9）** | ⚠ 部分 |
| B5 mode 切换命令 + 漂移标记 | `mode RUN_ID human\|auto`（run lock、terminal 拒绝、autopilot.log 一行）+ `Mode: <mode> (config: <mode>) ⚠` ✓。**但 AC2"records the switch (actor + timestamp)"中 actor 无落盘载体（见【主要】F6）；S1 的 run 级显式 opt-in 未契约化（见【主要】F4）** | ⚠ 部分 |
| B6 relay 节流 | `last_relay_at` 观测、`--relay-after 30`（分钟）、`[autopilot]` 前缀、`skipped (throttled)` ✓ | ✓ |
| B7 完成边界 | 能力承诺 + 非承诺表（不 merge/push、completed≠交付）+ README 要求 ✓ | ✓ |
| 决策点 A list 不加列 | list row contract 不变；`--once` TSV 摘要含 mode 列；v0.6 显式升级项 ✓ | ✓ |
| 决策点 B resume 默认 0 | `--resume-attempts N=0`、启用记 `unconfirmed`、仍 exit 6 ✓ | ✓ |
| 承诺收敛 | auto=APPROVE+PASS 自动完成 + 其余 stop-and-alarm；非承诺表三行 ✓ | ✓ |
| 观测文件非权威 | autopilot.tsv/log 明示 best-effort，权威=run-state+SHA 归档，reason 实例 token 三元关联 ✓ | ✓ |
| 扫描走 status oracle | AC7 唯一读路径 ✓。**但 writer pane 活性 status 不输出（见【主要】F3）** | ⚠ 部分 |
| --repo 白名单 | `--repo`（默认 cwd）/`--all-repos`（显式、记录）✓。匹配规则（绝对路径规范化、与 manifest repository 比较）未 pin（【次要】） | ✓ |
| --approve-delay | 默认 300s、基于 `last_transition_at` ✓。**窗口内 exit 码未 pin，且 plan 已自行钉 6，与 exit-6 定义矛盾（见【主要】F5）** | ⚠ 部分 |
| intent 绑定 | AC3：mode 入 T1r creation intent，重试漂移 fail-closed（exit 2）✓ | ✓ |
| AC 命名空间 v05-ACn | ✓ | ✓ |
| "50 节零改动"→零语义漂移+断言更新清单 | AC11 ✓。**但 spec 断言"unknown rows were already tolerated in manifests"与源码相反（见【主要】F7）** | ⚠ 部分 |
| run 级显式 opt-in（security S1） | **走样**：`start --mode auto` 仅出现在 US2 散文与信任模型注记，AC1/契约节/命令面/实施计划均无此 flag（见【主要】F4） | ✗ 遗漏 |

### 主要发现

- 【严重】F1 — **B3 停滞报警维度丢失，AC8 与动作矩阵自相矛盾，US4 承诺不可达**（详见问题二）。
- 【严重】F2 — **autopilot 自动 escalate 的审计归属撒谎**：AC8 要求 auto 模式 reviewer-pane-dead 自动 escalate（T9），而 `lib/escalate.sh` 两条路径都硬编码 `ARENA_STATE_LAST_TRANSITION_ACTOR='human'`；spec 只给 resolve 加了 `--actor`，escalate 无任何 actor 参数。实现后，机器发起的 escalate 会被权威状态记录为"人类操作"——这正是走查 B1/S2 在 resolve 上明确拒绝的"审计撒谎"模式。**必改**：escalate 增 `--actor human|system`（默认 human；`system` 已在 v0.4 枚举内，零契约变更），autopilot 传 system；或显式裁定"escalate 保持 actor=human，归属靠 reason 实例 token 补足"并写入 spec。二者必选其一，不能让实现者猜。
- 【主要】F3 — **writer pane 活性信号缺失，AC8 的 writer-dead alert 无数据源**：AC7 钉死"status oracle 为唯一读路径"，但 `lib/status.sh` 只检查 reviewer pane（`arena_status_reviewer_pane_alive`），无任何 writer pane 输出；spec 为 status 新增的行只有 `Mode:`。因此 changes_requested+writer-dead → alert(exit 6) 既不可实现也不可测（fake tmux 的 writer-dead 场景还会被 status 误报为 reviewer unreachable）。**必改**：status 增加 writer pane 活性行（并列入 AC11 断言更新清单），或显式放宽 AC7 允许 autopilot 直读 pane——二选一 pin 死。
- 【主要】F4 — **S1"run 级显式 opt-in"走样**：采纳清单明确要求 `start --mode auto`（或 init TTY 确认）防止"project.conf 一个键被静默 uncomment 即全 repo auto"。spec 的 AC1 只有"project.conf 解析 + start 快照"，命令面无 `--mode` flag，计划 §50 测试也不用它。按现状，攻击者或误操作改一行配置即可让后续所有 run 进入 auto——正是 S1 要封堵的滥用面；信任模型注记声称的"run-level start --mode auto"约束实际不存在。**必改**：契约化 `start --mode auto`（flag 优先级 > config、与 --no-attach 等组合、严格校验）+ AC + 测试。
- 【主要】F5 — **status exit 5 三源分类与 skip/5/6 语义冲突，approve-delay 窗口内 exit 码未 pin**（详见问题二契约清单 C3）。
- 【主要】F6 — **mode 切换的 actor 无落盘载体**：AC2 承诺"records the switch (actor + timestamp)"，但契约只 pin 了 manifest `mode`/`mode_updated_at` 两行；`autopilot.log` schema（`timestamp run_id mode state action result`）无 actor 列。**必改**：manifest 增 `mode_actor` 行，或 log schema 增 actor 列，二选一。
- 【主要】F7 — **rollback/v0.4 兼容声明与源码事实相反**：spec drift 节称"unknown rows were already tolerated in manifests"，但 `lib/common.sh` `arena_read_manifest` 对未知 key 一律 `arena_die "unknown manifest key"`（fail-closed，exit 1），仅 `list` 用 awk 直读可容忍。v0.5 写入 `mode`/`mode_updated_at` 行的 manifest 无法被 v0.4 二进制读取（list 除外），"v0.5-written states remain readable by v0.4"的 rollback 承诺不成立。**必改**：修正声明为"v0.5 必须同步扩展 arena_read_manifest 接受新行；真正回退到 v0.4 二进制的场景需显式说明不支持（保留 v0.5 二进制 + 弃用 autopilot 才是 rollback 路径）"，并把 manifest 读取器变更列入 AC11 断言更新清单。

---

## 问题二：spec 质量（gate 1 标准）

### 2.1 每条 v05-AC 可否写 hermetic 测试

| AC | 可测性 | 备注 |
|---|---|---|
| v05-AC1 | ✅ | §50：strict parser 拒绝未知行已有基座；`approval_mode` 缺失默认 human、非法值带合法值列表 die |
| v05-AC2 | ⚠ | 切换/锁/终态拒绝/漂移标记可测；**"actor"断言无处可写（F6）** |
| v05-AC3 | ✅ | 中断 start fixture 改 config 后重试 exit 2（plan 已给思路） |
| v05-AC4 | ✅ | 端到端 APPROVE+PASS→completed + actor/action/reason_detail 断言 + delay 强制 + 幂等 |
| v05-AC5 | ✅ | 零 mutation（文件清单 + state_revision 不变）+ exit 6 |
| v05-AC6 | ⚠ | 单实例 exit 4 + last_seen 活性可测；**plan 的"双回收者 fixture"是顺序 acquire 非并发（F9）；lock busy 的 exit-4 机制未 pin（F8）** |
| v05-AC7 | ⚠ | 0/2/4 映射可测；**5 的三源分类未 pin（F5）** |
| v05-AC8 | ❌ | reviewer-dead escalate 可测（FAKE_TMUX_PANES=reviewer-dead）；**writer-dead 不可测（F3）；停滞报警无阈值不可测（F1）** |
| v05-AC9 | ✅ | fake tmux send-keys 日志 + 第二轮 skipped-throttled 行 |
| v05-AC10 | ✅ | 断言无 reject/cancel 副作用 + unconfirmed 路径 |
| v05-AC11 | ⚠ | 断言更新清单本身未在 plan 中成文（只散见各 Task Step 4 注释），且漏了 manifest 读取器（F7） |

### 2.2 契约是否 pin 死（字段/标志/默认值/退出码/文件 schema）

已 pin 死的：`approval_mode` 值域、manifest 两行、mode 命令语义（锁/终态/输出/日志）、`--actor` 值域与默认、autopilot 全部 flag 默认值（interval 30 / approve-delay 300 / relay-after 30 分钟 / resume 0）、退出码 0/4/5/6 与聚合 6>5>4>0、autopilot.tsv/.log schema、实例 token 格式、`.autopilot-lock` 位置、锁活性规则（pid alive AND last_seen fresh < 3×interval）、漂移显示格式、`[autopilot]` 前缀、reason 三元关联。**这块是本 spec 最强项**，明显吸取了 B2/B6 与 statemachine/qa 专家意见。

未 pin / 实现时必然再问的开放点：

- **C1（阻塞）per-state 停滞阈值表缺失**：AC8 说"stalled states (waiting longer than per-state defaults) alert"，但全 spec 无阈值表（B3 裁定举例 review_pending>30min 未采纳进正文）；矩阵对 submitted/validated+live 标 observe。停滞=另一维度还是矩阵行？阈值多少？exit 6 还是 0？——实现者必然要发明设计。
- **C2（阻塞）approve-delay 窗口内 exit 码**：auto 模式下 decision 后未满 delay 的 approval_pending：按 exit-6 定义（"needs a human"）应为 0/deferred，但 plan §51 测试已钉"exit 6"。窗口内每轮 cron 都报"需人工"会造成报警风暴，且与 exit-6 语义相悖。spec 未裁决。
- **C3（阻塞）status exit 5 三源分类**：creation intent S1–S6（AC7 说 skip）、repair intent、legacy residue（矩阵说 incomplete→error exit 6）、协议表 5=incomplete/residue——三者互相矛盾，且 autopilot 自身 exit 5 是否可达未定义。若 intent 全 skip 且 residue 归 6，则协议表 5 是死值。
- **C4（非阻塞）矩阵 pane 维度两值 vs status 三值**：status 区分"tmux session: not running / reviewer pane: unreachable / 可达"，矩阵只有 live/dead。session-down 在 submitted/validated 落到 unlisted→observe＝**静默**，违反 US4（tmux server 重启是最常见的无人值守故障）。reviewer_unreachable+live pane 同理：矩阵只列 dead 行，live 行 observe，与 AC5"blocked→exit 6"矛盾。
- **C5（非阻塞）锁 busy 的 exit-4 机制**：`arena_lock_acquire` 对 live-owner 分支走 `arena_die`（exit 1）；AC6 要求第二实例 exit 4 with owner pid。v0.4 靠 precheck 先行 exit 4，spec 未 pin autopilot/mode 的 precheck 或 acquire 后重映射。plan Task 0 片段 `mkdir || arena_die`（exit 1）与 spec"failed rebuild exits 4"同样矛盾。
- **C6（非阻塞）观测文件落盘细节**：autopilot.tsv/.log/throttle 的路径（spec 只 pin 了锁）、权限（600/700）、原子写（mktemp+mv）、tsv 行更新与无界增长（cron --once 每轮新实例=新行）均未 pin。
- **C7（非阻塞）良性竞态判定机制**：resolve exit 2 既可能是 guard 拒绝（benign-race）也可能是 corrupt state（error）——spec 说"guard rejects with 2 — logged benign-race"但未 pin 分类规则（建议：动作失败后重读 state 判定）。
- **C8（非阻塞）`--once` 摘要 "same schema as the action log"**：log 是 `timestamp run_id mode state action result` 六列，摘要声明为五列（无 timestamp），措辞不准。
- **C9（非阻塞）`--repo` 匹配规则**：--repo 是否需为仓库根、与 manifest `repository` 字段如何比较（规范化后相等？）未 pin。

### 2.3 与 v0.4 的一致性（隐性破坏排查）

- `resolve --actor`/approve 保留 reason：纯增量；§47 现有 approve 测试只断言 action/state，不断言 reason_detail 被清空——无破坏。✅
- status 加 `Mode:` 行：现有断言全部 grep-based（§27/§49 用 require_match），§49 的 zero-write 检查基于文件清单——无破坏。✅
- config 加 `approval_mode`：旧 project.conf 无该键→默认 human；strict parser 正则扩展不拒绝旧文件。✅
- manifest 加两行：**破坏点见 F7**——v0.5 自身必须同步改 `arena_read_manifest`；且"v0.4 二进制可读回"声明不成立。⚠
- lock 回收改 mv-to-tombstone：对无 last_seen 的 v0.4 锁语义等价（60s grace、dead-PID、token release 均保留）。✅ 但 plan 的实现片段与 spec 的 exit-4 契约矛盾（C5）。⚠
- 帮助文本/arena.sh 增加 autopilot/mode 命令：§0 断言不受影响。✅
- 计划 §53 测试描述 "lock with dead pid but fresh last_seen -> live" 与 spec 活性规则（pid alive AND last_seen fresh）矛盾——应改为"alive pid + fresh → live；alive pid + stale → 回收；dead pid → 回收"。⚠

---

## 问题三：可行性（Bash 3.2 + fake CLI）

**总体：可行**，状态机不动 + 外部编排层的架构在 Bash 3.2 下没有技术障碍（mv 原子性、mktemp+mv、date +%s、awk 解析均已在 v0.4 验证过）。具体：

1. **pane 活性二维在 fake tmux 下基本可测**：`FAKE_TMUX_MODE=relay|live` + `FAKE_TMUX_PANES=reviewer-dead` 已能驱动 status 输出 "reviewer pane: unreachable"，reviewer-dead→escalate 路径可端到端断言。⚠ 但 (a) writer-dead 无独立 fake 模式（现有 `dead` 模式只输出 writer 且 status 会误报 reviewer unreachable）——需新增 writer-dead 模式与 status writer 行（F3）；(b) session-down（has-session 失败）在矩阵中无映射（C4）。
2. **`--watch` 常驻进程的 hermetic 测试策略未定义**：spec/plan 全部用 `--once` 测逻辑，watch 循环、锁 last_seen 刷新、心跳更新只能靠 timeout+kill 冒烟。**建议**：pin 一个测试专用有界模式（如 `--max-scans N` 隐藏 flag 或环境变量 `ARENA_AUTOPILOT_MAX_SCANS`），否则 watch 的核心路径（循环内刷新 last_seen、崩溃后回收）永远无断言。锁活性本身（<3×interval）可通过伪造 owner 元数据确定性测试，无需真 sleep。
3. **时间维度可测**：approve-delay / relay-after / 停滞阈值都基于 epoch 字段，测试可直接改写 run-state.tsv 的 `last_transition_at`/`waiting_since`（保持不变量即可），无需 sleep。可行。
4. **真并发 fixture 可行但 plan 没写对**：双回收者需两个子 shell 同时 acquire 同一 dead-owner 锁，断言"恰一个成功 + 锁最终 held 且 owner 唯一"。plan 的 fixture 是同一 shell 顺序 acquire，只测了"第二个 acquire 失败"，**测不出 rename 竞态**（F9）。
5. **exit-4 协议在 lock.sh 现状下不可直接达成**：需 pin precheck/重映射机制（C5），否则 AC6/AC2 的 exit-4 测试会失败在 arena_die=exit 1 上。

---

## 问题四：裁决投票

### 投票：**CONDITIONAL PASS**

**理由**：架构方向（状态机不动 + autopilot 外部编排 + opt-in 默认 human）与 B1/B2/B4/B6/B7、决策点 A/B 等核心裁定均已忠实落地，契约 pin 死程度在 v0.4 基座上做得相当扎实（flag 默认值、退出码、文件 schema、锁活性规则全部有值）；没有方向性错误，不需要重写。但存在 7 个阻塞级缺口——其中 F1（停滞维度丢失且 AC8 与矩阵自相矛盾）和 F2（escalate 审计归属撒谎）直接击穿"每个停滞路径都可观测报警"与"审计链不变"两条承诺，且 F3/F4/F5 会让实现者在"再问一次"和"违背 spec 某条"之间被迫二选一。修完这 7 项即可放行 Task 0–5。

### 必改项（阻塞级，7 项）

1. **F1 停滞报警维度**：恢复 B3 裁定的停滞维度——新增 per-state 默认阈值表（如 review_pending/decision_pending > 30min、changes_requested > relay-after 且超更长阈值→exit 6），矩阵补停滞行（或明确停滞为第三维），AC8 配测试。当前"AC8 承诺 alert、矩阵 observe、阈值无表"三者互相矛盾。
2. **F2 escalate 审计归属**：escalate 增 `--actor human|system`（默认 human，autopilot 传 system）并 pin 进契约与测试；或显式裁定维持 actor=human 并由 reason token 补足——不能留白。
3. **F3 writer pane 活性信号**：status 增 writer pane 行（列入 AC11 断言更新清单）或放宽 AC7 允许 autopilot 直读 tmux——pin 死其一，使 AC8 writer-dead alert 可实现可测。
4. **F4 run 级显式 opt-in**：契约化 `start --mode auto`（flag 优先级 > project.conf、校验、与 --no-attach 组合、AC + 测试），兑现 S1 与信任模型注记的承诺。
5. **F5 exit 分类表**：pin 一张"status 输出/退出码 → autopilot 分类（skip/defer/5/6）→ 聚合码"映射表，覆盖 status exit 5 的三源（creation intent / repair intent / legacy residue），并裁决 approve-delay 窗口内 exit 码（建议 0+deferred 行，与 exit-6"needs a human"定义一致）。
6. **F6 mode 切换 actor 载体**：manifest 增 `mode_actor` 行或 autopilot.log 增 actor 列，兑现 AC2"records actor + timestamp"。
7. **F7 rollback 声明修正**：承认 `arena_read_manifest` 对未知 key fail-closed，修正"unknown rows tolerated"的错误断言；把 manifest 读取器扩展列入 AC11 断言更新清单；明确"保留 v0.5 二进制 + 弃用 autopilot"为 rollback 路径。

### 建议项（非阻塞）

- 矩阵补 pane 第三值（session not running）映射，避免 submitted/validated + session-down 静默 observe（C4）。
- reviewer_unreachable + live pane 行补"alert（exit 6）"，与 AC5"blocked→exit 6"对齐（C4）。
- 锁 busy→exit 4 机制 pin 死（precheck 或 acquire 重映射），并修正 plan Task 0 片段（rebuild 失败应 exit 4 而非 arena_die 的 1）（C5）。
- plan 双回收者 fixture 改为真并发子进程 + "恰一个成功"断言（F9）。
- `--watch` 加有界测试钩子（如 `ARENA_AUTOPILOT_MAX_SCANS`），否则 watch 循环/锁刷新/崩溃回收无断言。
- 观测文件路径、权限、原子写、autopilot.tsv 每实例一行的无界增长（轮转/压缩）pin 死（C6）。
- 良性竞态判定规则（动作失败后重读 state 分类）pin 死（C7）。
- `--once` 摘要 schema 措辞修正（无 timestamp 列，勿称 same schema）（C8）。
- `--repo` 白名单匹配规则（规范化、与 manifest repository 相等）pin 死（C9）。
- 计划 §53 的 last_seen 测试描述修正（dead pid + fresh last_seen 应为可回收）。
- 实例 token（host:pid:nonce+scan-ts）长度与 reason_detail ≤256 的边界规则（超限拒绝或截断）。
- 文档化：watch 模式的"报警"通道 = 日志行 + 部署矩阵（cron --once 承担 page），watch 本身不会以非零码退出——M7 的裁定以"部署矩阵"方式收敛，建议在 README 中显式写明"watch 不报警，报警请用 cron --once"。

---

## 一句话总结

**方向正确、契约功底扎实，但 B3 的停滞报警维度在矩阵里整体丢失（AC8 与矩阵自相矛盾、阈值无表），且 autopilot 自动 escalate 会在权威审计记录里被记成 human——这两条不修，"每个停滞路径都可观测报警"与"审计链不变"的承诺就都不成立；连同 run 级 opt-in 走样、writer 活性信号缺失、exit-5 分类空白、mode actor 无载体、rollback 声明失真共 7 项必改，修后可放行实现。**
