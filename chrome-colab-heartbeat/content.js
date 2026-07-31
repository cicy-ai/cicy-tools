const HEARTBEAT_COMMAND =
  "!curl -fsSL https://raw.githubusercontent.com/cicy-ai/cicy-tools/main/colab-gpu-keepalive.sh | bash";
const RUN_KEY = "cicy-colab-heartbeat-ran";

function normalize(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function runHeartbeatCell() {
  if (sessionStorage.getItem(RUN_KEY) === location.href) return true;

  const firstCell = document.querySelector("div.notebook-cell");
  if (!firstCell) return false;

  const code = normalize(firstCell.querySelector(".inputarea")?.innerText);
  if (code !== HEARTBEAT_COMMAND) return true;

  const runButton = firstCell.querySelector("colab-run-button");
  if (!runButton) return false;

  sessionStorage.setItem(RUN_KEY, location.href);
  runButton.click();
  return true;
}

if (!runHeartbeatCell()) {
  const observer = new MutationObserver(() => {
    if (runHeartbeatCell()) observer.disconnect();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  setTimeout(() => observer.disconnect(), 120_000);
}
