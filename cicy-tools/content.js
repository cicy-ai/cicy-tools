// cicy-tools: schedule the first Colab heartbeat cell.
const COMMAND_PATTERN =
  /^!curl -fsSL https:\/\/raw\.githubusercontent\.com\/cicy-ai\/cicy-tools\/main\/colab-gpu-keepalive\.sh \| bash(?: -s(?: --)? [1-9]\d*)?$/;
const INTERVAL_PATTERN = /interval=([1-9]\d*)s/;
let timer = null;

function normalize(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function readFirstCell() {
  const cell = document.querySelector("div.notebook-cell");
  if (!cell) return null;

  const code = normalize(cell.querySelector(".inputarea")?.innerText);
  if (!COMMAND_PATTERN.test(code)) return null;

  const output = cell.querySelector(".codecell-input-output")?.innerText || "";
  const interval = output.match(INTERVAL_PATTERN);
  return { cell, seconds: Number(interval?.[1] || 30) };
}

function scheduleNextRun() {
  if (timer) return;
  const state = readFirstCell();
  if (!state) return;

  timer = setTimeout(() => {
    timer = null;
    const current = readFirstCell();
    current?.cell.querySelector("colab-run-button")?.click();
    setTimeout(scheduleNextRun, 1000);
  }, state.seconds * 1000);
}

new MutationObserver(scheduleNextRun).observe(document.documentElement, {
  childList: true,
  subtree: true,
});
scheduleNextRun();
