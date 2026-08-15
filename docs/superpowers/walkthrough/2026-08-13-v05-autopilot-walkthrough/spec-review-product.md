# v0.5 Autopilot Approval Modes — Gate 1 第二轮评审（product 角色）

> 评审人：product（产品与工作流专家）
> 评审对象：`docs/superpowers/specs/2026-08-13-autopilot-approval-mode.md`（正式 spec）
> 配套：`docs/superpowers/plans/2026-08-13-autopilot-approval-mode.md`、`00-findings-summary.md`、v0.4 spec、`lib/*.sh` 源码、`tests/run.sh`
> 核实方法：逐条核对 spec 与 findings 裁定；对 v0.4 源码（resolve.sh/lock.sh/config.sh/status.sh/state.sh/relay.sh/common.sh/start.sh/arena.sh）与测试 harness（grep 式断言、fake tmux 能力）做了原文级验证。

## 总体结论

**方向正确、裁定吸收率高，但契约层存在 10 项阻塞级缺口**。B1–B7 与决策点 A/B 的裁定绝大多数被忠实落地（已对源码逐条验证：`system`/`resolve-approve` 确在 v0.4 枚举内、approve 分支确清空 reason_detail、lock.sh 确为 rm -rf+mkdir 竞态、manifest 读取器对未知行确实 fail-closed、status 确实不输出 verdict/VR/last_transition_at）。但 spec 自身出现新的自相矛盾（exit 5/6、矩阵缺停滞维度、US2 与部署矩阵冲突），以及"status 为唯一读入口"与 AC4 所需数据不可兼得的硬缺口。**这些是契约 pin 死问题，不是方向性错误**，故投 CONDITIONAL PASS。

---

## 问题 1：裁定忠实度（逐条核对）

### B1–B7 与决策点 A/B 核对表

| 裁定 | spec 落地 | 判定 |
|---|---|---|
| B1 actor=system + reason 透传（零契约变更） | resolve 增 `--actor`（默认 human）、approve 保留 `--reason`；已核实 state.sh 枚举含 system、action=resolve-approve；T10 的 RD 清空改为"有条件保留" | ✅ 忠实（RD 语义是有意 delta，已声明；核实无 v0.4 测试向 approve 传 --reason，零破坏） |
| B2 exit 6 新码 + 聚合优先级 | autopilot 专属协议 0/4/5/6、优先级 6>5>4>0 | ⚠️ 部分走样：5 的触发条件与 AC5/矩阵互相矛盾（见必改 M2） |
| B3 pane 活性二维 | 矩阵含 pane 列；reviewer dead→escalate、writer dead→alert | ⚠️ 部分走样：停滞维度只出现在 AC8 文本、矩阵无停滞行且阈值未 pin（M3）；writer pane 活性无 oracle 来源（M1） |
| B4 锁回收原子化 | rename-to-tombstone + last_seen + 双实例 fixture；核实 v0.4 确为 rm -rf+mkdir 竞态 | ✅ 忠实（细节见建议 S3/S4：重建失败退出码、fixture 非真并发、tombstone 无 GC） |
| B5 mode 切换命令 + 漂移标记 | `mode RUN_ID human|auto`（run lock、terminal 拒绝、autopilot.log 审计行）、status `Mode:` + ⚠ 漂移 | ✅ 忠实（漂移只在 status 展示，list 不加——与决策点 A 一致；findings B5 原文提"status/list"，建议在 spec 显式说明该取舍，见信息 I1） |
| B6 relay 节流 | last_relay_at + `--relay-after 30` 分钟 + `[autopilot]` 前缀 + skipped (throttled)；已核实 relay --from 枚举不变 | ✅ 忠实（节流状态文件 schema 只在 plan、不在 spec，见建议 S1） |
| B7 完成边界 | capability promise（auto=APPROVE+PASS 自动完成 + 其余 stop-and-alarm）+ 非承诺表 + 信任模型降级说明 | ✅ 忠实 |
| 决策点 A：list 不加列 | list 行契约不动；`--once` TSV 含 mode 列；v0.6 显式 contract 升级项 | ✅ 忠实 |
| 决策点 B：resume 默认 0 | `--resume-attempts` 默认 0、unconfirmed + 仍 exit 6 | ✅ 忠实 |
| 承诺收敛 | "自动完成 + stop-and-alarm，不自愈"入 normative capability promise | ✅ 忠实 |
| 观测文件非权威 | autopilot.tsv/autopilot.log 明示 best-effort；审计链=run-state + SHA 归档；reason 带实例 token 三元关联 | ✅ 忠实 |
| 扫描走 status oracle | AC7 写入"唯一读路径" | ⚠️ **不可实现**（M1）：status 输出不含 AC4 需要的 last_transition_at/verdict/VR，也不含 writer pane 活性 |
| --repo 白名单 | `--repo PATH`（默认 cwd）/`--all-repos`（显式、记录 scope） | ✅ 忠实（PATH→repo_id 映射未 pin，见建议 S7） |
| --approve-delay | 默认 300s、decision→approve 最小间隔 | ⚠️ 冷却窗口内退出码未 pin 且 plan 测试 pin 成 6（M6）；锚点时间戳无 oracle（M1） |
| intent 绑定 | AC3：mode 入 T1r derived inputs、重试 fail-closed | ✅ 忠实（已核实 start.sh intent 校验机制可扩展） |
| AC 命名空间 v05-ACn | 采用 | ✅ 忠实 |
| "50 节零改动"→"零语义漂移+断言更新清单" | AC11 声明 50 节回归 + 更新清单 | ⚠️ 清单声明存在但实际未记录（建议 S6） |

### 裁定忠实度总评

- **无方向性走样**：全部 7 条阻塞级裁定与 2 个决策点均被吸收，且多处经源码验证属实。
- **发现 2 处 spec 内部新增矛盾**（非走查来源）：exit 5/6 冲突、US2 与部署矩阵冲突。
- **发现 1 处事实性错误**：drift 节称"manifest 未知行已被容忍"——`common.sh` 的 `arena_read_manifest` 对未知 key 执行 `arena_die`（fail-closed）。该错误直接破坏 spec 的 rollback/降级叙事（M9）。
- **新增未裁定设计 3 处**：`autopilot-throttle.tsv`（plan 引入、spec 未定义 schema，S1）、resume 尝试计数簿记位置未定义（S1）、`--watch` stdout 行为未 pin（M7）。

---

## 问题 2：spec 质量（gate 1 标准）

### 2.1 每条 v05-AC 的可测性

| AC | hermetic 可测？ | 说明 |
|---|---|---|
| AC1 | ✅ | §50：严格解析器、manifest 快照、legacy manifest 缺字段读 human |
| AC2 | ✅ | §50：切换（需补"锁被占用→exit 4"与"terminal→exit 2"两个小 fixture） |
| AC3 | ✅ | §50：intent 含 mode、改配置重试→exit 2 |
| AC4 | ⚠️ 依赖 pin 死 | 需先解决 M1（时间锚点来源）与 M6（冷却窗口内退出码） |
| AC5 | ✅ | §52：zero-mutation 可用"run 目录文件清单前后 cmp"（v0.4 已有同款手法）；exit 6 各形状可造 |
| AC6 | ✅（fixture 需改进） | 见建议 S4：plan 的双回收 fixture 是顺序执行，当前代码下未必先红 |
| AC7 | ⚠️ 依赖 pin 死 | "status 唯一读入口"是设计约束，行为可测（defer 不计数、skip legacy/intent），但"怎么拿到 pane/时间数据"未定（M1） |
| AC8 | ⚠️ 依赖 pin 死 | fake tmux 的 `FAKE_TMUX_PANES=reviewer-dead|dead` 已具备 pane 死模拟能力；停滞阈值未 pin（M3） |
| AC9 | ✅ | fake tmux send-keys 日志可断言一条/节流后 skipped-throttled |
| AC10 | ✅ | §52：断言无 cancel/reject（状态与日志）、resume 默认 0（fake respawn 日志为空） |
| AC11 | ⚠️ 清单缺失 | 见建议 S6 |

**结论：无不可测的 AC，但有 3 条 AC 的测试在契约 pin 死前无法编写**（AC4/AC7/AC8）。这与 M1/M3/M6 一致。

### 2.2 契约无歧义性

已 pin 死：flags/默认值/退出码/文件 schema/结果枚举/优先级。未 pin 死（实现时必然要再问）：

1. **status oracle 数据缺口**（M1）：AC4 需要 last_transition_at（approve-delay 锚点）与 verdict/VR 判别；AC7 规定 status 为唯一读入口。但 status.sh 只输出 prose 诊断（party/reason/waiting_since/reviewer-pane 活性），**不输出** verdict（非 terminal）、validation_result、last_transition_at、writer pane 活性、legacy/intent 判别（仅靠 exit code 无法区分 S3/S4 的 2 与 corrupt 的 2）。已核实。
2. **exit 5/6 三处矛盾**（M2，见下）。
3. **停滞阈值未 pin**（M3）：AC8 说"per-state defaults"，全文无默认值表、无配置 flag。
4. **`start --mode auto` 只出现在 US2 文本**（M5）：命令面/契约节均无该 flag。
5. **冷却窗口内退出码**（M6）：spec 未 pin，plan §51 测试 pin 成 exit 6。
6. **`--watch` 的 stdout/告警呈现**（M7）：spec 只定义了 `--once` 的 stdout TSV。
7. **锁活性 "3×interval" 的 interval 归属**（M8）。
8. **approval_mode 语法形式**（S5）：spec 契约示例为无引号 `approval_mode=human|auto`，现有 parser 只接受 `key="value"` 引号形式，plan §50 测试以无引号追加并断言 `approval_mode=human`；引号/无引号、重复行（last-wins?）、注释格式均未 pin。
9. **`--repo PATH`→repo_id 映射、cwd 非仓库行为、legacy run 上 `mode` 命令行为、status 读不到 project.conf 时漂移显示**（S7/S8）。

### 2.3 v0.4 一致性（隐性破坏排查）

已逐项核实 tests/run.sh（50 节 0–49 连续）与 cli-contract-smoke.sh：

- 断言全部为 `grep -Fq`（require_match/require_no_match）或 `cmp` 证据文件/`wc -l` 状态文件 16 键；**无任何对 project.conf 内容、manifest 行数/全量、status 全量输出、usage 文本的断言**。
- 三处增量（config 新 key、status `Mode:` 行、manifest 新行）对 §0–49 **零影响**——前提是实现时保持"其他未知行/未知 manifest key 仍 fail-closed"（AC1 与 plan §50 已覆盖）。
- `resolve --actor` 默认 human → v0.4 测试零影响；approve+reason 保留 → 核实无 v0.4 测试向 approve 传 reason。
- **但**：spec drift 节"unknown rows were already tolerated in manifests"是**事实错误**——`arena_read_manifest` 遇未知 key 直接 die。后果：**v0.4 二进制无法读取任何 v0.5 写入的 manifest**（mode 行致命），rollback 节"no state migration is needed"的降级叙事不成立（M9）。
- 锁回收原子化对现有测试行为兼容（单回收者路径不变）；`status` 的 `Mode:` 行在 lock/intent/repair 优先级检查之后打印——**注意**：v0.4 status 在 corrupt/conflict 时 exit 2 且不打印诊断，`Mode:` 行应放在 `Run:` 头部区（plan 未指定行位置，属实现细节，信息级）。

### 2.4 承诺边界（product 视角）

- ✅ 完成边界、非承诺表、信任模型降级声明均清晰且 normative。
- ⚠️ **US1 "only observes and alerts" 与矩阵 human 模式 relay 行冲突**（S2）：human 模式也会发 relay 提醒（tmux send-keys 是真副作用，B6 裁定即为此）。建议在承诺/非承诺节显式写"human 模式唯一副作用=节流后的 relay 提醒"。
- ⚠️ **US2 的"watch + 离开 + exit 6 分页"在部署矩阵下不成立**（M7）：watch 永不退出 → 无退出码可分页；而 cron --once 与 watch 因 autopilot 锁互斥（--once exit 4）。US2 是无人值守的主用户故事，必须与部署矩阵对齐。

---

## 问题 3：可行性（Bash 3.2 + fake CLI）

- **pane 活性测试**：✅ 可行。tests/run.sh 的 fake tmux 已支持 `FAKE_TMUX_MODE=relay|live` + `FAKE_TMUX_PANES=reviewer-dead|dead|normal`（第 5 列 dead flag），`send-keys` 有独立日志——reviewer dead→escalate、writer dead→alert、relay 节流三条路径均可造。**前提是** M1 解决"autopilot 通过什么通道读 pane 活性"（直接 tmux 探测 or status 扩展）。
- **--watch 常驻进程**：⚠️ 可行但 plan 无任何 fixture（M10）。建议：后台启动 `--watch --interval 1` + sleep + kill + 断言 autopilot.tsv 心跳行/last_seen 刷新/锁被下一实例原子回收；**不要用 `timeout`**（macOS Bash 3.2 无 GNU timeout），用 `&` + kill + EXIT trap 清理。
- **Bash 3.2 兼容**：✅ plan 代码片段（mv/rm/mkdir/printf/[[ ]]）与现 lib 风格一致；⚠ 字符按 UTF-8 字节处理无问题；`stat -c/-f` 双分支惯例已在 lock.sh 有先例。
- **Task 0 fixture**：⚠️ plan 的双回收测试是**顺序**执行（claim-a 成功后再 claim-b），当前代码下 claim-b 会因 owner-alive 走 die 路径而"正确失败"——**该测试在修复前未必变红**，TDD 循环可能空转（S4）。需要真并发（两个子 shell 并行 + 屏障）或高迭代竞态循环。
- **cron 部署**：--once 循环依赖外部 cron；测试无需模拟 cron。

---

## 问题 4：裁决投票

**CONDITIONAL PASS** —— 架构（状态机不动 + 外部编排 + opt-in）经源码验证成立，B1–B7/A/B 裁定吸收忠实，无方向性错误；但契约层有 10 项必改，其中 2 项（M1/M2）使 AC4/AC7 当前不可实现，1 项（M6）会破坏无人值守主场景的告警语义。

### 必改项（阻塞级，10 项）

- **M1【严重】status oracle 数据缺口**：AC4 的 approve-delay 锚点（last_transition_at）与 APPROVE+PASS 判别、AC8 的 writer pane 活性，status 输出均不提供；AC7"status 为唯一读入口"与 AC4 不可兼得。必须在 spec 中 pin 死一种方案并列出其对"零漂移"声明的影响：
  - 方案 A（推荐）：锚点改用 waiting_since 并显式论证（T6/T6r 对 approval_pending 同时置 WS 与 last_transition_at，二者恒等；legacy 已跳过）；verdict/VR 由状态不变量保证（approval_pending ∧ status 0 ⇒ APPROVE∧PASS，违反即 corrupt→2→error）；pane 活性（含 writer）与 legacy/intent 判别允许 autopilot 直接调 `arena_find_live_pane`/意图文件探测（对"唯一读入口"做显式 carve-out：唯一读入口=run 状态，pane/意图属观测）。
  - 方案 B：给 status 加机器可读状态行（需把该输出变化计入 v0.4 断言更新清单）。
- **M2【严重】exit 5/6/跳过三处矛盾**：AC5 与矩阵说"corrupt/conflict/incomplete（status 2/5）→ error（exit 6）"；退出码表说"5=incomplete/residue"；AC7 说 intent 阶段跳过。三种 status-5 形态（creation intent S1/S2/S5/S6、repair intent、transition residue）与 S3/S4（status 2）各自映射到"跳过/5/6"必须逐一 pin 死；若 5 无触发场景应删掉该行（聚合测试 6>5>4>0 需要能造出 5 的 fixture）。
- **M3【主要】停滞维度缺失**：AC8 的停滞报警在矩阵中无任何行（live+停滞仍显示 observe）；per-state 阈值（如 review_pending>30min）全文未 pin、无配置 flag。给出 状态→阈值 表（或统一 `--stall-after` 之类 flag）并补矩阵行。
- **M4【主要】矩阵完整性**：`blocked/reviewer_unreachable` + pane **live**（人工 resume 后未 recover）落入"未列状态→observe"，与 AC5"blocked→exit 6"矛盾；session 整体 absent 是否等同 pane dead（决定是否 escalate）未定义。逐格补齐并显式声明"未列状态=observe"的例外（blocked 全形态恒 needs-human）。
- **M5【主要】`start --mode auto` 缺失**：US2 引用了该 flag，但 Mode 配置契约节、命令面、AC1 均无；security S1 裁定的"run 级显式 opt-in"落空。补 flag 契约（含 intent 绑定、与 config 冲突时的优先级）或从 US2 删除。
- **M6【主要】冷却窗口内退出码**：plan §51 测试 pin 为 exit 6，与协议表"6=至少一个 run 需要人"语义直接冲突——auto 模式冷却中的 run 不需要人，cron 会对每个 decision 误报一次寻呼，破坏"无人值守"承诺。pin：冷却中=exit 0 + 日志 `deferred (cooling)`；仅超时未获批（异常）才报警。
- **M7【主要】US2 与部署矩阵矛盾**："watch + 离开 + 靠 exit 6 分页"不成立（watch 不退出、与 cron --once 锁互斥）。统一叙事：无人值守=cron --once（US2 改写）；同时 pin `--watch` 每轮是否向 stdout 打 per-run TSV（建议打，供 attended 观察）。
- **M8【主要】锁活性 "3×interval" 归属**：若以声称者自己的 interval 判定，watch `--interval 300` 会被默认 90s 新鲜度的 cron --once 误回收（pid 活但 last_seen 旧），破坏 AC6 单实例。pin：owner metadata 记录自身 interval，新鲜度用 **owner 的** 3×interval 判定。
- **M9【主要】manifest 未知行容忍的事实错误**：`arena_read_manifest` 对未知 key fail-closed，v0.4 二进制读不了 v0.5 manifest。修正 drift 节表述，并在 rollback 节写明：降级 v0.4 二进制需先剥离 manifest 的 mode 行（或明确不支持二进制降级、仅支持"v0.5 二进制 + human 模式"回退）。
- **M10【主要】--watch 零测试覆盖**：§50–53 全部 --once；默认模式（watch）的心跳刷新、锁活性、exit-4 竞争无 hermetic 测试。补一个有界后台 fixture（`&` + sleep + kill，EXIT trap 清理；避免 GNU timeout）。

### 建议项（非阻塞，9 项）

- **S1**：`autopilot-throttle.tsv`（run_id/reason/last_relay_at）与 resume 尝试计数簿记位置写入 spec 观测文件 schema 节（plan 与 spec 不一致）。
- **S2**：承诺/非承诺节显式写"human 模式唯一副作用=节流后的 relay 提醒"（消解 US1"只观测"与矩阵 relay 行的表面矛盾）。
- **S3**：锁重建失败退出码对齐——spec 说 4，plan Task 0 代码 `arena_die` 实际 exit 1。
- **S4**：Task 0 双回收 fixture 改真并发（并行 claimer + 屏障），保证修复前必红。
- **S5**：pin approval_mode 语法形式（引号/无引号、重复行 last-wins、注释格式），使 plan §50 的 `printf 'approval_mode=auto
' >>` 追加写法与严格解析器语义一致。
- **S6**：AC11 承诺的"断言更新清单"实际未记录（spec 说在 plan，plan 只列了 3 个类别）——补一份具体清单（我核实的结果是：§0–49 实际无需改任何断言，只需在清单中记录"已核对、零改动"及理由）。
- **S7**：pin `--repo PATH`→repo_id 的映射规则（git root？basename？）、cwd 非仓库时 --once 的失败行为（建议 exit 1 + 明确报错）。
- **S8**：`mode` 命令在 legacy run（无 manifest mode 行）上的行为；status 读不到 project.conf（被删/移走）时漂移显示策略。
- **S9**：tombstone（`.reap.*`）GC 策略（建议：新获得者顺手清扫同名前缀旧 tombstone，或文档化为良性残留）。

### 信息（4 项）

- **I1**：B5 原文"status/list 显示漂移"与决策点 A 的取舍——spec 只做 status，与 A 一致且合理，建议在 spec 显式写一句"list 不显示漂移"以免二义。
- **I2**：矩阵行"approval_pending, other → guard mismatch=error"对合法状态不可达（状态不变量保证 approval_pending⇒APPROVE∧PASS，违反即 corrupt→2→error 行）；无害，但建议标注为防御性死代码。
- **I3**：`--relay-after`（分钟）与 `--approve-delay`（秒）单位不对称——遵循走查裁定（默认值 pin），建议 usage 文本加单位后缀。
- **I4**：v0.4 创建的 creation intent 由 v0.5 start 重试：intent 无 mode 字段 → 校验 mismatch → fail-closed exit 2；行为安全但应在 T1r 文档注明升级期该路径。

---

## 给实现的一句话

先修 M1/M2（oracle 数据通道 + exit 5/6 映射），再写 §51/§53 测试；§50 可先行。其余必改项均为文本级 pin 死，工作量小但缺一不可。
