const COMMAND_PATTERN =
  /^!curl -fsSL https:\/\/raw\.githubusercontent\.com\/cicy-ai\/cicy-tools\/main\/colab-gpu-keepalive\.sh \| bash(?: -s(?: --)? ([1-9]\d*))?$/;
const LOG_PATH = "log=/content/gpu-heartbeat.log";
let timer = null;

function normalize(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function readFirstCell() {
  const cell = document.querySelector("div.notebook-cell");
  if (!cell) return null;

  const code = normalize(cell.querySelector(".inputarea")?.innerText);
  const match = code.match(COMMAND_PATTERN);
  if (!match) return { cell, seconds: 0, ready: false };

  const seconds = Number(match[1] || 30);
  const output = cell.querySelector(".codecell-input-output")?.innerText || "";
  const ready = output.includes(LOG_PATH) && output.includes(`interval=${seconds}s`);
  return { cell, seconds, ready };
}

function startTimer() {
  if (timer) return true;
  const state = readFirstCell();
  if (!state?.ready) return false;

  timer = setInterval(() => {
    const current = readFirstCell();
    if (!current || current.seconds !== state.seconds) {
      clearInterval(timer);
      timer = null;
      return;
    }
    if (!current.ready) return;
    current.cell.querySelector("colab-run-button")?.click();
  }, state.seconds * 1000);
  return true;
}

if (!startTimer()) {
  const observer = new MutationObserver(() => {
    if (startTimer()) observer.disconnect();
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
}
