# Round 1 — 用户故事与验收标准走查

对 v0.2 规格（`docs/superpowers/specs/2026-08-13-pluggable-writer-adapters.md`）的 5 个用户故事与 10 条 AC 逐条核对实现与测试。

## 1.1 用户故事核对

| # | 故事 | 实现路径 | 状态 |
|---|------|----------|------|
| S1 | 操作者可在不启动模型的情况下发现本地可用的 writer profile | `doctor`：probe 全部适配器 + Cursor，输出 profile 矩阵；`start` 在创建任何状态前 probe | ✅ 覆盖（tests/run.sh §1, §16） |
| S2 | 可用一个选定的 writer 启动命名 run（如 `start tui-sink --profile codex-cursor`） | `start`：profile 解析（封闭映射）→ probe → 干净集成树 → writer 专属分支/worktree → manifest → tmuxp | ✅ 覆盖（§4, §17） |
| S3 | writer 只收到自己的隔离 worktree、run 上下文、checkpoint 命令、直接 relay 命令；绝不收到审批绕过 flag | 适配器 launch 参数固定；`assert_no_dangerous_writer_flags` 校验 11 个危险 flag；prompt 注入 run/命令上下文 | ✅ 覆盖（§21, §24） |
| S4 | Cursor 门收到 writer 的确切提交 checkpoint，保留现有验证与 SHA 绑定决策控制 | `submit` → detached 快照 + 门策略 + wrapper；validate/decision 完整性校验 | ✅ 覆盖（§5–§12, §19） |
| S5 | 审计者可从不可变 run manifest 与 relay 标签识别所选 writer | manifest 的 profile/writer_adapter/writer_label；relay 用 `[Label]` 前缀 | ✅ 覆盖（§17, §20） |

**故事层缺口**：S5 的"审计者"体验不完整——`status` 不做完整性校验（见 F4）、新 checkpoint 提交后指针陈旧（见 F2）。审计真值（归档文件）正确，但 status 展示会误导。

## 1.2 AC 核对

| ID | 验收标准 | 实现 | 测试 | 状态 |
|----|----------|------|------|------|
| AC1 | doctor 报告 Cursor + 每个检测到的 writer，只列出所需 CLI 存在的 profile | doctor.sh probe 矩阵 | §1, §16 | ✅ |
| AC2 | 每个 profile 选择自己的 writer 适配器，记录 profile/adapter/label，用 writer 专属分支命名空间 | 封闭 profile 映射 `arena_profile_branch`（`agent-arena/<adapter>/<run_id>`）；manifest 13 字段 | §17 | ✅ |
| AC3 | 未知 profile 或缺失 writer 在创建 worktree/tmux 会话**之前**失败 | `start`：解析→probe→才 `worktree add`；resume 路径同样二次 probe | §16 | ✅ |
| AC4 | 每个 writer 适配器在隔离工作区启动，带固定安全 prompt，无 force/yolo/绕过 flag | 适配器 launch 参数 + prompt 模板；`assert_no_dangerous_writer_flags` | §21 | ✅ |
| AC5 | writer pane 分发 manifest 记录的适配器；tmux 角色/模式与 relay 安全不变 | pane.sh writer 分支读 manifest 后 `exec <adapter>.sh launch`；relay 唯一 live pane 约束 | §24, §20 | ✅ |
| AC6 | 无 v0.2 profile 字段的旧 manifest 解析为 `pi-cursor` | `arena_read_manifest` profile_field_count==0 分支（`pi-session` 目录兼容） | §18 | ✅ |
| AC7 | 提交/验证/决策绑定所选 writer 的干净已提交 HEAD | submit 干净检查 + base 祖先检查；validate/decision 双重完整性校验 | §5–§12, §19 | ✅ |
| AC8 | Cursor 是每个 profile 的唯一正式评审/验证/决策者；其他 provider CLI 不能替换不可变快照门 | 门策略只存在于 review 快照；wrapper 只放行 4 个命令；适配器声明 writer=true | §6, §19 | ⚠️ 部分（见 F5：同 UID 下 writer 技术上可自调用底层命令；仅靠 prompt 约束） |
| AC9 | 会话元数据与恢复行为按 provider 显式声明；不支持的自动恢复安全失败 | capabilities 声明（explicit_session_id/session_dir/resume_by_id/automatic_resume）；Gemini marker 原子发布；无 marker 不 resume | §22, §23 | ✅ |
| AC10 | README/适配器元数据区分本地 CLI 检查与真实模型测试；不断言 CLI 未提供的网络隔离 | README 各 profile 的 "non-claims" 表 + 本地证据表 | 文档核对 | ✅ |

## 1.3 Round 1 结论

- 10 条 AC 中 9 条完全闭合；AC8 存在**威胁模型缺口（F5）**：规范说"其他 provider CLI 不能替换门"，实现层面仅靠 prompt + 同 UID 信任，无能力级约束。规范措辞建议改为"在 writer 遵守其 prompt 的前提下，其他 provider 不承担门角色"。
- 用户故事层面新增 2 条未被 AC 覆盖的审计体验问题（F2、F4），建议补充 AC："status 必须显示与当前 Review HEAD 绑定的验证/决策状态"、"status 必须报告快照完整性检查结果"。
