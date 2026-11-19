# EchoFrame 项目约定

> 命名：仓库与目录沿用 `EchoFrame`，面向用户的产品名是「忆光 / Lumio」。Dart 包名 `lumio`，应用 ID `com.hxg.lumio`。除仓库/目录路径外，不要把产品名写成 EchoFrame。

- 本项目禁止使用 `test-driven-development` skill。
- 实现功能或修复问题时，不要因通用触发规则加载、声明或执行该 skill。
- 测试策略按改动风险和项目实际情况决定；前端改动默认不新增或修改单元测试，除非用户明确要求。
- 可继续使用现有静态检查、已有测试、构建和真机验证来确认改动。
- 提交前执行 `dart run tool/check.dart`（格式、静态分析、单元测试）；它与 `.github/workflows/ci.yml` 的检查项一致，未格式化的代码会被 CI 拒绝。
- 不要回退他人的无关改动；不要为了通过检查而放宽 `analysis_options.yaml`。
- 功能状态、平台能力或遗留问题发生变化时，同步更新 `docs/FEATURE_STATUS.md`；发布相关改动补充 `tool/release_notes/`。
