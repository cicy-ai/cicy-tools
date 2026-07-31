# cicy-tools Chrome Extension

仅在 Google Colab 页面生效的 Chrome Manifest V3 扩展，显示名称为 `cicy-tools`，当前版本 `1.1.4`。

## 安装

1. 打开 `chrome://extensions/`。
2. 开启右上角「开发者模式」。
3. 点击「加载已解压的扩展程序」。
4. 选择本目录 `cicy-tools/`。
5. 安装或更新后刷新 Colab 页面。

## 使用

将下面命令放在 Notebook 的第一个 Cell。默认每 30 秒执行一次：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash
```

如果 Cell 已有以下输出，扩展使用其中的秒数：

```text
interval=30s log=/content/gpu-heartbeat.log
```

如果 Cell 没有 output，或 output 中没有 `interval=`，扩展默认等待 30 秒后点击 Run。之后会从最新输出重新读取间隔。

## 执行条件

以下条件必须全部满足：

- 页面地址匹配 `https://colab.research.google.com/*`。
- 目标是 Notebook 的第一个 Cell。
- output 包含 `interval=<秒数>s` 时使用该秒数。
- 没有 output 或没有 `interval=` 时使用默认值 30 秒。

命令不匹配或位于其他 Cell 时，扩展不会点击。

## 修改时间

例如改为每 60 秒执行：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash -s 60
```

运行后 Shell 会输出 `interval=60s`，扩展后续自动切换为每 60 秒执行。
