"use strict";

// Updates from this project's GitHub releases, through scripts/backup-suite-update.py
// (bin/backup-suite-update.py, copied in when the GUI is installed).
//
// - check: the latest release, cached (automatic checks at most every 6 hours, a
//   check on request at most once a minute).
// - this login's GUI: updated as this login in a transient user unit
//   (backup-suite-gui-update.service), so the update outlives the GUI's restart.
// - Backup Suite itself: through the control verb update.apply (as root in
//   system mode); a system-wide GUI is updated with it.

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const AUTO_CHECK_MS = 6 * 60 * 60 * 1000;
const FORCED_CHECK_MS = 60 * 1000;
const RUN_TIMEOUT_MS = 60 * 1000;
const GUI_UPDATE_UNIT = "backup-suite-gui-update";

function parseVersion(text) {
  const match = /^(\d{1,4})\.(\d{1,5})\.(\d{1,6})$/.exec(String(text || "").trim());
  return match ? match.slice(1).map(Number) : null;
}

// True when `latest` is a newer version than `current` (or `current` is unknown).
function isNewer(latest, current) {
  const a = parseVersion(latest);
  if (!a) return false;
  const b = parseVersion(current);
  if (!b) return true;
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] > b[index];
  }
  return false;
}

function runJson(command, args, { env = process.env, timeoutMs = RUN_TIMEOUT_MS } = {}) {
  return new Promise((resolve) => {
    let output = "";
    let errors = "";
    let child;
    try {
      child = spawn(command, args, { env, stdio: ["ignore", "pipe", "pipe"] });
    } catch (error) {
      resolve({ ok: false, error: error.message });
      return;
    }
    const timer = setTimeout(() => child.kill("SIGKILL"), timeoutMs);
    child.stdout.on("data", (chunk) => { output += chunk; });
    child.stderr.on("data", (chunk) => { errors += chunk; });
    child.on("error", (error) => {
      clearTimeout(timer);
      resolve({ ok: false, error: error.message });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      const line = output.split("\n").find((part) => part.trim().startsWith("{"));
      if (line) {
        try {
          resolve(JSON.parse(line));
          return;
        } catch {
          // fall through
        }
      }
      resolve({ ok: false, error: (errors || output).trim().slice(0, 400) || `exit code ${code}` });
    });
  });
}

class Updates {
  constructor({ appDir, version, stateDir, env = process.env, systemGui = false, python = "python3", systemdRun = "systemd-run" }) {
    // The installed GUI has its own copy; a GUI run from a checkout uses bin/'s.
    const installed = path.join(appDir, "scripts", "backup-suite-update.py");
    const checkout = path.join(appDir, "..", "bin", "backup-suite-update.py");
    this.script = fs.existsSync(installed) || !fs.existsSync(checkout) ? installed : checkout;
    this.version = version;
    this.stateDir = path.join(stateDir, "updates");
    this.env = env;
    this.systemGui = systemGui;
    this.python = env.BACKUP_SUITE_GUI_PYTHON || python;
    this.systemdRun = env.BACKUP_SUITE_SYSTEMD_RUN || systemdRun;
    this.latest = null;
    this.checkedAt = 0;
    this.pending = null;
  }

  available() {
    return fs.existsSync(this.script);
  }

  // The latest release; cached unless `force` (and then at most once a minute).
  async check({ force = false } = {}) {
    const age = Date.now() - this.checkedAt;
    if (this.latest && (age < FORCED_CHECK_MS || (!force && age < AUTO_CHECK_MS))) return this.latest;
    if (this.pending) return this.pending;
    if (!this.available()) {
      return { ok: false, error: "This GUI has no updater yet; install it once more from a release (./install.sh --gui-only)." };
    }
    this.pending = runJson(this.python, ["-I", this.script, "check", "--current", this.version], { env: this.env })
      .then((result) => {
        this.latest = result.ok ? { ok: true, ...result.data } : { ok: false, error: result.error, checked_at: new Date().toISOString() };
        this.checkedAt = Date.now();
        return this.latest;
      })
      .finally(() => { this.pending = null; });
    return this.pending;
  }

  async guiStatus() {
    if (!this.available()) return { state: "idle" };
    const result = await runJson(this.python, ["-I", this.script, "status", "--state-dir", this.stateDir], { env: this.env });
    return result.ok ? result.data : { state: "unknown", error: result.error };
  }

  // Starts this login's GUI update in its own user unit; the GUI restarts during it.
  async startGuiUpdate(version) {
    if (this.systemGui) {
      throw Object.assign(new Error("This system-wide GUI is updated together with Backup Suite."), { code: "invalid_request" });
    }
    if (!parseVersion(version) || !isNewer(version, this.version)) {
      throw Object.assign(new Error(`Version ${version} is not newer than this GUI (${this.version}).`), { code: "invalid_request" });
    }
    if (!this.available()) {
      throw Object.assign(new Error("This GUI has no updater yet; install it once more from a release (./install.sh --gui-only)."), { code: "unavailable" });
    }
    fs.mkdirSync(this.stateDir, { recursive: true, mode: 0o700 });
    const args = ["--user", "--unit", GUI_UPDATE_UNIT, "--collect", "--quiet", "--description", `Backup Suite GUI update to ${version}`];
    for (const name of ["BACKUP_SUITE_UPDATE_LATEST_URL", "BACKUP_SUITE_UPDATE_DOWNLOAD_BASE"]) {
      if (this.env[name]) args.push("--setenv", `${name}=${this.env[name]}`);
    }
    args.push("--", this.python, "-I", this.script, "gui-apply", "--version", version, "--state-dir", this.stateDir);
    const result = await new Promise((resolve) => {
      let errors = "";
      const child = spawn(this.systemdRun, args, { env: this.env, stdio: ["ignore", "ignore", "pipe"] });
      child.stderr.on("data", (chunk) => { errors += chunk; });
      child.on("error", (error) => resolve({ code: -1, errors: error.message }));
      child.on("close", (code) => resolve({ code, errors }));
    });
    if (result.code !== 0) {
      throw Object.assign(new Error(result.errors.trim().slice(0, 400) || "systemd-run failed."), { code: "unavailable" });
    }
    return { started: true, version, unit: `${GUI_UPDATE_UNIT}.service` };
  }
}

// The command for the GUI's terminal that updates a Backup Suite which cannot update
// itself yet (before 1.1: no update verb). In a system install sudo asks for the
// password in that terminal, like agentw-gui's operations; the update then runs in
// its own unit (as root), and the terminal shows its log until it ends.
Updates.prototype.terminalBackendCommand = function terminalBackendCommand(version, mode) {
  if (!parseVersion(version)) throw Object.assign(new Error("version must look like 1.2.3."), { code: "invalid_request" });
  if (!this.available()) throw Object.assign(new Error("This GUI has no updater; install it once more from a release."), { code: "unavailable" });
  const quote = (value) => `'${String(value).replace(/'/g, "'\\''")}'`;
  const python = fs.existsSync("/usr/bin/python3") ? "/usr/bin/python3" : "python3";
  const system = mode !== "user";
  const updater = system ? "/run/backup-suite-update.py" : this.script;
  const steps = [
    "set -e",
    // As root, run a root-owned copy of this GUI's updater, not the one in a home folder.
    system ? `install -m 755 ${quote(this.script)} ${updater}` : "",
    `${this.env.BACKUP_SUITE_SYSTEMCTL || "systemctl"} ${system ? "" : "--user "}reset-failed backup-suite-update.service >/dev/null 2>&1 || true`,
    `${this.systemdRun} ${system ? "" : "--user "}--unit backup-suite-update --collect --quiet --description ${quote(`Backup Suite update to ${version}`)} -- ${python} -I ${updater} apply --version ${version}`,
    "echo 'Started backup-suite-update.service; its log follows. Closing this window does not stop it.'",
    `exec ${python} -I ${updater} follow --version ${version}`
  ].filter(Boolean).join("; ");
  const shell = system
    ? `echo 'sudo asks for your password: type it in the input box below and press Send.'; ${this.env.BACKUP_SUITE_GUI_SUDO || "sudo"} -- sh -c ${quote(steps)}`
    : `sh -c ${quote(steps)}`;
  // The GUI's own unit has NoNewPrivileges (sudo cannot work there) and small
  // limits: run the terminal's command in a transient user unit with its own pty.
  return `${this.systemdRun} --user --pty --quiet --wait --collect --unit backup-suite-gui-terminal --description ${quote("Backup Suite update terminal")} -- sh -c ${quote(shell)}`;
};

module.exports = { Updates, isNewer, parseVersion };
