# 言语 · Yanyu

言语是基于 [Handy](https://github.com/cjpais/Handy) 的个人语音输入项目。我们计划改善 UI/UX，并在后续加入个人语音样本的整理、人工校正和导出，为模型训练积累数据。

目前仓库保留上游实现。界面改版、训练数据导出和模型训练流程尚未实现。

## 项目来源

- 上游项目：[cjpais/Handy](https://github.com/cjpais/Handy)
- 初始导入提交：`f6b3f82`
- 原项目说明：[README.upstream.md](README.upstream.md)
- 保留上游 Git 提交历史，便于追踪来源和同步更新。

言语是独立的衍生项目，与 Handy 官方没有隶属或背书关系。源码中仍有上游的应用名称、图标和构建配置，发布言语安装包前需要替换为自己的品牌，并调整应用标识和更新地址。

## 技术栈与开发

- 界面：React、TypeScript、Tailwind CSS
- 桌面应用：Tauri 2、Rust
- 语音识别：本地模型推理

开发环境需要 Bun、Rust 和对应平台的 Tauri 构建依赖。完整步骤见 [BUILD.md](BUILD.md)。

```bash
bun install
bun run tauri dev
```

首次开发需要按 [AGENTS.md](AGENTS.md) 准备 Silero VAD 模型。个人录音和训练数据应保存在本地，不要提交到这个公开仓库。

## 许可证与署名

本项目采用 [MIT License](LICENSE)。保留上游作者 CJ Pais 的版权声明和完整许可文本。分发代码或其重要部分时，必须一并保留这些声明。

MIT 代码许可不代表可以使用 Handy 的名称、标识和品牌资产。品牌说明见[上游 README](https://github.com/cjpais/Handy#license)。
