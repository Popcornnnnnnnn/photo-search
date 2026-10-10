# Photo Search

[English](README.md) · **简体中文**

一个面向 Apple Photos 照片库的本地优先语义搜索工具。

## 演示

不必记住日期或文件名，只需描述你记得的内容：人物、场景、画面文字，或者关于那个瞬间的一句话。

![Photo Search 演示](docs/photo-search-demo.webp)

本仓库包含产品的两个组成部分：

- `Sources/`、`Tests/`、`Package.swift` 和 `scripts/`：原生 SwiftUI macOS 应用。
- `backend/`：PhotoKit 导出、Apple Vision OCR、模型标注、SQLite 索引、本地图片/文字向量、混合检索和后台服务。
- `~/Library/Application Support/PhotoSearch/`：私有运行数据、预览图、模型服务配置、任务状态和日志。

搜索、索引和浏览通过公开 API 读取 Apple Photos。**Review photos** 仅在你标记照片并明确确认后，通过 PhotoKit 删除选中项目；搜索和索引不会删除照片。所有派生产物都会记录模型、Prompt、Schema、预处理版本和输入哈希，便于后续比较和重新生成。

## 构建应用

```bash
swift test
scripts/build_app.sh --version 0.1.0 --build <build-number>
open "dist/Photo Search.app"
```

## 运行后端

```bash
cd backend
.venv/bin/python -m unittest discover -s tests
.venv/bin/photo-search doctor
scripts/install_background_services.sh
```

后台服务：

- `com.popcornnn.photo-search.worker`
- `com.popcornnn.photo-search.network`

应用的 **Settings → Models** 页面用于管理本地或云端 OpenAI-compatible 模型服务。Endpoint 和模型配置保存在私有运行目录中，API Key 保存在 macOS Keychain 中。

CLI 和索引流程详情见 [backend/README.md](backend/README.md)。

## 搜索和浏览

按 **Return** 或点击搜索箭头提交查询。输入过程中只编辑草稿，不启动搜索；
分类和时间范围筛选作用于上一次已提交的查询。两种提交入口使用同一套文字与
视觉排名。视觉助手超时或失败时回退到文字结果，下一次搜索可以重新启动助手。

日历菜单提供 **不限日期、最近 30 天、今年、去年**，按本地日历计算。
没有拍摄日期的项目仅在“不限日期”下显示。图库每次加载 200 项；
**加载更多**、大图中的下一张和 **Locate in Library** 会按需加载后续页面。
后台只在索引有已提交的变更时刷新，并保留已经加载的页面范围。

结果卡片标明文字匹配、画面相似或视频描述匹配，表示检索依据，
不代表置信度或对画面事实的确认。每个视频仍作为一个完整结果返回。
应用直接读取 SQLite，并通过本地子进程运行视觉搜索，不再依赖 Web 服务。

**Settings → Indexing** 分别展示文字、视觉和视频索引覆盖率。
等待下一批、状态过期、部分项目跳过和失败有不同标识；未知数量显示为“—”。
长时间处理中的后台任务每 30 秒刷新一次心跳。

## 验证和本地检查点

Swift 和后端测试均纳入 CI，两端共用合成检索样例：
`Tests/LiquidGlassDemoTests/Fixtures/search-ranking.json`。
这些样例不需要访问照片库、私有数据或下载模型。
Application Support 下的私有运行数据不纳入 Git。

当前 `origin` 是公开仓库；按项目约定，本地检查点不推送到该远端。
