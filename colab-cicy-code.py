"""Launch colab-cicy-code.sh with secrets from the Colab notebook kernel."""

import os
import subprocess

from google.colab import userdata


SECRET_NAMES = ("CICY_EMAIL", "CODEX_AUTH_B64", "CICY_CONFIG_GH_TOKEN")
INSTALLER = "/content/colab-cicy-code.sh"

environment = os.environ.copy()
for name in SECRET_NAMES:
    value = userdata.get(name)
    if not value:
        raise RuntimeError(
            f"Missing or unauthorized Colab Secret: {name}. "
            "Create it in Secrets and enable notebook access."
        )
    environment[name] = value

environment.setdefault("CICY_TEAM", "colab")
subprocess.run([INSTALLER], check=True, env=environment)
