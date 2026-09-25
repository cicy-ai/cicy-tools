# models

Colab GPU 上的本地大模型安装脚本，一个模型一个文件。在 Colab 新建 Cell 运行对应命令：

| 模型 | 命令 |
| --- | --- |
| Qwen3.8-27B（官方，unsloth GGUF） | `!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/models/qwen3.8-27b.sh \| bash` |
| Qwen3.8-27B Uncensored（JonathanColetti GGUF） | `!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/models/qwen3.8-27b-uncensored.sh \| bash` |

每个脚本按显存从自己的 `TABLE` 选量化和上下文，再调用根目录的 `colab-llm.sh` 完成安装 llama.cpp、下载、启动、冒烟测试和 cicy-code provider 注册。T4（15G）上的选择：

| 模型 | T4 量化 | 上下文 |
| --- | --- | --- |
| qwen3.8-27b | `UD-Q3_K_XL`（13.1G） | 32K |
| qwen3.8-27b-uncensored | `noMTP-IQ2_M`（10.2G） | 32K |

同一时间只运行一个模型；换模型直接运行另一个脚本，已下载的文件保留在 `/content/llm/models`，切回时不用重新下载。两个 Qwen 脚本对外模型名都是 `qwen3.8-27b`，已配置的 agent 不用改。

额外参数原样传给 `colab-llm.sh`，例如 `| bash -s -- --ctx 16384`、`--quant UD-Q4_K_XL`、`--stop`。

## 新增模型

复制一个现有脚本，改 `REPO`、`PREFIX`、`ALIAS` 和 `TABLE`（`最低显存MiB:量化:上下文`，从大到小排列，文件名为 `<PREFIX>-<量化>.gguf`），并在上表加一行。
