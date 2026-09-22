# Photo Search

[English](README.md) · **简体中文**

一个面向 Apple Photos 照片库的本地优先语义搜索工具。

## 演示

不必记住日期或文件名，只需描述你记得的内容：人物、场景、画面文字，或者关于那个瞬间的一句话。

![Photo Search 演示](docs/photo-search-demo.webp)

本仓库包含产品的两个组成部分：

- `Sources/`、`Tests/`、`Package.swift` 和 `scripts/`：原生 SwiftUI macOS 应用。
- `backend/`：PhotoKit 导出、Apple Vision OCR、模型标注、SQLite 索引、本地 Web 后备界面和后台服务。
- `~/Library/Application Support/PhotoSearch/`：私有运行数据、预览图、模型服务配置、任务状态和日志。

应用只通过公开 API 读取 Apple Photos，不会修改系统照片库。所有派生产物都会记录模型、Prompt、Schema、预处理版本和输入哈希，便于后续比较和重新生成。

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

- `com.popcornnn.photo-search.web`
- `com.popcornnn.photo-search.worker`
- `com.popcornnn.photo-search.network`

应用的 **Settings → Models** 页面用于管理本地或云端 OpenAI-compatible 模型服务。Endpoint 和模型配置保存在私有运行目录中，API Key 保存在 macOS Keychain 中。

CLI 和索引流程详情见 [backend/README.md](backend/README.md)。
