# v0.5 spec Gate 1 评审 — QA（测试与质量专家）

> 评审对象：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`（正式 spec）
> 配套：`docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`、
> `docs/superpowers/walkthrough/2026-08-13-v05-autopilot-walkthrough/00-findings-summary.md`、
> v0.4 spec（`2026-08-13-run-state-authority.md`）与 `lib/*.sh` 源码、`tests/run.sh`（§0–49，共 50 节）。
> 角色：qa — hermetic 可测性、fixture 设计、回归核对、AC 断言。

**核对过的源码事实（本评审的断言基础）**：

- `lib/common.sh`：`arena_read_manifest` 对未知 manifest key **fail-closed die**
  （`*) arena_die "unknown manifest key '$key' in $manifest"`）；`arena_die` 恒 exit 1。
- `lib/status.sh`：只诊断 **reviewer pane**（`reviewer pane: unreachable`）；`verdict`/`validation_result`
  仅对**终态**打印（`state: <status>; verdict: <verdict>`），非终态（含 approval_pending）不打印；
  退出码 0/1/2/4/5；**不读取 project.conf**。
- `lib/resolve.sh`：`ARENA_STATE_LAST_TRANSITION_ACTOR='human'` 硬编码；approve 分支无条件
  `ARENA_STATE_REASON_DETAIL=''`（清空 reason）。
- `lib/escalate.sh`：`last_transition_actor='human'` 硬编码，无 `--actor` 选项。
- `lib/lock.sh`：dead-owner 回收是 `rm -rf` + `mkdir` 两步（非原子）；live-owner 竞争走
  `arena_die`（**exit 1**），仅 metadata-less fresh 分支 exit 4。
- `lib/config.sh`：严格解析器只接受 `key="value"` **带引号**形式，未知行 die。
- `lib/list.sh`：用 awk 直接解析 manifest（容忍未知行）；不经过 `arena_read_manifest`。
- `lib/decision.sh`：APPROVE 守卫保证 `validation_result=PASS`（决策层已保证 APPROVE⇒PASS）。
- `tests/run.sh`：§0–49 共 50 节；status 断言全为 grep 型（`require_match`）；list 断言按列位置
  （`list_column`）；fake tmux 已支持 `normal/ambiguous/dead/reviewer-dead/input-off/copy-mode/
  synchronized` 七种 pane 形态，`arena_find_live_pane` 要求 8 字段中 5–8 全 0。
- `tests/run.sh` 现有断言中无 `approval_mode`、`Mode:`、unknown-manifest-key 相关断言
  （新增不影响既有断言）。

---

## 问题 1：裁定忠实度（00-findings-summary 逐条核对）

| 裁定 | spec 落地 | 判定 |
|---|---|---|
| B1 actor=system + reason 透传（resolve） | ✅ resolve 增 `--actor human|system`（默认 human）、approve 保留 `--reason` → reason_detail；action 保持 resolve-approve | 忠实（但 escalate 侧未裁定，见 F-03） |
| B2 exit 6 新码 + 聚合优先级 | ✅ 退出码表 0/4/5/6、优先级 6>5>4>0、预期竞态只记日志 | **部分走样**：incomplete 的归属自相矛盾（F-02） |
| B3 pane 活性二维 | ⚠️ 矩阵有 pane 列；reviewer 维度有读路径（status 诊断行） | **遗漏**：writer-pane 维度无读路径（F-07）；"tmux session 整体死亡"第三态无矩阵行（F-07）；停滞阈值只给了一个例子未 pin（F-04） |
| B4 锁回收原子化 + last_seen 活性 | ✅ Task 0 rename-to-tombstone；活性=pid alive AND last_seen fresh（<3×interval）；双 claimer fixture | 忠实，但输家/重建失败退出码未 pin（F-11）；owner 文件 `last_seen_at` 字段名未 pin（F-19） |
| B5 mode 切换命令 + 漂移标记 | ✅ `mode RUN_ID human|auto`（锁内、终态 exit 2）、`Mode:` 行 + `⚠` 漂移标记 | 忠实，但漂移检查新增的 config 读取是未声明的 v0.4 行为变化（F-10）；"记录 actor"无处落盘（F-13）；`start --mode auto` 悬挂（F-05） |
| B6 relay 节流 | ✅ `--relay-after 30` 默认、`[autopilot]` 前缀、`last_relay_at`、`skipped (throttled)` | 忠实（矩阵 "idle" 措辞应改为 waiting_since 年龄，F-22） |
| B7 完成边界 | ✅ 能力承诺收敛 + 非承诺表（completed ≠ 交付） | 忠实 |
| 决策点 A：list 不加 MODE 列 | ✅ 列入 out-of-scope + v0.6 升级项；`--once` TSV 摘要含 mode 列 | 忠实 |
| 决策点 B：resume 默认 0 | ✅ `--resume-attempts N=0`、unconfirmed、仍 exit 6 | 忠实（计数语义未 pin，F-14） |
| 承诺收敛（auto=自动 approve + stop-and-alarm） | ✅ AC4/AC5/AC10 + 非承诺表 | 忠实，但 approve 冷却窗内的退出码未 pin（F-06） |
| 观测文件非权威 | ✅ autopilot.tsv/log best-effort、reason 实例 token 三元关联 | 忠实（行保留策略未 pin，F-16） |
| 扫描走 status oracle（exit 0/2/4/5） | ⚠️ AC7 采纳 | **核心契约漏洞**：exit code 不足以支撑矩阵所需分类（F-08/F-07）；status exit 1 未入映射（F-20） |
| `--repo` 白名单 | ✅ 默认当前 repo、`--all-repos` 显式 | 忠实（scope→repo_id 映射未 pin，F-21） |
| `--approve-delay` | ✅ 默认 300s、冷却窗口 | 忠实（窗内语义缺失，F-06） |
| intent 绑定 mode | ✅ AC3（intent 字段比较机制与 v0.4 一致，可扩展） | 忠实 |
| AC 命名空间 v05-ACn | ✅ | 忠实 |
| "50 节零改动"→断言更新清单 | ⚠️ AC11 采纳 | **清单不完整**：漏 manifest reader、status 读 config、verdict/pane 输出扩展（若采纳 F-08/F-07 方案 a）等（F-10/F-12 并入） |

**新增未裁定设计核查**：`--all-repos`、`autopilot-throttle.tsv`、`Mode:` 行、autopilot.log `mode`
action 行、"guard mismatch = error" 矩阵行均来自走查采纳清单或 B5/B2 的自然延伸，无越界新增。
唯一一处**凭空事实声明**：Drift 段称 "unknown rows were already tolerated in manifests" —— 与
`arena_read_manifest` 源码相反（见 F-01，严重）。

---

## 问题 2：spec 质量（Gate 1 标准）

### 2.1 v05-AC 可测性逐条

| AC | hermetic 可测？ | 缺口 |
|---|---|---|
| AC1 | 条件可测 | 需先定案 F-01（manifest reader 扩展）与 F-09（引号语法）；"legacy manifests 缺字段读为 human"需 fixture |
| AC2 | 条件可测 | F-10（status 读 config 的失败语义）、F-13（actor 落盘位置）；mode 在 live lock 下 exit 4 与既有命令 exit 1 不一致（F-23） |
| AC3 | ✅ 可测 | intent 写入/重试比较 fixture 与 v0.4 §10 同构 |
| AC4 | **不可测（当前）** | APPROVE+PASS 前提无法从 status oracle 获得（F-08）；窗内退出码未 pin 且 plan §51 与之矛盾（F-06）；plan §51 "第二次 --once 记 benign-race" 混淆 skip 与 benign-race（F-18） |
| AC5 | 条件可测 | 依赖 F-02（incomplete→5 还是 6）定案 |
| AC6 | 条件可测 | F-11（输家/重建失败退出码）、F-19（owner 字段名）；plan §53 "dead pid + fresh last_seen → live" 与 spec 的 AND 公式矛盾（F-17） |
| AC7 | **不可测（当前）** | "status oracle = exit codes 0/2/4/5" 无法区分 legacy / creation-intent 阶段 / incomplete transition / corrupt（同类 exit code 不同语义），也无法区分 APPROVE+PASS（F-08/F-20） |
| AC8 | 部分可测 | reviewer-pane escalate ✅（fake tmux `reviewer-dead` 已存在）；writer-pane dead 子句**不可测**（无读路径，F-07）；stall 子句**不可测**（无阈值，F-04） |
| AC9 | ✅ 可测 | `--relay-after 0` + 伪造 waiting_since + fake tmux send-keys 日志；节流窗断言可行 |
| AC10 | 条件可测 | cancel/reject 永不发出（可断言 autopilot.log 无对应 action）；`--resume-attempts` 计数语义未 pin（F-14） |
| AC11 | ✅ 可测 | 断言更新清单本身不完整（F-10/F-12 并入） |

**结论：11 条 AC 中 2 条当前不可测（AC4 前提、AC7），2 条部分不可测（AC8 的 writer-pane 与 stall
子句），其余需先定案 4 个契约点（F-01/F-02/F-06/F-09）。**

### 2.2 契约 pin 状态与开放问题（"实现时必然要再问一次"清单）

见 F-01、F-02、F-04、F-05、F-06、F-07、F-08、F-09、F-10、F-11、F-12、F-14、F-19、F-21。
字段/标志/默认值方面 pin 得好的：autopilot flag 表（interval 30 / approve-delay 300 /
relay-after 30 / resume-attempts 0）、退出码表、action 矩阵、autopilot.log result 枚举、
`--once` TSV 摘要 schema（与 log 同构）、`--actor` 枚举、manifest 行名、`.autopilot-lock` 位置。

### 2.3 v0.4 一致性（隐性破坏排查）

1. **F-01（严重）**：manifest 增 mode 行后，`arena_read_manifest` 对未知 key die →
   status/resolve/submit/validate/decision/escalate/relay/resume 全挂——除非同步扩展 reader；
   而 spec 声称 "unknown rows were already tolerated"（假），plan Task 1 的 Files 列表也没有
   `lib/common.sh`。**这是 plan 的硬缺口**：Task 1 实现必然打挂全量回归。
2. **F-10（主要）**：status 为显示 ⚠ 必须解析 project.conf（现状完全不读）；
   `arena_load_project_config` 严格模式在 config 缺失/非法时 die（exit 1）→ status 从"成功"
   变"失败"，是未声明的 v0.4 行为变化；AC11 断言清单与 Drift 段均未列。
3. **F-09（主要）**：spec 契约块与 plan fixture 写 `approval_mode=human|auto`（无引号），
   与 v0.4 严格解析器的 `key="value"` 正则矛盾——按 plan 的 fixture 写行，实现会 die。
4. **resolve approve 保留 reason**：默认路径（无 --reason 仍清空）与 v0.4 一致，既有 §48 断言
   （grep 型，未断言 reason_detail 为空）不受影响 ✅（这是本 spec 最干净的一处扩展）。
5. **F-11（主要）**：Task 0 锁回收改造的输家路径按 plan 草图走 `arena_die`（exit 1），
   spec 只 pin 了"重建失败 exit 4"；watch+cron 并发时输家 exit 1 会被 cron 当错误报警。
6. list 不受 manifest 新行影响（awk 直接解析，容忍未知行）✅；state 文件 16-key 契约不动 ✅。
7. 其余（`--actor` 默认 human、approve 默认清空 reason、list 列契约、status/list 退出码域）
   均无破坏 ✅。

---

## 问题 3：可行性（Bash 3.2 + fake CLI 环境）

1. **pane 活性二维在 fake tmux 下可靠可测**：fake tmux 已实现 `reviewer-dead`/`dead` 形态，
   `arena_find_live_pane`/status 的 pane 探测走 `tmux list-panes -F`，字段 5 置 1 即"死"。
   但 autopilot 的读路径必须定案：reviewer 维度可解析 status 诊断行（"reviewer pane: unreachable"），
   **writer 维度 status 不提供**（F-07）——需扩展 status 诊断行或允许 autopilot 直接探测，
   二选一后 fake tmux 均能支撑。
2. **--watch 常驻进程**：与 --once 共用扫描/动作代码，`--once` 已可覆盖矩阵全部行为；
   --watch 的循环/心跳刷新/锁 last_seen 更新需要一个有界运行 seam 才能确定性断言
   （建议 `ARENA_AUTOPILOT_MAX_SCANS` 环境变量或 `--max-scans N` 测试钩子，走查 QA-12 已提，
   spec 未采纳；plan §53 也只测 --once）。不加钩子也能用"后台起 watch --interval 1 + sleep + kill +
   断言日志行"的糙测，但会引入时序抖动，不符合本项目 hermetic 风格。
3. **时间类契约**：`--approve-delay 0/1`、`--relay-after 0` + 伪造 waiting_since/last_relay_at
   （既有 fixture 模式：直接写 state 文件与观测文件）完全可行；`last_seen` 新鲜度可伪造
   owner 元数据（需 F-19 pin 字段名）。
4. **Bash 3.2 兼容**：tombstone rename（`mv`）、`printf -v`、`[[ =~ ]]`、`date +%s` 均 3.2 可用；
   新代码无 eval、无 nameref 依赖；autopilot 循环用 `sleep` 无跨平台问题。可行。
5. **v05-AC11 回归**：现有 50 节断言形态已核对（grep 型 + key 解析型），除 F-01/F-10 外
   增量输出不会破坏既有断言；§29/§47 的 list 按列位置断言不受影响（list 未动）。

**结论：方向可行；但"status oracle 唯一读路径"若不加机器契约，AC7/AC8 无法写成确定性断言。**

---

## 发现清单（分级）

### 【严重】

- **F-01**（spec Drift/rollback 段 + plan Task 1）：**"unknown rows were already tolerated in
  manifests" 与源码相反**。`arena_read_manifest`（lib/common.sh）对未知 key fail-closed die。
  后果三重：(a) plan Task 1 按字面实现（start 写 mode 行，不改 common.sh）→ status/resolve/
  submit/validate/decision/escalate/relay/resume 全部在读 manifest 时 die，全量回归打挂；
  (b) rollback 承诺 "v0.5-written states remain readable by v0.4" 对 manifest 不成立——0.4.0
  读 mode 行即 die；(c) rollback 指引 "set approval_mode=human" 也不够——v0.4.0 严格解析器
  对 approval_mode 行（无论值）die，必须**删除该行**。必改：订正两处声明；plan Task 1 增补
  `lib/common.sh` reader 扩展（接受 `mode`/`mode_updated_at`，缺失默认 human）；明确 v0.4
  兼容策略（v0.4 打补丁容忍未知行，或 rollback 显式要求移除 mode 行）。
- **F-08**（AC4/AC7 + 矩阵）：**APPROVE+PASS 前提在"status oracle 唯一读路径"下不可得**。
  status 对非终态不打印 verdict/validation_result，退出码也不携带；autopilot 无法区分
  "approval_pending + APPROVE+PASS（应 approve）"与"approval_pending + 其他（guard
  mismatch = error）"——这正是矩阵要求区分的两行。同类问题：legacy（exit 0 但 stdout 标
  legacy）、creation-intent 阶段（exit 2/5 但应 skip）与 incomplete transition（exit 5 应
  alert）在纯 exit-code 映射下不可区分。必改：钉死机器可消费的 oracle 契约——方案 a：
  status 增补 verdict/validation_result/意图阶段/legacy 标记等输出行（grep 安全，列入 AC11
  清单）；方案 b：允许 autopilot act 阶段直读 run-state.tsv（AC7 措辞收窄）；方案 c：
  盲试 resolve + guard 兜底 + 失败重扫分类（需钉死分类规则）。三选一，配套断言。

### 【主要】

- **F-02**（AC5/矩阵 vs 退出码表）：incomplete 归属自相矛盾——退出码表 "5=incomplete/
  residue"，AC5 与矩阵 "corrupt/conflict/incomplete → error (exit 6)"。且与 B2 裁定
  （5=incomplete）冲突。按矩阵实现则 exit 5 永不可达。必改：钉死 status 各结果 →
  autopilot 退出码的映射表（建议：incomplete/residue→5；corrupt/conflict→6；intent
  阶段/legacy→skip；needs-human→6）。
- **F-04**（AC8 第三子句）：**停滞阈值未 pin**。"waiting longer than per-state defaults" 无
  任何默认值表（B3 只给了 review_pending>30min 一个例子），矩阵行无停滞维度，无配置 flag；
  changes_requested 何时从 relay 升级为 alert 也未定义。该子句当前不可测。必改：per-state
  默认阈值表 + 可配置项 + 矩阵停滞行。
- **F-05**（US2/信任模型 vs 契约段/plan）：`start --mode auto` 出现两次但从未定义（语法、
  与 config 的优先级、入 intent、漂移语义），plan 完全未实现。必改：钉死 flag 或删除提法。
- **F-06**（AC4 + plan §51）：approve 冷却窗内 approval_pending（auto 模式）的 `--once`
  退出码未 pin；矩阵语义（"after --approve-delay: resolve approve"）与退出码表
  （"0=no action needed"）指向 **0/deferred**，而 plan §51 fixture 断言 **exit 6**——两者
  矛盾；按 plan 实现会让 cron 在每次健康 run 的 5 分钟冷却窗内持续误报。必改：pin 窗内
  = deferred、聚合 0；plan fixture 订正。
- **F-07**（AC8 第二子句 + 矩阵）：**writer-pane 活性无读路径**。status 只诊断 reviewer
  pane；AC7 又 pin "status 为唯一读路径"。writer dead in changes_requested → alert 无法实现；
  "tmux session: not running" 第三态也无矩阵行。必改：扩展 status 诊断（writer 行 +
  会话行，列入 AC11）或允许 autopilot 直探 tmux；矩阵补会话死亡行。
- **F-09**（AC1 + 契约块 + plan §50）：approval_mode 语法未 pin：spec 示例与 plan fixture
  为无引号 `approval_mode=auto`，v0.4 严格解析器只收 `key="value"`。按 plan fixture 写行，
  解析器 die。必改：pin 为引号形式（与 init 输出一致）并同步 plan fixture。
- **F-10**（AC2/AC11）：status 漂移检查引入对 project.conf 的读取（现状不读）；严格解析在
  config 缺失/损坏时使 status 从成功变 exit 1——未声明的 v0.4 行为变化，AC11 断言清单未列。
  必改：pin 容错语义（缺失/非法 → 无 ⚠ 或警告，不 die；或显式声明 die 并列入清单）。
- **F-11**（AC6 + Task 0）：锁回收输家/重建失败退出码未 pin：spec 只 pin "重建失败 exit 4"，
  plan 草图两者都走 `arena_die`（exit 1）。watch+cron 并发下输家 exit 1 会被 cron 误报为
  错误。必改：rename 输家与重建失败统一 exit 4（defer），并在 Task 0 fixture 断言。
- **F-12**（"Live lock during action: defer"）：resolve/escalate 遇 live run lock 实际
  exit 1（`arena_lock_acquire` → `arena_die`），与"锁竞争应 defer 不报警"无法按 exit code
  区分。必改：钉死分类机制（解析 stderr 文本，或把 live-owner 竞争改为 exit 4——后者与
  v0.4 spec AC10 "contenders exit 4" 文本一致，可声明为对码的实现修正，§39 现断言
  `!= 0`，exit 4 兼容）。

### 【次要】

- **F-03**：autopilot 调 escalate 时 `last_transition_actor` 仍为 `human`（escalate 硬编码、
  无 --actor）。审计上靠 reason_detail 实例 token 关联（与 B1 裁定精神一致），但 spec 未
  显式声明，实现者可能擅自扩 --actor 造成契约漂移。建议 pin 一句。
- **F-13**：AC2 "records the switch (actor + timestamp)"——autopilot.log schema 无 actor 列，
  manifest 只有 mode/mode_updated_at；actor 无处落盘。建议 log schema 加 actor 列或改措辞。
- **F-14**：`--resume-attempts` 计数语义（per-run / per-instance、持久化位置、何时重置）
  未 pin。
- **F-16**：autopilot.tsv 每实例一行、无保留策略，崩溃实例行永久残留、文件无限增长。
- **F-17**：plan §53 "lock with dead pid but fresh last_seen -> live" 与 spec 活性公式
  （pid alive **AND** last_seen fresh）矛盾——按 spec，dead pid 恒可回收。plan fixture 描述
  需订正。
- **F-18**：plan §51 "second --once exits 0 with a benign-race log row" 混淆了 skip
  （completed 终态，矩阵=skip）与 benign-race（本应 approve 时发现他人已 completed 的竞态）。
  benign-race 需要"两次扫描之间由 human approve"的 fixture。
- **F-19**：autopilot lock owner 文件的 `last_seen_at` 字段名/格式未 pin（测试需伪造）。
- **F-20**：status exit 1（usage/missing manifest 等）未入 AC7 映射；应 pin 为 error 或 skip。
- **F-21**：`--repo` 默认"当前目录仓库"：cwd 非仓库时行为未定义；scope→repo_id 映射
  （`arena_repo_id`）未 pin。
- **F-22**：矩阵 "live, idle > relay-after" 的 "idle" 应改为 "waiting_since 年龄"（trace 已
  隐含，措辞易误导）。

### 【信息】

- **F-15**：--watch 无有界测试 seam（建议 `ARENA_AUTOPILOT_MAX_SCANS`），plan §53 只测
  --once。
- **F-23**：mode 命令 live-lock exit 4（spec pin）与 resolve 等既有命令 exit 1 不一致——
  新命令可如此，但实现须走 precheck（status 式）而非 `arena_lock_acquire`。
- **F-24**：v0.4 spec AC10 "contenders exit 4" 与 lock.sh 实现（live-owner exit 1）存在
  既有偏差，可在 v0.5 一并修正并更新 §39 断言（与 F-12 同源）。

---

## 问题 4：裁决投票

### 投票：**CONDITIONAL PASS**

理由：架构方向（状态机不动 + autopilot 外置编排 + opt-in 默认 human）、B1–B7 与决策点
A/B 的落地整体忠实、既有测试形态核对后增量输出安全（grep 型断言）、fake tmux 已具备
pane 活性测试的全部基础设施、Bash 3.2 可行性无虞。但存在 1 处**事实性错误声明**
（F-01，manifests 容忍性）、1 处**核心扫描契约不可实现**（F-08，APPROVE+PASS 无读路径）、
2 处 AC 子句不可测（F-04/F-07）及若干内部矛盾（F-02/F-06）与未 pin 契约（F-05/F-09/
F-10/F-11/F-12）——不修复直接进入 Task 0–5，实现必然返工或产出与 spec 矛盾的测试。
这些均为"定案即可开工"的钉死类问题，无方向性错误，故 CONDITIONAL 而非 FAIL。

### 必改项（阻塞级，11 项）

1. **F-01**：订正 "unknown rows were already tolerated in manifests" 错误声明；plan Task 1
   增补 `lib/common.sh` 的 manifest reader 扩展（接受 mode/mode_updated_at、缺失默认
   human）；订正 rollback 承诺（0.4.0 读 v0.5 manifest/config 均 fail-closed，需明确
   兼容补丁或回滚操作步骤）。
2. **F-08**：钉死 status oracle 机器契约（verdict/validation_result/legacy/intent 阶段
   的可消费输出行，或允许 act 阶段直读 run-state.tsv，或盲试+重扫分类协议），修正
   AC7 措辞。
3. **F-07**：钉死 writer-pane / session 死亡维度的读路径（扩展 status 诊断或直探 tmux），
   矩阵补 "tmux session: not running" 行。
4. **F-04**：钉死 per-state 停滞默认阈值表 + 可配置项 + 矩阵停滞行。
5. **F-02**：订正 incomplete 的退出码矛盾（AC5/矩阵 vs 退出码表），给出 status 结果 →
   autopilot 退出码全映射。
6. **F-05**：钉死 `start --mode auto`（语法/优先级/intent/漂移）或删除该提法。
7. **F-09**：钉死 approval_mode 配置语法（引号形式），同步 plan §50 fixture。
8. **F-10**：钉死 status 漂移检查的 config 缺失/损坏语义；补入 AC11 断言更新清单。
9. **F-11**：钉死锁回收输家/重建失败退出码（exit 4），Task 0 fixture 断言。
10. **F-12**：钉死 action 阶段 live run-lock 的分类机制（stderr 解析或 live-owner 竞争
    改 exit 4 + §39 断言更新）。
11. **F-06**：钉死 approve 冷却窗内 `--once` 退出码（建议 0/deferred），订正 plan §51
    fixture。

### 建议项（非阻塞）

F-03（escalate actor 声明）、F-13（autopilot.log actor 列）、F-14（resume 计数语义）、
F-15（--watch 测试 seam）、F-16（观测文件保留策略）、F-17（plan §53 活性描述订正）、
F-18（plan §51 benign-race fixture 设计）、F-19（last_seen_at 字段名）、F-20（status
exit 1 映射）、F-21（scope→repo_id 映射）、F-22（"idle"措辞）、F-23/F-24（mode/既有
命令锁竞争退出码一致性，可借机修正 v0.4 spec 与实现偏差）。

### 最关键 1 个问题

**F-08：扫描契约的核心断点** —— spec 把 "status oracle（exit codes 0/2/4/5）为唯一读路径"
与"approval_pending 需判定 APPROVE+PASS 才 approve"同时 pin 死，但 v0.4 status 对非终态
既不输出 verdict/validation_result、退出码也不携带，writer-pane 活性与意图阶段/legacy
区分同样不可得；不先定案"autopilot 到底能读到什么"，AC4/AC7/AC8 无法写成确定性 hermetic
断言，任何实现选择（扩 status 输出 / 直读状态文件 / 盲试 guard）都会触碰"零漂移"承诺，
必须在 Gate 1 关闭。
