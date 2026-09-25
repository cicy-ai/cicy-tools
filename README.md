# cicy-tools

面向 Colab、Google Cloud Shell、WSL 和临时主机的独立工具集合。脚本可通过 `curl` 直接运行；连接信息和密钥由环境变量或本地配置传入，不写入仓库。

## 工具总览

| 文件 | 用途 |
| --- | --- |
| `colab-gpu-keepalive.sh` | Colab CPU/GPU heartbeat 启动器。自动检测已有进程，输出版本、GPU、CPU、内存、磁盘和日志路径。 |
| `colab-gpu-keepalive.py` | Heartbeat 后台程序；按指定间隔写日志，约每 5 分钟执行轻量 GPU/CPU 检查。 |
| `colab-cicy-code.sh` | 在 Colab 恢复私有配置、Codex 登录、虚拟桌面，担保注册到 CiCy Hub 并启动 `cicy-code@latest`（hub + 内置 frpc，不走 cicy-cloud）。 |
| `colab-cicy-code.py` | 在 Colab Notebook Kernel 中读取 Secrets，并安全调用 cicy-code shell 安装器。 |
| `cloudshell-keepalive.sh` | Cloud Shell heartbeat；输出 cicy-code PID、CPU、内存和 `~/` 所在磁盘用量。 |
| `colab-llm.sh` | 在 Colab GPU 上用 llama.cpp 跑 GGUF 大模型（默认 Qwen3.8-27B），按显存自动选量化，提供 OpenAI 兼容接口并注册为 cicy-code provider。 |
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

## 在 Colab 启动 cicy-code（直接接入 CiCy Hub）

Colab 实例只接入 ws hub（默认 `https://ws.cicy-ai.com`，可用 `CICY_HUB_ORIGIN` 覆盖），不再经过 cicy-cloud。Secret 只能由 Notebook Python Kernel 读取，因此使用 keepalive 下载的 Python 启动器：

```python
%run /content/colab-cicy-code.py --email <address> --team colab_<team>
```

Colab Secrets：

| Secret | 作用 |
|--------|------|
| `CICY_EMAIL` | 登录邮箱（`--email` 可覆盖）。 |
| `CICY_HUB_TOKEN` | **首次接入必填**：同一 owner 已有实例的 hub token（设置 → CiCy 账号）。安装器用它调 hub 的 `/api/enroll` 担保注册本实例，无需邮件验证码。之后若 config 仓库恢复出的 hub 凭据仍被 hub 接受，则直接复用（同一实例 id、同一域名），此 Secret 可留空。 |
| `CICY_PROVIDERS_JSON` | 可选：base64 的 `{"items":[<global.json providers.items 条目>],"defaults":{...}}`，启动后通过 providers API 写入，让重建的 Runtime 自动拿回模型密钥。 |
| `CICY_CONFIG_GH_TOKEN` + `CICY_CONFIG_GH_REPO` | 可选，成对出现；恢复团队 config 仓库（含 `db/cloud-device.json`、`db/global.json`、`db/crontab.txt`），并由其中的 cron 同步脚本持续回写。有了它，Runtime 回收后重跑两格即可恢复身份、密钥和记录。 |
| `CICY_KNOWLEDGE_GH_TOKEN` / `CICY_KNOWLEDGE_GH_REPO` | 可选：知识库仓库，默认 `w3c-ai/cicy-ai-knowledge`。 |
| `CODEX_AUTH_B64` | 可选：Codex 登录。 |

hub 凭据在 cicy-code 启动**之前**写入 `~/cicy-ai/db/cloud-device.json`（`mode: hub`），守护进程启动即走 hub WebSocket 并自动拉起内置 frpc；不再启动 Cloudflare Quick Tunnel。成功后输出：

```text
TOKEN=<本实例 API token>
HUB_DOMAIN=https://colab-<team>.hub.cicy-ai.com
AGENT_ADDRESS=colab_<team>.<agent>   # cicy-agent msg colab_<team>.w-1001 …
OPEN_URL=https://colab-<team>.hub.cicy-ai.com/_hub/grant?g=…   # 一次性免登录链接
```

hub 域名不接受 `?token=`；`OPEN_URL` 是实例自己向 hub 申请的一次性授权链接，过期后从任意 owner 桌面端的「CiCy Hub」列表点「打开」即可再生成。实例名即 `--team`，hub 会把它 slug 化为域名（`colab_limeng` → `colab-limeng.hub.cicy-ai.com`）。

`--reset-instance` 强制丢弃已保存身份、注册新实例 id；`--team` 变化时也会自动这样做。安装器仍先停止已有 cicy-code，再以最新版启动；`--restart` 走热更新脚本，跳过安装与配置恢复。

## Colab 本地大模型（llama.cpp）

先把运行时切到 GPU（T4 / L4 / A100），再在新 Cell 中运行：

```bash
!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-llm.sh | bash
```

默认模型 `unsloth/Qwen3.8-27B-GGUF`。脚本会：

1. 按显存选量化和上下文：T4 16G → `UD-Q3_K_XL` / 8K，L4 24G → `UD-Q4_K_XL` / 32K，A100 40G → `UD-Q6_K_XL` / 64K，80G → `UD-Q8_K_XL` / 128K。
2. 安装 llama.cpp 官方 CUDA 12.8 预编译包（含 cudart/cublas）；如果预编译内核不支持当前 GPU，自动按本机算力从源码编译。
3. 从 Hugging Face 断点续传下载 GGUF 到 `/content/llm/models`。
4. 启动 `llama-server`（KV cache q8_0、Flash Attention、`--fit` 在显存不足时把部分层放到 CPU），做一次真实对话冒烟测试。
5. 如果本机在跑 cicy-code，注册 provider `qwen_local`（模型名 `qwen3.8-27b`），不改默认 provider。

脚本幂等：参数不变时复用正在运行的服务。常用参数：

```bash
!curl -fsSL …/colab-llm.sh | bash -s -- --quant UD-Q4_K_XL --ctx 16384   # 指定量化/上下文
!curl -fsSL …/colab-llm.sh | bash -s -- --vision                          # 加载 mmproj，支持图片输入
!curl -fsSL …/colab-llm.sh | bash -s -- --stop                            # 停止服务
```

输出 `LLM_BASE_URL=http://127.0.0.1:18090/v1`、`LLM_API_KEY`（默认 `sk-colab-llm`，可用环境变量 `LLM_API_KEY` 覆盖）。服务只监听 `127.0.0.1`，外部访问请走 CiCy Hub。`/content` 是临时盘，Runtime 回收后需重跑（模型需重新下载）。

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

Colab、GitHub Actions 和 Cloud Shell 的统一运行账号为 `cicy`，HOME 固定为
`/home/cicy`；cicy-code、Config、Knowledge、projects、认证和 cron 均从该 HOME
运行。`cicy` 配置为 `sudo` 免密用户。

## Google Cloud Shell

W3C Cloud Shell 使用唯一 Team `cloudshell_w3c`、独立 Config
`w3c-ai/cicy-ai-config-cloudshell`，Knowledge 继续共用
`w3c-ai/cicy-ai-knowledge`。复制 `config.ini.example` 为 `~/config.ini`，填写
Cloudflare、FRP、GitHub Token 和邮箱后运行：

```bash
curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh | bash
```

也可以先安装 keepalive；它会同时安装 `cicytools` 和 `cicy-cloudshell` 两个命令，
heartbeat 会读取 `/home/cicy` 下直接运行的 cicy-code 状态：

```bash
curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cloudshell-keepalive.sh | bash -s -- install
cicy-cloudshell
```

以后只更新 cicy-code，不重新执行完整安装流程：

```bash
cicytools update              # 更新到 latest；版本未变化时不重启
cicytools update 2.3.405      # 更新到指定版本
```

更新器先下载并验证新的版本化二进制，再切换稳定软链，并使用保存的参数重新启动
cicy-code。运行参数保存在 `/home/cicy/cicy-ai/runtime/cicy-code.args`，运行日志仍为
`/home/cicy/logs/cicy-code.log`。

`cicy-cloudshell` 启动前会移除 Cloud Shell 登录用户遗留的
`~/.npmrc prefix=~/.npm-global`（避免与 nvm 冲突）。当 home 用量达到 95%
时仅清理可重建的 npm、pip、pnpm、uv、yarn 与 node-gyp 缓存；清理后仍达到
99% 会停止启动并列出最大的一级目录，避免在磁盘已满时留下半安装状态。

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
