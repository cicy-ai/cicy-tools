# Colab Heartbeat Runner

一个仅在 Google Colab 页面生效的 Chrome Manifest V3 扩展。

当 Notebook 的第一个 Cell 内容严格匹配以下命令时，扩展会自动点击一次 Run：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash
```

其他域名、其他命令和后续 Cell 均不会操作。同一页面会话只自动运行一次；heartbeat 启动脚本自身也会检测已有进程，不会重复启动。

## 安装

1. 打开 `chrome://extensions/`。
2. 打开右上角「开发者模式」。
3. 点击「加载已解压的扩展程序」。
4. 选择本目录 `chrome-colab-heartbeat/`。

## 使用

打开或刷新 `https://colab.research.google.com/` 下的 Notebook。若第一个 Cell 是上述命令，扩展会在 Cell 渲染完成后自动点击 Run。

## 权限范围

扩展没有后台服务和额外权限，内容脚本仅匹配：

```text
https://colab.research.google.com/*
```
