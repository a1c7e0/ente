# Photos 集成分支验证记录

日期：2026-10-25（Asia/Tokyo）。验证对象为 `feat/integration-test`；同步上游 `65fa47f765ff403d6d597742b4dc88a2c3b91295` 后，记录时的代码/测试基线为 `3f4146af56`。后续报告和分支说明提交不改变这些功能代码。

## 同步范围

`main`、`fix/review-feedback-refresh` 和 `feat/integration-test` 均通过正常 merge 同步上游，没有代码冲突。main 接收了上游的独立相册封面选择器及视频封面恢复；后两者此前已包含封面选择器，只新增视频封面恢复。Server 和 Locker 与 main 保持一致，没有加入 fork 的 Locker 配额功能。

用于上游 PR #14053 的 `fix/review-suggestion-refresh-upstream` 保持原提交，没有为本次同步重写 PR。其他实验分支不属于本轮验证对象。

## 验证结果

| 检查 | 结果 | 能说明什么 |
| --- | --- | --- |
| Photos ML、数据库、人物、review、诊断、相册/搜索缓存回归 | 197 项通过 | 组合分支中的本地行为、受控异步顺序及错误恢复符合这些测试的断言 |
| 共享账号服务 | 4 项通过 | 退出/切换账号、保存期间会话变化和缓存行为 |
| Rust Photos 库 | 162 项通过 | 包括 body 索引持久化、版本筛选、清除及侧脸 review 数据库质量条件 |
| Rust body 检测/模型契约 | 4 项通过 | 包括真实 ONNX 模型调用及 embedding 分批处理，不只是 mock 输出 |
| Photos Web / 桌面共用 ML 与封面逻辑 | 40 项通过，8 个文件 | body 分组/反馈/调度、未命名簇关联、元数据合并、裁剪缓存和封面网格 |
| 上游 Space 视频封面回归 | 28 项通过 | 新同步的视频播放/封面恢复逻辑 |
| Photos 静态分析 | 通过 | 应用目录分析未发现问题 |
| 修改相关测试文件的显式静态分析 | 通过 | review、ML 服务、调试测试目录均无告警 |
| Rust 格式、fork workflow、Git diff | 通过 | `cargo fmt --check`、actionlint、`git diff --check` |

合计 435 项测试通过；修正两处测试风格告警后另行复测的 2 项 body 裁剪缓存测试不重复计入。测试数量表示执行范围，不代表实机覆盖率。

## 重点组合场景

- **review 与缓存**：删除/隐藏照片、编辑或拆分分组后，同时刷新成员与预备缩略图；查询/裁剪晚到不能恢复旧候选；取消命名表单要处理延后的失效。
- **跨页面完成 review**：从人物页或独立 review 完成最后一组，返回总 People 页；也覆盖先返回、后完成本地保存的顺序。
- **反馈与预取并行**：下一组可提前准备，保存完成前不能重复提交；失败后恢复原候选，迟到的缩略图不能覆盖恢复结果。
- **本地反馈与后台同步**：持久化后重开、账号隔离、部分上传失败、较新撤销与较旧确认竞争、远端变更覆盖保护。这些使用受控存储/远端替身，没有连接用户的真实服务端。
- **重置与数据边界**：绑定 reset 保留检测与 embedding；完整 reset 清理选定生成数据；空人物清理、失败项保留、分批读取和并发写入限制。
- **face/body 共存**：采用原有人脸质量与聚类约束，侧脸扩展只进入人工 review；body 数据使用独立身份空间和元数据，保留未知字段及 face/CLIP 信息。

## 真实模型检查

使用项目锁定的 ONNX Runtime `1.28.1-r1`；按上游测试资源锁文件验证运行时压缩包与动态库的 SHA-256。生产 `body::tests` 使用资源目录中的检测模型和 OSNet-AIN x1.0，并经过 AssetStore 校验。

模型契约测试实际执行检测和 embedding，验证 17 个裁剪按 16 + 1 分批处理、输出维度/数量及归一化条件。输入是受控合成图像；它证明模型资源和当前原生调用契约可工作，不是人物识别准确率或手机性能评测。

## 复现入口与环境

本地 Flutter 3.47.7 / Dart 3.13.5；GitHub 构建按现有 workflow 使用 Flutter 3.47.2。Rust 为 1.99.0。Web 使用锁文件对应的 Vitest 5.0.4 / Vite 8.3.4；复用其余本机依赖缓存，所有 workspace 链接指向本次 checkout，未执行完整 `npm ci` 或 Web 生产构建。

Flutter 的主要执行范围：

```sh
cd mobile/apps/photos
flutter test --no-pub test/models/ml test/db/ml_profile_review_test.dart \
  test/services/machine_learning test/ui/viewer/people test/ui/settings/debug \
  test/services/account/user_details_session_test.dart \
  test/services/collections_service_display_cache_test.dart \
  test/services/search_file_cache_test.dart test/utils/face/face_crop_request_queue_test.dart
flutter analyze --no-pub
flutter analyze --no-pub test/ui/viewer/people test/services/machine_learning test/ui/settings/debug
```

共享账号测试从 `mobile/packages/accounts` 运行 `flutter test --no-pub test/services/user_service_test.dart`。Rust 从 `rust/` 运行 `cargo test --locked -p ente-photos --lib`，以及 `cargo test --locked -p ente-ml --lib --features ml-assets body::tests`；后者需将 `ORT_DYLIB_PATH` 指向已校验的运行时，`ENTE_BODY_TEST_ASSETS` 指向模型缓存。

Web 从对应 app 目录运行 Vitest：Photos 的 `body-*.test.ts`、`unnamed-body-attachments.test.ts`、`ml-metadata.test.ts`、`cover-photo-grid.test.tsx`，以及 Space 的 `post-video-content.test.ts`。

## APK 与尚未验证的部分

本地检查不替代 Android 编译。同步版 APK 使用既有手动 workflow 构建，结果见 [集成分支 APK 构建记录](https://github.com/a1c7e0/ente/actions/workflows/fork-photos-apk.yml?query=branch%3Afeat%2Fintegration-test)。发布后核对 Release 的 `COMMIT`；先前 `8a3f9bf3ad` 成功构建的 APK 不包含这轮同步与整理。

没有连接手机/模拟器，没有使用真实账号和相册测试加密远端写入、跨设备同步、触控体验或 Android 内存/耗时。没有为本轮改动调整模型、检测/匹配阈值或聚类算法。人工验收继续使用 [集成测试清单](integration-test-checklist.zh.md)。
