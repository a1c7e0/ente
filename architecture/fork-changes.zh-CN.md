# 本 fork 的改动与上游关联

核对日期：2026-10-25（Asia/Tokyo）。状态是本次核对的快照，以链接中的当前信息为准。

当前分支为 `feat/integration-test`，用于集中测试 Photos 功能和修复。它包含下面标为“有”的各项功能及本轮代码整理，使用 main 的 Server；Locker 共享配额功能未纳入。

## 功能与分支范围

| 功能或修复 | main | fix/review-feedback-refresh | feat/integration-test |
| --- | --- | --- | --- |
| 移动端、桌面端身体识别及现有人物工作流接入 | 有 | 有 | 有 |
| body 独立元数据、模型标记及共用冲突重试 | 有 | 有 | 有 |
| 常规元数据写入复用及旧测试夹具修正 | 有 | 有 | 有 |
| 身体分组、人工 review、Mixed grouping 拆分 | 有 | 有 | 有 |
| 元数据精度与 review 缓存优化、就绪候选预取 | 有 | 有 | 有 |
| 人物 Reset 与选定照片 ML reset / full reset | 有 | 有 | 有 |
| 空人物清理、人物删除后的缓存刷新 | 有 | 有 | 有 |
| body 反馈本地持久化、后台同步与撤销 | 有 | 有 | 有 |
| 高质量侧脸 singleton 进入人工 review | 独立分支 | 有 | 有 |
| 已命名人物存在时仍显示官方未命名 cluster | 独立分支 | 有 | 有 |
| 相册、搜索、头像与账号会话缓存修复 | 独立分支 | 有 | 有 |
| #14053 的删除、分组编辑和跨页面 review 刷新 | 未推广 | 有 | 有 |
| 完整 ML Debug 菜单及图库范围 body 诊断/重置 | feat/ml-lab 等测试分支 | 有 | 有 |
| 本轮共享阈值组件、review 测试与 APK workflow 整理 | 不适用或未推广 | 有 | 有 |

表中 main 的选定照片诊断/重置功能已经单独推广；这不表示整个 ML Lab 分支已合并。分支的祖先可能含有后来撤销的提交，判断功能是否存在应看当前代码，不能只看提交标题。

## 新增与接入的处理

- **身体识别**：使用既有 YOLOv5s 人体检测资源和 OSNet-AIN x1.0 embedding，沿用模型资源下载、校验、ML consent、索引调度及计算控制。与宠物识别共用的检测资源只下载一次，下载界面保留其他模型项。
- **人物与 review**：身体样本关联已有 face 身份/未命名簇，相似身体可形成 review 分组；沿用接受、拒绝、撤销和 Mixed grouping 操作。时间窗口、歧义检查和同照片排他规则仍存在；身体数据不会冒充 face 数据或创建新的 face 身份。
- **元数据**：在加密 mldata JSON 中加入独立顶级 `body`，face 数据补充模型标记，缺失标记采用当前模型默认值。保留未知字段及既有 face/CLIP 数据，三者复用版本检查和冲突重试路径。新增身体信息不要求 Server 新 API 或 SQL 列。
- **存储与缓存**：移动端扩展既有 Dart/Rust ML SQLite 数据库，桌面端扩展 IndexedDB。向量写入保留数值数组形状并取四位有效数字；解析结果按变更失效，裁剪复用既有缩略图/缓存路径。性能数字是特定数据与主机测量，不能当作手机端耗时承诺。
- **预览**：身体长边撑满现有 review 小框，照片边缘裁切、身体框外变暗。候选预取允许先显示已就绪分组，保留既定预取预算及保存失败后的恢复。
- **反馈同步**：body 接受、拒绝、撤销先提交本地持久化补丁，再由既有 file-data 同步流上传；按账号隔离、合并单文件变更并保留失败任务，避免旧确认删除较新的编辑。
- **重置**：单个人物 Reset 同时清理其 body review 数据。选定照片 `ML reset` 清人物绑定/review，保留框与 embedding；人脸绑定属于 cluster，触及的簇会整体解除人物分配；`ML full reset` 清生成数据并提供立即/稍后重算，复用既有处理队列。非本人所有或未上传照片不提供这些选定照片操作。批量操作限制读取/写入并发，保留失败项以便重试。
- **分支专属修复**：侧脸扩展只增加人工 review 候选；未命名簇修复保留官方 cluster 机制。缓存修复针对已确认的失效/会话问题；#14053 的移植保留 fork 的 body 缩略图和预取逻辑。

实现细节见 [身体识别](body-reid.md)、[反馈同步](body-feedback-sync.md)、[ML Lab](ml-lab.md) 和 [构建说明](fork-testing.md)。

## 本轮按项目习惯进行的整理

main、修复和集成分支均让常规元数据更新复用已有的校验/写入入口，保留会话保护及允许部分元数据的特殊写入路径，并补齐旧测试夹具所需的 CLIP 字段。

修复/集成分支将七次点击菜单与完整 ML Debug 菜单中的阈值代码合为一个现有样式的组件，保留原有文案、范围、持久化和禁用时的初始化行为。持久化开关等待原有异步设置操作完成。

review 测试通过显示的照片/分组和真实反馈调用验证结果，移除私有 State 读取；删除与 #14053 回归重叠的场景，保留 fork 特有的并行预备、失败恢复和晚到结果测试。未引入额外的生产测试接口。

APK workflow 移除了遗留的单项应用矩阵和 Locker 参数分支。Photos 的缓存键、签名配置、产物/Release 命名和手动触发方式保持原样。测试与静态分析仍由独立 CI 执行，APK workflow 保留产物完整性检查。

这些整理发生在对应修复/集成分支；它们不是对上游所有模块进行统一改写，也没有更换识别模型或调节匹配参数。

## 已撤销、隔离或未启用

自建自动 unnamed person 功能已经移除，保留官方 cluster 展示。Locker 共享空间配额仅在 `feat/locker-shared-storage`；main、这里的修复分支和集成分支均不包含该配额功能。

不默认补扫历史照片，不扩展匿名本地模式的人物分组/review。MMR、额外两/三跳传播和更激进的检测过滤仍是实验/建议，不作为当前已启用功能。Web Lab 重置和独立 Lab Server/Web 镜像已撤下；网页推理保留上游的客户端限制。

## 上游 PR、issue 与讨论

| 链接 | 本次核对的状态 | 与本 fork 的关系 |
| --- | --- | --- |
| [PR #14053](https://github.com/ente/ente/pull/14053) | Open；未合并；REVIEW_REQUIRED | 我们提交的人脸 review 刷新修复，不带 body 或 Lab 功能。最新提交 `db1940f63f` 仅精简测试：42 项减至 25 项，功能代码不变。旧版本自动审查和 CLA 已通过；最新提交需重新检查，仍需维护者审查。 |
| [Issue #9341](https://github.com/ente/ente/issues/9341) | Open | 删除唯一照片后仍出现候选；#14053 声明修复此问题。 |
| [Issue #9083](https://github.com/ente/ente/issues/9083) | Closed | 忽略匹配、返回页面后旧提示仍显示；属于相关历史背景，不应推断当前复现已被全部覆盖。 |
| [PR #11948](https://github.com/ente/ente/pull/11948) | Merged | 已有跨页面 review 刷新实现；本 fork 复用相应事件机制。 |
| [PR #12447](https://github.com/ente/ente/pull/12447) | Closed，未合并 | 先前的删除后候选刷新尝试，用于了解历史方案。 |
| [PR #12955](https://github.com/ente/ente/pull/12955) | Closed，未合并 | 并发人脸裁剪请求去重的来源之一；fork 采用了相关实现，不能称为已被上游合入的功能。来源版本见修复分支的说明。 |
| [Discussion #4091](https://github.com/ente/ente/discussions/4091) | 用户诉求/背景 | 关于显示未命名人脸的讨论；与保留官方 cluster 并修复其展示相关，不代表讨论中的所有诉求已经完成。 |
| [Discussion #12370](https://github.com/ente/ente/discussions/12370) | 用户诉求/背景 | 桌面端希望从 review 查看原照片；与预览可用性相关，并非本次移动端刷新修复的直接验收项。 |
| [Discussion #6048](https://github.com/ente/ente/discussions/6048) | 用户诉求/背景 | 桌面端人物管理、合并及 review 操作反馈；仅作项目上下文参考。 |

#14053 的 [自动审查记录](https://github.com/ente/ente/actions/runs/40105856901) 不等于人工批准或合并。后续状态变化时应更新本表。项目的 [贡献指南](https://github.com/ente/ente/blob/eb994dbbaf2b181a049a19ae3e711123f7ce6454/CONTRIBUTING.md) 要求改动聚焦、验证所触及的行为；相似症状不必自动捆成一个大型上游 PR。

## 本轮上游同步与组合验证

本分支已同步上游 `65fa47f765`，没有代码冲突。main、修复分支也同步到同一上游基线；上游 PR 的干净分支保持原状。组合验证在本集成分支执行，共 435 项测试通过，并通过应用和相关测试文件分析；真实 ONNX 模型契约检查也通过。范围、环境、构建入口及未完成的实机验证见 [本轮验证记录](integration-verification-2026-10-25.zh-CN.md)。

## 构建与验证边界

main 发布 Server 和完整 Web 镜像，分别是 `ghcr.io/a1c7e0/server` 和 `ghcr.io/a1c7e0/web`；相关目录变更自动触发，也支持手动触发，使用按包/架构隔离的构建缓存。Photos APK 始终手动触发，复用 Flutter、Dart、Cargo 和 Gradle 缓存；发布产物不代表部署服务。

整理前的 `8a3f9bf3ad` 已完成 [APK 构建](https://github.com/a1c7e0/ente/actions/runs/40158206853) 和 [独立 CI](https://github.com/a1c7e0/ente/actions/runs/40158208798)，均成功。上一轮整理另通过 57 项定向 Flutter 测试、Photos 静态分析、格式检查、actionlint 和内嵌 Python 语法检查，该轮未重新触发 APK 构建。本次同步版构建和更完整的验证见上节；核对产物 COMMIT 后再测试。

用户的真实相册、模型准确率、跨设备同步体验和手机端性能仍需要实机测试。构建、定向测试、自动审查、人工批准和上游合并分别记录，不能相互替代。
