# cicy-tools

面向 Colab、Google Cloud Shell、WSL 和临时主机的独立工具集合。脚本可通过 `curl` 直接运行；连接信息和密钥由环境变量或本地配置传入，不写入仓库。

## 工具总览

| 文件 | 用途 |
| --- | --- |
| `colab-gpu-keepalive.sh` | Colab CPU/GPU heartbeat 启动器。自动检测已有进程，输出版本、GPU、CPU、内存、磁盘和日志路径。 |
| `colab-gpu-keepalive.py` | Heartbeat 后台程序；按指定间隔写日志，约每 5 分钟执行轻量 GPU/CPU 检查。 |
| `colab-cicy-code.sh` | 在 Colab 恢复私有配置、Codex 登录、虚拟桌面并启动 `cicy-code@latest --cft`。 |
| `colab-cicy-code.py` | 在 Colab Notebook Kernel 中读取 Secrets，并安全调用 cicy-code shell 安装器。 |
| `cloudshell-keepalive.sh` | Cloud Shell heartbeat；输出 cicy-code PID、CPU、内存和 `~/` 所在磁盘用量。 |
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
| `cicy-tools/` | Chrome 扩展：保持 Colab heartbeat Cell 和已打开的 Cloud Shell Terminal 活跃。 |

## Colab CPU/GPU heartbeat

在 Colab 第一个 Cell 中运行：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/colab-gpu-keepalive-v1.3.5/colab-gpu-keepalive.sh | bash -s 20
```

脚本具有幂等性：未运行时启动，已运行时复用，不会创建重复进程。传入的秒数会作为真实 heartbeat 间隔；GPU/CPU 轻量检查约每 5 分钟执行一次。每次输出当前状态，例如：

```text
heartbeat=running version=1.2.2 interval=20s pid=123
gpu=[Tesla T4, 2 MiB, 15360 MiB] cpu=2cores
memory=1.0Gi/12Gi disk=21G/108G(19%)
installer=ready shell=/content/colab-cicy-code.sh launcher=/content/colab-cicy-code.py
cicy-code=running installed=yes version=2.3.336 pid=456 login_log=connected
cicy_log=/content/cicy-code.log
log=/content/gpu-heartbeat.log
!tail -f /content/gpu-heartbeat.log
```

每次运行 keepalive 启动器都会下载但不会执行最新版 `colab-cicy-code.sh`，并显示安装器是否就绪。`cicy-code` 行分别检测安装状态、运行状态、版本、PID 和登录日志。即使进程已经停止，也会检查全局命令、npx 缓存和安装标记；`login_log` 可能为 `connected`、`pending`、`failed`、`not-found` 或 `missing`。脚本不会读取或输出登录凭据。

查看日志：

```bash
!tail -n 20 /content/gpu-heartbeat.log
```

## 在 Colab 启动 cicy-code

可通过 `--email` 或 Colab Secret `CICY_EMAIL` 提供登录邮箱。`CODEX_AUTH_B64` 可选。Config 使用必须成对出现的 `CICY_CONFIG_GH_TOKEN` + `CICY_CONFIG_GH_REPO`；repo 值使用 `owner/name`。Knowledge 使用独立的 `CICY_KNOWLEDGE_GH_TOKEN`，repo 默认是 `w3c-ai/cicy-ai-knowledge`，仅在需要覆盖默认值时设置 `CICY_KNOWLEDGE_GH_REPO`。未提供对应 token 时只复用本地目录，不执行该私库的拉取和定时同步。Secret 只能由 Notebook Python Kernel 读取，因此使用 keepalive 下载的 Python启动器：

```python
%run /content/colab-cicy-code.py
```

启动器会实时显示安装输出，并同步保存到 `/content/colab-cicy-install.log`；cicy-code 运行日志位于 `/content/cicy-code.log`。成功后分别输出 `TOKEN`、随机 Quick Tunnel 的 `TUNNEL_URL`/`OPEN_URL`，以及 cicy-cloud 分配的固定 `FIXED_DOMAIN`/`FIXED_OPEN_URL`。

固定域名查询会同时查找 PATH 中的 `cicy-agent` 和 Skill 安装目录中的真实命令，并最多等待两分钟让 cicy-cloud 完成 proxyHost 上报；等待期间显示 `waiting for fixed cicy-cloud domain...`。

安装器不再根据 team 猜测 GitHub 仓库。一个 team 的所有 cicy-code 实例使用该 team 明确配置的 config repo，不同 team 配置不同 repo；Knowledge repo 独立指定。Config repo 可由 `CICY_CONFIG_GH_REPO` 提供，也可在启动时通过 `--repo owner/name` 覆盖。每次运行会先停止已有 cicy-code，再以指定的 `--team <name> --cft` 启动最新版并输出 `OPEN_URL`：`%run /content/colab-cicy-code.py --email <address> --team <name> --repo <owner/name>`。

如果配置仓库中的 `db/cloud-device.json` 属于另一个 team，安装器会先把旧身份备份到 `/content/cloud-device.<old-team>.previous.json`，再让 cicy-code 为当前 `--team` 注册独立实例，防止两个 Colab 共享同一 instance ID、互相覆盖心跳。

从同一份历史配置拆分出新 team 时，即使 `team_id` 字段看似正确，也可能继承相同的 `instance_id`。首次迁移时为每个 Colab 启动命令增加一次 `--reset-instance`，强制备份旧身份并生成新 instance ID；成功注册后后续启动不要再带此参数。

## cicy-tools Chrome 扩展

扩展位于 [`cicy-tools/`](cicy-tools/)，匹配：

```text
https://colab.research.google.com/*
https://shell.cloud.google.com/*
```

默认间隔为 30 秒，也可使用 `bash -s <秒数>` 覆盖。扩展从首 Cell 的 `interval=<秒数>s` 输出读取间隔；没有 output 或没有 `interval=` 时按 30 秒执行。安装和完整规则见目录内的 [`README.md`](cicy-tools/README.md)。

Cloud Shell 首次使用先运行 `curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh | bash -s -- install` 安装 `cicytools`。之后只有最下面的 Terminal 已打开且停在空提示符时，扩展才每 30 秒执行这个短命令，输出 cicy-code PID、CPU、内存和 `~/` 所在磁盘用量；Terminal 关闭、正在输入或命令正在运行时均不执行。已打开的 Terminal 断线并出现“重新连接”时，扩展会尝试重新连接。

## Colab SSH / frp

```bash
FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… FRP_TOKEN=… \
  bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-frp-ssh.sh)
```

Colab Runtime 是临时环境，每次获得新 Runtime 后需要重新运行。密钥建议保存在 Colab Secrets 中。

## Google Cloud Shell

W3C Cloud Shell 使用唯一 Team `cloudshell_w3c`、独立 Config
`w3c-ai/cicy-ai-config-cloudshell`，Knowledge 继续共用
`w3c-ai/cicy-ai-knowledge`。复制 `config.ini.example` 为 `~/config.ini`，填写
Cloudflare、FRP、GitHub Token 和邮箱后运行：

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
