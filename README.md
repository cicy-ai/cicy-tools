# cicy-tools

Small self-contained setup scripts, hosted for `curl | bash` from ephemeral
hosts (Colab, throwaway VMs) where uploading files each session is annoying.
No connection details or secrets live in this repo — they are passed in via env
(Colab) or `~/config.ini` (Cloud Shell).

## colab-frp-ssh.sh

Expose a Google Colab runtime's SSH through a frp gateway so an agent can drive
it. All params (server / port / token) are passed IN via env — nothing is
hardcoded. Public keys are embedded (public by nature).

```bash
FRP_SERVER=… FRP_PORT=… FRP_REMOTE_PORT=… FRP_TOKEN=… \
  bash <(curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-frp-ssh.sh)
```

In Colab, store the token in **Secrets** (🔑) and run a cell that injects it +
the params — see the cicy `colab-frp-ssh` skill. Colab is ephemeral: re-run each
new runtime.

## cicy-cloudshell.sh

Run cicy-code in Docker on Google Cloud Shell + expose the host over frp. Every
domain / port / secret comes from `~/config.ini` (see `config.ini.example`),
never from this repo.

```bash
# thin launcher on Cloud Shell (~/cicy-cloudshell.sh):
curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/cicy-cloudshell.sh | bash
```
