# 言语 · Yanyu

[English](README.md) | **简体中文**

言语是基于 [Handy](https://github.com/cjpais/Handy) 的个人语音输入项目。我们计划改善 UI/UX，并在后续加入个人语音样本的整理、人工校正和导出，为模型训练积累数据。

应用已使用言语 · Yanyu 品牌和独立标识。界面改版、训练数据导出和模型训练流程尚未实现。

可选的本地润色在 Apple Silicon Mac 上使用 Qwen3-0.6B 和固定的保守清理规则，可在常规设置中启用。已启用的个性化资料仅提供术语背景，禁用或删除的资料不影响本地润色。提示词编辑区已移除，但已保存的旧提示词仍保留在磁盘上。本地试用与日常听写使用相同处理，不回退到外部服务。超过 200 字的输入跳过润色；模型不可用、输出无效或超过 500 毫秒时保留原始转写。这些检查无法保证语义忠实性。关闭本地润色时，可选的个性化试用仍使用已配置的外部服务。

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
