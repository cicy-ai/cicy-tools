# Colab Heartbeat Runner

仅在 Google Colab 页面生效的 Chrome Manifest V3 扩展，当前版本 `1.1.0`。

## 安装

1. 打开 `chrome://extensions/`。
2. 开启右上角「开发者模式」。
3. 点击「加载已解压的扩展程序」。
4. 选择本目录 `chrome-colab-heartbeat/`。
5. 安装或更新后刷新 Colab 页面。

## 使用

将下面命令放在 Notebook 的第一个 Cell，最后的 `30` 表示每 30 秒执行一次：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash -s -- 30
```

先手动运行一次该 Cell。成功输出必须同时包含时间和日志路径：

```text
interval=30s log=/content/gpu-heartbeat.log
```

扩展看到这两个字段后才启动定时器。它会等待 30 秒，然后点击第一个 Cell 的 Run；之后每 30 秒重复。

## 执行条件

以下条件必须全部满足：

- 页面地址匹配 `https://colab.research.google.com/*`。
- 目标是 Notebook 的第一个 Cell。
- 命令使用 `bash -s -- <秒数>`，秒数为正整数。
- Cell 已有输出。
- 输出包含对应的 `interval=<秒数>s`。
- 输出包含 `log=/content/gpu-heartbeat.log`。

缺少时间、尚无输出、日志路径不匹配或命令位于其他 Cell 时，扩展都不会点击。

## 修改时间

例如改为每 60 秒执行：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash -s -- 60
```

修改后先手动运行一次，让输出出现 `interval=60s`，再刷新页面以重建扩展定时器。
