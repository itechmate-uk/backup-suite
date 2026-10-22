"use strict";

// Commands that need a terminal, like agentw-gui's operation tasks: the command runs
// under `script` (a pseudo-terminal, so sudo can ask for its password), its output
// is kept for the page to poll, and the page's input box writes typed lines to it.
// The GUI never looks at that input: sudo reads it from the terminal with echo off.

const { spawn } = require("child_process");
const crypto = require("crypto");

const MAX_OUTPUT_BYTES = 512 * 1024;
const MAX_INPUT_LENGTH = 4096;
const KEEP_FINISHED_MS = 30 * 60 * 1000;
const MAX_TASKS = 4;

function quote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`;
}

class TerminalTasks {
  constructor({ env = process.env, log = () => {} } = {}) {
    this.env = env;
    this.log = log;
    this.tasks = new Map();
  }

  // Starts `command` (a shell command line built by the server, never by the page).
  start(command, { label = "command" } = {}) {
    this.prune();
    for (const task of this.tasks.values()) {
      if (!task.done && task.label === label) {
        throw Object.assign(new Error(`${label} is already running.`), { code: "busy" });
      }
    }
    if (this.tasks.size >= MAX_TASKS) throw Object.assign(new Error("Too many terminal tasks."), { code: "busy" });
    const id = crypto.randomBytes(12).toString("hex");
    const scriptBin = this.env.BACKUP_SUITE_GUI_SCRIPT || "script";
    const child = spawn(scriptBin, ["-q", "-e", "-c", command, "/dev/null"], {
      env: { ...this.env, TERM: "dumb", COLUMNS: "120", LINES: "40" },
      stdio: ["pipe", "pipe", "pipe"],
      detached: true
    });
    const task = { id, label, child, output: "", trimmed: 0, done: false, code: null, startedAt: new Date().toISOString(), finishedAt: "" };
    const append = (chunk) => {
      task.output += chunk.toString("utf8");
      if (task.output.length > MAX_OUTPUT_BYTES) {
        const cut = task.output.length - MAX_OUTPUT_BYTES;
        task.output = task.output.slice(cut);
        task.trimmed += cut;
      }
    };
    child.stdout.on("data", append);
    child.stderr.on("data", append);
    child.stdin.on("error", () => {});
    child.on("error", (error) => {
      append(`\n${error.message}\n`);
      task.done = true;
      task.code = -1;
      task.finishedAt = new Date().toISOString();
    });
    child.on("close", (code) => {
      task.done = true;
      task.code = code;
      task.finishedAt = new Date().toISOString();
      this.log("terminal", `${label} finished with ${code}`);
    });
    this.tasks.set(id, task);
    this.log("terminal", `${label} started`);
    return this.view(task, 0);
  }

  view(task, offset = 0) {
    const absolute = task.trimmed + task.output.length;
    const from = Math.max(0, Number(offset) - task.trimmed);
    return {
      id: task.id, label: task.label, done: task.done, code: task.code,
      started_at: task.startedAt, finished_at: task.finishedAt,
      output: task.output.slice(from), offset: absolute
    };
  }

  get(id, offset = 0) {
    const task = this.tasks.get(String(id || ""));
    if (!task) throw Object.assign(new Error("No such terminal task."), { code: "not_found" });
    return this.view(task, offset);
  }

  // One typed line, written to the terminal as typed (never logged or kept).
  input(id, text) {
    const task = this.tasks.get(String(id || ""));
    if (!task) throw Object.assign(new Error("No such terminal task."), { code: "not_found" });
    if (task.done) throw Object.assign(new Error("The command has finished."), { code: "invalid_request" });
    const line = String(text ?? "");
    if (line.length > MAX_INPUT_LENGTH || /[\r\n\0]/.test(line)) {
      throw Object.assign(new Error("Send one line at a time."), { code: "invalid_request" });
    }
    task.child.stdin.write(`${line}\n`);
    return { ok: true };
  }

  stop(id) {
    const task = this.tasks.get(String(id || ""));
    if (!task) throw Object.assign(new Error("No such terminal task."), { code: "not_found" });
    if (!task.done) {
      try {
        process.kill(-task.child.pid, "SIGTERM");
      } catch {
        task.child.kill("SIGTERM");
      }
    }
    return { stopping: !task.done };
  }

  prune() {
    const now = Date.now();
    for (const [id, task] of this.tasks) {
      if (task.done && now - Date.parse(task.finishedAt) > KEEP_FINISHED_MS) this.tasks.delete(id);
    }
  }
}

module.exports = { TerminalTasks, quote };
