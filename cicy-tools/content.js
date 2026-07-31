// cicy-tools: keep supported browser workspaces active.
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

function scheduleNextColabRun() {
  if (timer) return;
  const state = readFirstCell();
  if (!state) return;

  timer = setTimeout(() => {
    timer = null;
    const current = readFirstCell();
    current?.cell.querySelector("colab-run-button")?.click();
    setTimeout(scheduleNextColabRun, 1000);
  }, state.seconds * 1000);
}

function isVisible(element) {
  if (!element) return false;
  const rect = element.getBoundingClientRect();
  return rect.width > 0 && rect.height > 0;
}

function findCloudShellButton(pattern) {
  return [...document.querySelectorAll("button,[role=button]")].find((element) => {
    const label = normalize(
      `${element.getAttribute("aria-label") || ""} ${element.textContent || ""}`,
    );
    return isVisible(element) && pattern.test(label);
  });
}

function isCloudShellTerminalOpen() {
  const button = findCloudShellButton(/^(关闭终端|Close terminal)$/i);
  return Boolean(button && button.getBoundingClientRect().y < 50);
}

function reconnectCloudShell() {
  const button = findCloudShellButton(/重新连接|Reconnect/i);
  if (!button) return false;
  button.click();
  return true;
}

function cloudShellPromptIsIdle() {
  const tree = document.querySelector(".xterm-accessibility-tree");
  const lines = [...(tree?.children || [])]
    .map((element) => element.textContent || "")
    .filter((line) => line.trim());
  const lastLine = lines.at(-1) || "";
  return /(?:[$#>]\s*)$/.test(lastLine);
}

function sendCloudShellDate() {
  if (!isCloudShellTerminalOpen()) return false;
  if (reconnectCloudShell()) return false;

  const input = document.querySelector(
    'textarea.xterm-helper-textarea[aria-label="Terminal input"]',
  );
  if (!isVisible(input) || !cloudShellPromptIsIdle()) return false;

  input.focus();
  for (const char of "date") {
    const options = {
      key: char,
      code: `Key${char.toUpperCase()}`,
      keyCode: char.toUpperCase().charCodeAt(0),
      which: char.toUpperCase().charCodeAt(0),
      bubbles: true,
      cancelable: true,
    };
    input.dispatchEvent(new KeyboardEvent("keydown", options));
    input.dispatchEvent(new KeyboardEvent("keypress", options));
    input.dispatchEvent(new KeyboardEvent("keyup", options));
  }

  const enter = {
    key: "Enter",
    code: "Enter",
    keyCode: 13,
    which: 13,
    bubbles: true,
    cancelable: true,
  };
  input.dispatchEvent(new KeyboardEvent("keydown", enter));
  input.dispatchEvent(new KeyboardEvent("keypress", enter));
  input.dispatchEvent(new KeyboardEvent("keyup", enter));
  return true;
}

if (location.hostname === "colab.research.google.com") {
  new MutationObserver(scheduleNextColabRun).observe(document.documentElement, {
    childList: true,
    subtree: true,
  });
  scheduleNextColabRun();
} else if (location.hostname === "shell.cloud.google.com") {
  setInterval(sendCloudShellDate, 30_000);
}
