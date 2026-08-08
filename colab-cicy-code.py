"""Launch colab-cicy-code.sh with secrets from the Colab notebook kernel."""

import argparse
import os
import re
import subprocess
import sys

from google.colab import userdata


SECRET_NAMES = ("CICY_EMAIL", "CODEX_AUTH_B64", "CICY_CONFIG_GH_TOKEN")
INSTALLER = "/content/colab-cicy-code.sh"
INSTALL_LOG = "/content/colab-cicy-install.log"

parser = argparse.ArgumentParser()
parser.add_argument(
    "--team",
    default=os.environ.get("CICY_TEAM_OVERRIDE", "colab_w3c"),
    help="cicy-code team id (default: colab_w3c)",
)
arguments = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_.-]+", arguments.team):
    parser.error("--team may only contain letters, digits, dot, underscore, and hyphen")

environment = os.environ.copy()
for name in SECRET_NAMES:
    value = userdata.get(name)
    if not value:
        raise RuntimeError(
            f"Missing or unauthorized Colab Secret: {name}. "
            "Create it in Secrets and enable notebook access."
        )
    environment[name] = value

environment["CICY_TEAM"] = arguments.team
with open(INSTALL_LOG, "w", encoding="utf-8") as log:
    process = subprocess.Popen(
        [INSTALLER, "--team", arguments.team],
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
        log.write(line)
        log.flush()
    return_code = process.wait()

if return_code:
    print(f"colab-cicy-code failed with exit code {return_code}", file=sys.stderr)
    print(f"install log: {INSTALL_LOG}", file=sys.stderr)
    raise SystemExit(return_code)
