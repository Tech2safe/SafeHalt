# SafeHalt 控制服务端 SDD 进度

Plan: docs/superpowers/plans/2026-07-08-safehalt-control-server.md
Branch: feat/control-server
Base (plan committed): 85ced86

- [x] Task 1: 基础常量 + DaemonConfig 演进 + 删死代码 — complete (b3ffc97..1acd470, review clean; Minor: ledger 被扫入提交-cosmetic)
- [x] Task 2: HTTP 解析/编码 — complete (1acd470..b450877; 评审 2 Important 已修:非法 Content-Length 抛 malformed + 补测试;11/11)
- [ ] Task 3: 配对码/令牌 + PairingStore
- [ ] Task 4: EngineStatus DTO + DaemonRunner 演进
- [ ] Task 5: ControlRouter
- [ ] Task 6: ControlServer (NWListener)
- [ ] Task 7: main 接线 + 子命令 + 品牌对话框
- [ ] Task 8: .pkg 打包 + 卸载 + README
