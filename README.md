# cicy-tools

面向 Colab、Google Cloud Shell、WSL 和临时主机的独立工具集合。脚本可通过 `curl` 直接运行；连接信息和密钥由环境变量或本地配置传入，不写入仓库。

## 工具总览

| 文件 | 用途 |
| --- | --- |
| `colab-gpu-keepalive.sh` | Colab CPU/GPU heartbeat 启动器。自动检测已有进程，输出版本、GPU、CPU、内存、磁盘和日志路径。 |
| `colab-gpu-keepalive.py` | Heartbeat 后台程序；每分钟写日志，每 5 分钟执行轻量 GPU/CPU 检查。 |
| `colab-frp-ssh.sh` | 安装并启动 Colab SSH，通过外部 frp 网关暴露 Runtime。 |
| `colab-digital-human.ipynb` | Colab 数字人口播环境示例 Notebook。 |
| `cicy-cloudshell.sh` | 在 Google Cloud Shell 中以 Docker 运行 cicy-code，并通过 frp 暴露服务。 |
| `cicy-cloudshell-ssh.sh` | 在 Cloud Shell 启动 SSH，配合 Cloudflare Named Tunnel 使用。 |
| `cicy-wsl.sh` | 在 Windows WSL 中安装 SSH/frpc，并通过 frp 暴露该发行版。 |
| `musetalk-provision.sh` | 在 Colab 安装 MuseTalk 1.5、模型和独立运行环境，并执行冒烟测试。 |
| `musetalk-synthesize.sh` | MuseTalk 对口型合成封装，输入视频和音频，输出 MP4。 |
| `cosyvoice-provision.sh` | 在 Colab 安装 CosyVoice2 及独立运行环境。 |
| `cosyvoice_tts.py` | CosyVoice2 零样本声音克隆 TTS 命令行封装。 |
| `heygem-provision.sh` | 在 Colab 安装实验性的 HeyGem Linux 环境。 |
| `heygem-synthesize.sh` | HeyGem 对口型合成封装。 |
| `config.ini.example` | Cloud Shell/frp 配置样例，不包含真实密钥。 |
| `chrome-colab-heartbeat/` | Chrome 扩展：当 Colab 第一个 Cell 是 heartbeat 命令时自动点击一次 Run。 |

## Colab CPU/GPU heartbeat

在 Colab 第一个 Cell 中运行：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash
```

脚本具有幂等性：未运行时启动，已运行时复用，不会创建重复进程。每次只输出一行当前状态，例如：

```text
heartbeat=running version=1.2.0 interval=30s pid=123 gpu=[Tesla T4, 2 MiB, 15360 MiB] cpu=2cores memory=1.0Gi/12Gi disk=21G/108G(19%) log=/content/gpu-heartbeat.log
cicy-code=running pid=456 login_log=connected log=/content/cicy-code.log
```

第二行检测 cicy-code 进程和登录日志，`login_log` 可能为 `connected`、`pending`、`failed`、`not-found` 或 `missing`。脚本不会读取或输出登录凭据。

查看日志：

```bash
!tail -n 20 /content/gpu-heartbeat.log
```

## Chrome Colab 扩展

扩展位于 [`chrome-colab-heartbeat/`](chrome-colab-heartbeat/)，仅匹配：

```text
https://colab.research.google.com/*
```

默认间隔为 30 秒，也可使用 `bash -s <秒数>` 覆盖。只有首 Cell 已输出对应 `interval=<秒数>s` 和日志路径时，扩展才按该秒数定时点击 Run；没有时间或日志输出时不执行。安装和完整规则见目录内的 [`README.md`](chrome-colab-heartbeat/README.md)。

## Colab SSH / frp

```bash
FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… FRP_TOKEN=… \
  bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-frp-ssh.sh)
```

Colab Runtime 是临时环境，每次获得新 Runtime 后需要重新运行。密钥建议保存在 Colab Secrets 中。

## Google Cloud Shell

复制 `config.ini.example` 为 `~/config.ini` 并填写本地配置，然后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh | bash
```

只启动 Cloud Shell SSH 时使用：

```bash
curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell-ssh.sh | bash
```

## Windows WSL

在 WSL 发行版内运行：

```bash
FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… FRP_TOKEN=… \
  bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-wsl.sh)
```

## 数字人组件

三组组件各自使用独立目录和环境，避免 PyTorch/CUDA 依赖冲突：

- MuseTalk：`/content/mt`
- CosyVoice：`/content/cosy`
- HeyGem：`/content/hg`

Provision 脚本负责安装和就绪检查；`*-synthesize.sh`、`cosyvoice_tts.py` 是业务调用入口。具体参数和输出约定见各文件头部注释。

## 安全约定

- 不把 token、密码或私钥提交到仓库。
- frp/Cloudflare 参数通过环境变量或 `~/config.ini` 注入。
- `config.ini.example` 只提供字段结构。
- `/content` 属于 Colab 临时磁盘，Runtime 回收后其中的进程和日志都会消失。
