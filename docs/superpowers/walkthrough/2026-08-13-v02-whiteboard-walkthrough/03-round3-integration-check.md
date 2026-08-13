# Round 3 — 集成与错误矩阵

## 3.1 端到端场景矩阵

| # | 场景 | 预期路径 | 结果 |
|---|------|----------|------|
| E1 | 干净项目，pi-cursor，完整一轮：init→start→写→commit→submit→validate→decision APPROVE→relay | 全链路 | ✅ 实测通过（含真实 tmuxp/离线两种模式）；决策 relay 失败时降级为 note |
| E2 | 同一轮次第二轮 checkpoint（CHANGES_REQUESTED → 修复 → 再 submit） | submit-2 → 新快照 `review-<sha2>` → validate-2 → decision-2 | ✅ 流程正确；⚠️ status 指针在 validate-2 前仍指向第一轮（F2） |
| E3 | 每 profile 一轮（codex/opencode/gemini） | 同 E1，适配器参数不同 | ✅ hermetic 测试全覆盖（§17/§19/§21/§22/§23）；真实 provider 未跑（Gate 4 开放项） |
| E4 | 会话运行中，writer 从 pane 内 submit | 环境刷新 + reviewer pane respawn → Cursor 进入 review 阶段 | ⚠️ 依赖 reviewer pane 恰好 live（F1）；pane 死亡/初始化中 → 命令失败但状态已提交 |
| E5 | 会话关闭后 submit/validate/decision | 全部离线完成（无 respawn/relay） | ✅ 实测通过 |
| E6 | 快照被外部篡改（改文件/改 policy/改 wrapper/换 HEAD） | validate/decision 拒绝；status 无感 | ✅ validate/decision fail-closed（hash+status+HEAD 三重校验）；⚠️ status 不报（F4） |
| E7 | review worktree 被删除 | submit/start 均失败，无自愈 | ❌ F3 实锤：git raw error + preflight 死锁，需手工 `git worktree prune` |
| E8 | writer 在评审期间提交新 checkpoint | decision 拒绝旧 HEAD（正确 fail-closed） | ✅ 但评审者无法记录对旧 checkpoint 的 CHANGES_REQUESTED（F10 约束） |
| E9 | 多仓库同名 run_id | run 隔离（repo_id 含路径哈希） | ✅ 测试 §14 |
| E10 | legacy v0.1 manifest（无 profile 字段） | 解析为 pi-cursor，`pi-session` 目录兼容 | ✅ 测试 §18 |
| E11 | 未知 profile / 缺失 writer / 缺失 Cursor | 任何状态创建前失败 | ✅ 测试 §16；real-world 亦验证 |
| E12 | Gemini 首次启动失败 / 被中断 | marker 不发布 → 下次仍为首次会话 | ✅ 测试 §23；SIGKILL 残留临时文件（F9） |
| E13 | 项目 checkpoint 跟踪 `.cursor/cli.json` | submit 拒绝（防策略叠层不可证） | ✅ 测试覆盖；fail-closed 正确 |
| E14 | 脏集成树 / 脏 writer 树 / 无初始 commit / 分支已存在 | start/submit 拒绝 | ✅ 测试 §3/§4/§5 |
| E15 | 恶意 project.conf（绝对路径/`../`/未知键） | validate 拒绝 | ✅ 代码路径：config 严格解析 + 路径约束 |

## 3.2 错误处理矩阵

图例：🟢 fail-closed 且信息清晰；🟡 fail-closed 但信息误导/可恢复性差；🔴 不 fail-closed 或状态已变。

| 命令 | 错误条件 | 行为 | 级别 |
|------|----------|------|------|
| 全部 | 未知命令/未知选项/参数缺失 | usage + die | 🟢 |
| doctor | 缺 git/tmux/tmuxp/cursor/全部 writer | 缺失列表 + exit 1 | 🟢 |
| init | 非 git 根/已存在 config | 拒绝覆盖 | 🟢 |
| start | 脏集成树/无 HEAD/分支冲突/路径存在/缺 CLI/profile 不匹配 | 全部先于状态创建拒绝 | 🟢 |
| start | tmuxp before_script 失败（preflight） | fail-closed，但泄漏 Python traceback（F11） | 🟡 |
| start | review.tsv 指向已删快照 | preflight die，无恢复路径（F3） | 🔴 |
| submit | writer 脏/无新提交/非 base 后代/跟踪门文件 | 干净拒绝 | 🟢 |
| submit | **快照已建后** reviewer pane 非 live | **exit 1，但状态已提交**（F1） | 🔴 |
| submit | review worktree 被删 | raw git 错误（lost but registered），无自愈（F3） | 🔴 |
| validate | 无 review.tsv/HEAD 漂移/快照脏/策略哈希不符/脚本不可执行 | 全部拒绝，报告不写（或写 FAIL） | 🟢 |
| decision | 非法 verdict/超长文本/快照不完整/报告缺失或未绑定/APPROVE 无 PASS/重复决策/writer 越位 | 全部拒绝且不写决策 | 🟢 |
| decision | relay 失败 | note + **exit 0**（决策仍持久化） | 🟢 |
| relay | 会话不在/无唯一 live pane/消息超长/控制字符 | die；decision 内调用被降级为 note | 🟢 |
| status | run 不存在 | die | 🟢 |
| status | 快照被篡改/指针陈旧 | **照常显示**（F2/F4） | 🔴 |

**模式总结**：🟢 14 项（核心门路径全部 fail-closed 且状态原子）；🟡 1 项；🔴 4 项，全部集中在 submit 的 pane 耦合、快照删除恢复、status 审计展示。`decision` 对 relay 的优雅降级是正确范式，`submit` 未沿用。

## 3.3 一致性检查（spec ↔ 实现 ↔ 测试）

| 检查项 | 结论 |
|--------|------|
| AC→测试映射 | 10/10 有对应测试段；§1–§25 全绿（2026-08-13 基线） |
| 适配器危险 flag 禁令 ↔ prompt 文本 | 一致：submit/relay 指令、禁止列表逐 profile 对齐 |
| 门策略 allow/deny ↔ wrapper 白名单 | 一致：wrapper 仅放行 status/validate/decision/relay，且均被 policy 允许 |
| manifest 字段 ↔ 模板环境变量 ↔ preflight 校验 | 一致：13 字段全部导出、全部核对 |
| 快照完整性三重绑定（HEAD/hash/status）↔ review.tsv | 一致：validate/decision/preflight/pane 四处共用同一函数 |
| README 宣称 ↔ 实现 | 宣称"Cursor 唯一正式门"超出实现能力边界（F5）；宣称"审查快照不可变"成立 |
| 测试隔离性 | 全部 hermetic（fake CLI/tmp 仓库/私有 tmux socket），无模型/网络调用 ✅ |
| 版本/打包 | VERSION 0.2.0 ↔ dist tarball ↔ `version` 命令一致；packaging 测试通过 |

## 3.4 Round 3 结论

1. **门路径（submit→validate→decision）的审计正确性闭环成立**：任何篡改或顺序违规都会在 validate/decision 被拒绝；relay 失败不影响决策持久化。这是设计最坚实的部分。
2. **操作性缺陷集中且可修**：F1（pane 耦合致命化）、F3（无自愈）都是 submit 的边界问题，修复成本低；F2/F4 是 status 的审计展示问题，修复成本低。
3. **威胁模型（F5）需要写进规范**：同 UID 本地工具的"唯一门"是角色声明而非能力声明，应显式记录，避免 README 过度承诺。
4. **Gate 4（真实 Cursor 认证 smoke）仍为发布前置**，与本次走查互不替代：走查验证的是 Arena 自身行为，Gate 4 验证的是 Cursor CLI 对门策略的遵守。
