# v0.5 走查 Round 2 — 技术追踪与契约（多专家聚合）

> 各专家完整论证见 expert-*.md 的 R2 节。

## 关键契约事实（已核实源码）

- `last_transition_actor` 枚举：writer|reviewer|human|system（state.sh L108，fail-closed）
- `last_transition_action` 枚举：start|submit|validate|decision|escalate|resolve-approve|resolve-reject|resolve-recover|resolve-cancel|repair-state（state.sh L109）
- `resolve.sh` L202 硬编码 actor='human'；approve 分支清空 reason_detail（L108）
- list row contract：11 列钉死（v0.4 spec）；manifest 写入仅 start 单点
- lock.sh：dead-PID 回收 = `rm -rf` + `mkdir` 两步（竞态窗口）

## 关键发现

| # | 级别 | 发现 | 来源 | 裁定 |
|---|---|---|---|---|
| B1 | 严重 | actor 枚举冲突（详见 R1） | security / qa | system 复用；resolve 增加 --actor 透传（默认 human）+ approve 保留 --reason |
| B2 | 严重 | --once exit 2 与 v0.4 协议碰撞、无聚合优先级 | statemachine R2-1 / qa QA-06 | 新码 6=需人工；协议表 0/4/5/6；优先级 6>5>4>0 |
| B4 | 严重 | lock.sh 回收竞态（rm+mkdir 双成功）+ PID 复用死锁"活" | statemachine R2-2/R2-3 | Task 0：rename-to-tombstone 原子回收 + last_seen 心跳 + 双实例 fixture |
| — | 主要 | 心跳须并入锁活性协议；autopilot.tsv 每实例一行、钉死观测文件 | statemachine R2-3 / sre | 活性=pid alive AND last_seen 新鲜（<3×interval） |
| — | 主要 | 扫描遇 live lock（exit 4）无 defer 定义 | statemachine R2-4 | defer：跳过、不计数、下轮重扫 |
| — | 主要 | 扫描应走 status oracle 而非直读 run-state.tsv | statemachine R3-5 | status 为唯一读入口 |
| — | 主要 | 日志权威边界：日志可丢、审计不丢；reason 带实例标识 | statemachine R3-2 / sre | autopilot.log/tsv=观测；权威=run-state+SHA 归档 |
| — | 主要 | 作用域未定义：全局扫描放大同 UID 威胁 | security M3 / product R2-2 | --repo 白名单，--all 显式 |
| — | 主要 | auto-resume 是 spawn-and-stall 陷阱（trust prompt 半开 + reachability 误判） | statemachine R3-1 | 默认 0；启用时记 unconfirmed + exit 6 |
| — | 次要 | mode 未入 T1r creation intent 绑定 | statemachine R2-5 | 加入 intent 绑定，重试 fail-closed |
| — | 次要 | mode run 级不可变语义需显式声明 | statemachine R2-6 | 配置变更只影响新 run；切换走显式命令 |
| — | 次要 | 超时/心跳依赖墙上时钟 | statemachine R3-4 / sre | 容忍区间判定 + 文档化 |
| — | 次要 | watch+cron 双跑锁冲突 UX（exit 4 属正常） | product R3-4 | 文档化部署矩阵（二选一） |
