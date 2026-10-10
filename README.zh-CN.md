# 言语 · Yanyu

[English](README.md) | **简体中文**

言语是基于 [Handy](https://github.com/cjpais/Handy) 的个人语音输入项目。我们计划改善 UI/UX，并在后续加入个人语音样本的整理、人工校正和导出，为模型训练积累数据。

应用已使用言语 · Yanyu 品牌和独立标识。界面改版、训练数据导出和模型训练流程尚未实现。

## 项目来源

- 上游项目：[cjpais/Handy](https://github.com/cjpais/Handy)
- 初始导入提交：`f6b3f82`
- 原项目说明：[README.upstream.md](README.upstream.md)
- 保留上游 Git 提交历史，便于追踪来源和同步更新。

言语是独立的衍生项目，与 Handy 官方没有隶属或背书关系。应用名称、图标、托盘和安装包已使用 Yanyu 品牌，应用标识为 `com.siyuqian.yanyu`。言语与上游使用独立的数据目录和系统权限，可以同时安装；已有 Handy 的设置、模型和历史不会自动迁移。自动更新暂时关闭，待配置言语自己的发布渠道和签名密钥后再启用。Windows 安装包暂不配置发行者签名。

## 技术栈与开发

- 界面：React、TypeScript、Tailwind CSS
- 桌面应用：Tauri 2、Rust
- 语音识别：本地模型推理

开发环境需要 Bun、Rust 和对应平台的 Tauri 构建依赖。完整步骤见 [BUILD.md](BUILD.md)。

```bash
bun install
bun run tauri dev
```

项目导航见 [AGENTS.md](AGENTS.md)，架构说明见 [ARCHITECTURE.md](ARCHITECTURE.md)，完整开发参考见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。首次开发需按开发参考准备 Silero VAD 模型。个人录音和训练数据应保存在本地，不要提交到这个公开仓库。

## 许可证与署名

本项目采用 [MIT License](LICENSE)。保留上游作者 CJ Pais 的版权声明和完整许可文本。分发代码或其重要部分时，必须一并保留这些声明。

MIT 代码许可不代表可以使用 Handy 的名称、标识和品牌资产。品牌说明见[上游 README](https://github.com/cjpais/Handy#license)。

### 个人词汇纠正原型

正常听写不会弹出纠正提示。在设置 → 听写中配置“修改上次听写”快捷键（macOS 默认 Command+Option+Shift+C，其他平台默认 Ctrl+Shift+F8）。编辑器打开最近成功输出的文字，包括润色结果，无需保存录音。修改后选中纠正的词语或短语，点击“记住选中的词语”，再应用。Enter 应用，Shift+Enter 换行，Escape 关闭并保留草稿。可在已有的自定义词汇设置中删除记住的词语。

macOS 仅在辅助功能支持读取该文字控件、原输入位置未变且插入内容经验证时替换。并非所有应用都能读取文字。不支持或已经变化的输入位置、仅复制输出、自动发送及其他平台都会复制纠正结果并明确提示。如果无法确认替换结果，请检查原输入位置。词汇保存在本机，使用已有的自定义词汇流程，包括支持的 Whisper 提示。此原型不训练模型、不保证中文识别准确率，也不进行广泛的中文同音替换。
