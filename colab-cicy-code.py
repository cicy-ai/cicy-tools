"""Launch colab-cicy-code.sh with secrets from the Colab notebook kernel."""

import argparse
import os
import re
import subprocess
import sys

from google.colab import userdata


SECRET_NAMES = (
    "CICY_EMAIL",
    "CODEX_AUTH_B64",
    "CICY_CONFIG_GH_TOKEN",
    "CICY_CONFIG_GH_REPO",
    "CICY_KNOWLEDGE_GH_TOKEN",
    "CICY_KNOWLEDGE_GH_REPO",
)
INSTALLER = "/content/colab-cicy-code.sh"
INSTALL_LOG = "/content/colab-cicy-install.log"

parser = argparse.ArgumentParser()
parser.add_argument(
    "--email",
    help="cicy-code login email; overrides the CICY_EMAIL Colab Secret",
)
parser.add_argument(
    "--team",
    default=os.environ.get("CICY_TEAM_OVERRIDE", "colab_w3c"),
    help="cicy-code team id (default: colab_w3c)",
)
parser.add_argument(
    "--repo",
    help="Config GitHub repository in owner/name format; overrides CICY_CONFIG_GH_REPO",
)
parser.add_argument(
    "--reset-instance",
    action="store_true",
    help="back up the saved cloud identity and register a new instance ID",
)
parser.add_argument(
    "--preview",
    action="store_true",
    help="use /home/cicy/projects/cicy-code/app/dist when that preview build exists",
)
arguments = parser.parse_args()
if not re.fullmatch(r"[A-Za-z0-9_.-]+", arguments.team):
    parser.error("--team may only contain letters, digits, dot, underscore, and hyphen")
if arguments.repo and not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repo):
    parser.error("--repo must use owner/name format")

environment = os.environ.copy()
for name in SECRET_NAMES:
    if name == "CICY_EMAIL" and arguments.email:
        value = arguments.email
    else:
        try:
            value = userdata.get(name)
        except Exception:
            value = None
    if name == "CICY_EMAIL" and not value:
        raise RuntimeError(
            f"Missing or unauthorized Colab Secret: {name}. "
            "Create it in Secrets and enable notebook access."
        )
    if value:
        environment[name] = value

environment["CICY_TEAM"] = arguments.team
environment["CICY_EMAIL"] = arguments.email or environment["CICY_EMAIL"]
if arguments.repo:
    environment["CICY_CONFIG_GH_REPO"] = arguments.repo
installer_arguments = [INSTALLER, "--email", environment["CICY_EMAIL"], "--team", arguments.team]
if arguments.repo:
    installer_arguments.extend(["--repo", arguments.repo])
if arguments.reset_instance:
    environment["CICY_RESET_CLOUD_INSTANCE"] = "1"
    installer_arguments.append("--reset-instance")
if arguments.preview:
    installer_arguments.append("--preview")
with open(INSTALL_LOG, "w", encoding="utf-8") as log:
    process = subprocess.Popen(
        installer_arguments,
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
