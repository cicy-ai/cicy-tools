// cicy-tools: keep supported browser workspaces active.
const COMMAND_PATTERN =
  /^!curl -fsSL https:\/\/raw\.githubusercontent\.com\/cicy-ai\/cicy-tools\/main\/colab-gpu-keepalive\.sh \| bash(?: -s(?: --)? [1-9]\d*)?$/;
const INTERVAL_PATTERN = /interval=([1-9]\d*)s/;
const CLOUD_SHELL_COMMAND = "cicytools";
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

function cloudShellTerminalToggle() {
  const buttons = [...document.querySelectorAll("button.large")]
    .filter((button) => isVisible(button) && button.getBoundingClientRect().y < 50)
    .sort(
      (left, right) =>
        left.getBoundingClientRect().x - right.getBoundingClientRect().x,
    );
  return buttons[1] || null;
}

function isCloudShellTerminalOpen() {
  return cloudShellTerminalToggle()?.classList.contains("selected") || false;
}

function reconnectCloudShell() {
  const button = findCloudShellButton(
    /重新连接|Reconnect|重新連線|再接続|다시 연결|Reconectar|Reconnecter|Erneut verbinden/i,
  );
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

function cloudShellKeyOptions(char) {
  if (/[a-z]/i.test(char)) {
    return {
      code: `Key${char.toUpperCase()}`,
      keyCode: char.toUpperCase().charCodeAt(0),
      shiftKey: false,
    };
  }
  if (/\d/.test(char)) {
    return { code: `Digit${char}`, keyCode: char.charCodeAt(0), shiftKey: false };
  }

  const punctuation = {
    " ": { code: "Space", keyCode: 32, shiftKey: false },
    "-": { code: "Minus", keyCode: 189, shiftKey: false },
    ".": { code: "Period", keyCode: 190, shiftKey: false },
    "/": { code: "Slash", keyCode: 191, shiftKey: false },
    ":": { code: "Semicolon", keyCode: 186, shiftKey: true },
    "|": { code: "Backslash", keyCode: 220, shiftKey: true },
  };
  return punctuation[char];
}

function sendCloudShellHeartbeat() {
  if (!isCloudShellTerminalOpen()) return false;
  if (reconnectCloudShell()) return false;

  const input = document.querySelector(
    'textarea.xterm-helper-textarea[aria-label="Terminal input"]',
  );
  if (!isVisible(input) || !cloudShellPromptIsIdle()) return false;

  input.focus();
  for (const char of CLOUD_SHELL_COMMAND) {
    const key = cloudShellKeyOptions(char);
    if (!key) return false;
    const options = {
      key: char,
      code: key.code,
      keyCode: key.keyCode,
      which: key.keyCode,
      shiftKey: key.shiftKey,
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
  setInterval(sendCloudShellHeartbeat, 30_000);
}
