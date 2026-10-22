#!/usr/bin/env python3
"""Backup Suite updater: finds, downloads, verifies and installs a release.

Releases come only from this project's GitHub releases. Only the latest
published release (not a draft or a pre-release) can be installed, and only
when it is newer than the installed version. The archive must match the
SHA-256 published with it, and every file in it must stay inside its
top-level folder.

    backup-suite-update.py check  --current VERSION
    backup-suite-update.py apply  --version VERSION [--state-dir DIR] [--stop-running]
        updates Backup Suite: runs the release's install.sh (as root: the
        system install and a system-wide GUI; as a user: the user install)
    backup-suite-update.py gui-apply --version VERSION [--state-dir DIR]
        updates this login's GUI: runs the release's backup-suite-gui-server install
    backup-suite-update.py follow --version VERSION [--state-dir DIR]
        prints that update's log as it grows, until it ends
    backup-suite-update.py status [--state-dir DIR]

Without --state-dir: /var/lib/backup-suite/updates as root, else
~/.local/state/backup-suite/updates (Backup Suite's default state folders).

Every command prints one JSON object. Standard library only.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request

REPOSITORY = "itechmate-uk/backup-suite"
# Overridable for tests only; a GUI can never pass them (the control script runs
# with the broker unit's environment, and the GUI starts this with its own).
LATEST_URL = os.environ.get("BACKUP_SUITE_UPDATE_LATEST_URL",
                            "https://api.github.com/repos/%s/releases/latest" % REPOSITORY)
DOWNLOAD_BASE = os.environ.get("BACKUP_SUITE_UPDATE_DOWNLOAD_BASE",
                               "https://github.com/%s/releases/download/" % REPOSITORY)
VERSION_RE = re.compile(r"^(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,4})\.(0|[1-9][0-9]{0,5})$")
MAX_ARCHIVE_BYTES = 100 * 1024 * 1024
MAX_SMALL_BYTES = 1024 * 1024
HTTP_TIMEOUT = 30
KEEP_RELEASES = 2
LOG_TAIL_BYTES = 12000
USER_AGENT = "backup-suite-updater"


class UpdateError(Exception):
    pass


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_version(text):
    match = VERSION_RE.match(str(text or "").strip())
    if not match:
        return None
    return tuple(int(part) for part in match.groups())


def http_get(url, limit):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/vnd.github+json"})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            data = response.read(limit + 1)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise UpdateError("No release is published yet (%s)." % url)
        if error.code in (403, 429):
            raise UpdateError("GitHub refused the request (HTTP %s, probably its hourly limit); try again later." % error.code)
        raise UpdateError("Download failed: HTTP %s for %s" % (error.code, url))
    except (urllib.error.URLError, OSError) as error:
        raise UpdateError("Could not reach %s: %s" % (url.split("/")[2] if "//" in url else url, getattr(error, "reason", error)))
    if len(data) > limit:
        raise UpdateError("%s is larger than expected." % url)
    return data


def latest_release():
    """The latest published release: its version, archive and checksum URLs."""
    try:
        release = json.loads(http_get(LATEST_URL, MAX_SMALL_BYTES * 4).decode("utf-8"))
    except ValueError:
        raise UpdateError("GitHub returned an unreadable release description.")
    if not isinstance(release, dict) or release.get("draft") or release.get("prerelease"):
        raise UpdateError("The latest release is not a published release.")
    tag = str(release.get("tag_name") or "")
    version = tag[1:] if tag.startswith("v") else ""
    if not parse_version(version):
        raise UpdateError("The latest release tag %r is not a version (vX.Y.Z)." % tag)
    archive_name = "backup-suite-%s.tar.gz" % version
    wanted = {archive_name: None, archive_name + ".sha256": None}
    prefix = "%s%s/" % (DOWNLOAD_BASE, tag)
    for asset in release.get("assets") or []:
        name = str(asset.get("name") or "")
        url = str(asset.get("browser_download_url") or "")
        if name in wanted:
            if url != prefix + name:
                raise UpdateError("Release file %s is not served from %s." % (name, prefix))
            wanted[name] = {"url": url, "size": int(asset.get("size") or 0)}
    missing = [name for name, asset in wanted.items() if asset is None]
    if missing:
        raise UpdateError("The release %s lacks %s." % (tag, ", ".join(missing)))
    return {
        "version": version,
        "tag": tag,
        "published_at": str(release.get("published_at") or ""),
        "url": str(release.get("html_url") or ""),
        "notes": str(release.get("body") or "")[:6000],
        "archive": wanted[archive_name],
        "checksum": wanted[archive_name + ".sha256"],
        "archive_name": archive_name,
    }


def check(current):
    latest = latest_release()
    current_version = parse_version(current)
    latest_version = parse_version(latest["version"])
    newer = current_version is None or latest_version > current_version
    return {
        "checked_at": now_iso(),
        "current": current or "unknown",
        "latest": latest["version"],
        "tag": latest["tag"],
        "published_at": latest["published_at"],
        "url": latest["url"],
        "notes": latest["notes"],
        "update_available": newer,
    }


def download_verified(release, work_dir):
    """Downloads the archive and its checksum; returns the verified archive path."""
    checksum_text = http_get(release["checksum"]["url"], 4096).decode("utf-8", "replace")
    match = re.match(r"^([0-9a-f]{64})[ \t]+\*?(\S+)\s*$", checksum_text.strip())
    if not match or match.group(2) != release["archive_name"]:
        raise UpdateError("The release checksum file is not in the expected form.")
    expected = match.group(1)
    os.makedirs(work_dir, mode=0o700, exist_ok=True)
    target = os.path.join(work_dir, release["archive_name"])
    partial = target + ".part"
    digest = hashlib.sha256()
    written = 0
    request = urllib.request.Request(release["archive"]["url"], headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response, open(partial, "wb") as handle:
            while True:
                block = response.read(65536)
                if not block:
                    break
                written += len(block)
                if written > MAX_ARCHIVE_BYTES:
                    raise UpdateError("The release archive is larger than %d MB." % (MAX_ARCHIVE_BYTES // 1048576))
                digest.update(block)
                handle.write(block)
    except (urllib.error.URLError, OSError) as error:
        _remove(partial)
        raise UpdateError("Downloading the release failed: %s" % getattr(error, "reason", error))
    except UpdateError:
        _remove(partial)
        raise
    expected_size = release["archive"]["size"]
    if (expected_size and written != expected_size) or digest.hexdigest() != expected:
        _remove(partial)
        raise UpdateError("The downloaded archive does not match the release's SHA-256; nothing was installed.")
    os.replace(partial, target)
    return target


def _remove(path):
    try:
        os.remove(path)
    except OSError:
        pass


def extract_release(archive, version, work_dir):
    """Extracts into work_dir/backup-suite-<version>; refuses anything outside it."""
    top = "backup-suite-%s" % version
    destination = os.path.join(work_dir, top)
    staging = destination + ".extracting"
    shutil.rmtree(staging, ignore_errors=True)
    os.makedirs(staging, mode=0o755)
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            name = member.name
            parts = name.split("/")
            if name.startswith("/") or ".." in parts or (parts[0] != top and name != "pax_global_header"):
                raise UpdateError("The archive holds an unexpected path: %s" % name[:200])
            if not (member.isfile() or member.isdir() or member.issym()) and name != "pax_global_header":
                raise UpdateError("The archive holds an unexpected file type: %s" % name[:200])
            if member.issym():
                link = os.path.normpath(os.path.join(os.path.dirname(name), member.linkname))
                if member.linkname.startswith("/") or not (link == top or link.startswith(top + "/")):
                    raise UpdateError("The archive holds a link that leaves it: %s" % name[:200])
        kept = [member for member in members if member.name != "pax_global_header"]
        if hasattr(tarfile, "data_filter"):
            tar.extractall(staging, members=kept, filter="data")
        else:
            tar.extractall(staging, members=kept)
    extracted = os.path.join(staging, top)
    if not os.path.isfile(os.path.join(extracted, "install.sh")):
        raise UpdateError("The release archive has no install.sh.")
    with open(os.path.join(extracted, "VERSION"), encoding="utf-8") as handle:
        if handle.read().strip() != version:
            raise UpdateError("The release's VERSION file does not say %s." % version)
    shutil.rmtree(destination, ignore_errors=True)
    os.replace(extracted, destination)
    shutil.rmtree(staging, ignore_errors=True)
    return destination


def prune_releases(releases_dir, keep_path):
    """Keeps the installed release and the one before it; removes older ones."""
    keep = {keep_path, keep_path + ".tar.gz"}
    try:
        names = os.listdir(releases_dir)
    except OSError:
        return
    folders = []
    for name in names:
        path = os.path.join(releases_dir, name)
        if path in keep:
            continue
        if os.path.isdir(path) and not path.endswith(".extracting"):
            folders.append(path)
        elif os.path.isdir(path):
            shutil.rmtree(path, ignore_errors=True)
        else:
            _remove(path)
    folders.sort(key=os.path.getmtime, reverse=True)
    for path in folders[KEEP_RELEASES - 1:]:
        shutil.rmtree(path, ignore_errors=True)


# ------------------------------------------------------------------ status

def status_path(state_dir):
    return os.path.join(state_dir, "status.json")


def write_status(state_dir, status):
    os.makedirs(state_dir, mode=0o750, exist_ok=True)
    temporary = status_path(state_dir) + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(status, handle)
    os.replace(temporary, status_path(state_dir))


def read_status(state_dir):
    try:
        with open(status_path(state_dir), encoding="utf-8") as handle:
            status = json.load(handle)
    except (OSError, ValueError):
        return {"state": "idle"}
    log = status.get("log")
    if log:
        try:
            with open(log, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - LOG_TAIL_BYTES))
                status["log_tail"] = handle.read().decode("utf-8", "replace")
        except OSError:
            status["log_tail"] = ""
    return status


def installer_env():
    """A login-like environment for the installer: a systemd unit (the update runs
    in one) has no HOME, USER or LOGNAME, and the installers expect them."""
    import pwd
    env = dict(os.environ)
    entry = pwd.getpwuid(os.getuid())
    env.setdefault("HOME", entry.pw_dir)
    env.setdefault("USER", entry.pw_name)
    env.setdefault("LOGNAME", entry.pw_name)
    env.setdefault("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    return env


def run_logged(command, log_handle, env=None):
    log_handle.write("$ %s\n" % " ".join(command))
    log_handle.flush()
    process = subprocess.run(command, stdout=log_handle, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             env=env if env is not None else installer_env())
    return process.returncode


def gui_came_up(log_handle, unit="backup-suite-gui-4337.service", seconds=20):
    """True once this login's GUI unit is active again after the reinstall."""
    deadline = time.time() + seconds
    while time.time() < deadline:
        time.sleep(2)
        result = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True)
        if result.stdout.strip() == "active":
            time.sleep(3)
            again = subprocess.run(["systemctl", "--user", "is-active", unit], capture_output=True, text=True)
            if again.stdout.strip() == "active":
                log_handle.write("%s is active.\n" % unit)
                return True
    log_handle.write("%s did not become active.\n" % unit)
    return False


def locked(state_dir):
    os.makedirs(state_dir, mode=0o750, exist_ok=True)
    handle = open(os.path.join(state_dir, "update.lock"), "a")
    try:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise UpdateError("Another update is running.")
    return handle


def apply_update(version, state_dir, what, stop_running=False):
    if not parse_version(version):
        raise UpdateError("Not a version: %r" % version)
    lock = locked(state_dir)
    log_path = os.path.join(state_dir, "update-%s-%s.log" % (what, version))
    status = {"state": "running", "what": what, "version": version, "requested": version, "started_at": now_iso(),
              "step": "download", "log": log_path, "pid": os.getpid()}
    write_status(state_dir, status)
    try:
        with open(log_path, "w", encoding="utf-8") as log_handle:
            log_handle.write("%s Updating %s to %s\n" % (now_iso(), what, version))
            release = latest_release()
            if release["version"] != version:
                if parse_version(release["version"]) < parse_version(version):
                    raise UpdateError("The latest release is %s, older than %s; check for updates again." % (release["version"], version))
                # A newer release came out after the check: install that one (only
                # the latest release is ever installed).
                log_handle.write("A newer release is out: installing %s instead of %s.\n" % (release["version"], version))
                status["version"] = release["version"]
                write_status(state_dir, status)
                version = release["version"]
            releases_dir = os.path.join(state_dir, "releases")
            archive = download_verified(release, releases_dir)
            log_handle.write("Downloaded and verified %s (SHA-256 matches).\n" % os.path.basename(archive))
            tree = extract_release(archive, version, releases_dir)
            log_handle.write("Extracted to %s\n" % tree)
            log_handle.flush()
            status["step"] = "install"
            write_status(state_dir, status)
            if what == "backup-suite":
                command = ["bash", os.path.join(tree, "install.sh"), "--no-user-gui"]
                if stop_running:
                    command.append("--stop-running")
                code = run_logged(command, log_handle)
            else:
                code = run_logged(["bash", os.path.join(tree, "gui", "scripts", "backup-suite-gui-server"), "install"], log_handle)
                if code == 0 and not gui_came_up(log_handle):
                    run_logged(["bash", os.path.join(tree, "gui", "scripts", "backup-suite-gui-server"), "rollback"], log_handle)
                    raise UpdateError("The new GUI did not start; the previous GUI was put back.")
            if code != 0:
                raise UpdateError("The installer stopped with exit code %d; see the log. The previous version stays in use." % code)
            prune_releases(releases_dir, tree)
            log_handle.write("%s Done.\n" % now_iso())
        status.update({"state": "done", "step": "done", "finished_at": now_iso()})
        write_status(state_dir, status)
    except UpdateError as error:
        status.update({"state": "failed", "error": str(error), "finished_at": now_iso()})
        write_status(state_dir, status)
        try:
            with open(log_path, "a", encoding="utf-8") as log_handle:
                log_handle.write("%s Failed: %s\n" % (now_iso(), error))
        except OSError:
            pass
        raise
    finally:
        lock.close()
    return status


def follow(version, state_dir, wait_seconds=None):
    """Prints the log of the update to `version` as it grows, until it ends.

    Used in the GUI's terminal after starting the update unit with sudo; exits 0
    when the update finished, 1 when it failed or never started.
    """
    if wait_seconds is None:
        wait_seconds = int(os.environ.get("BACKUP_SUITE_UPDATE_FOLLOW_WAIT", "60"))
    started = time.time()
    log_path = os.path.join(state_dir, "update-backup-suite-%s.log" % version)
    status = {}
    while time.time() - started < wait_seconds:
        status = read_status(state_dir)
        if version in (status.get("requested"), status.get("version")) and status.get("started_at", "") >= time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(started - 10)):
            break
        time.sleep(1)
    else:
        print("The update did not start; see: journalctl -u backup-suite-update.service", flush=True)
        return {"state": "failed", "version": version, "error": "did not start"}
    offset = 0
    while True:
        try:
            with open(log_path, "rb") as handle:
                handle.seek(offset)
                chunk = handle.read()
                offset += len(chunk)
            if chunk:
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
        except OSError:
            pass
        status = read_status(state_dir)
        if status.get("state") != "running":
            break
        time.sleep(1)
    status.pop("log_tail", None)
    return status


def default_state_dir():
    """Backup Suite's own update folder: the system one as root, else the user's."""
    if os.getuid() == 0:
        return "/var/lib/backup-suite/updates"
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "backup-suite", "updates")


def main():
    parser = argparse.ArgumentParser(description="Backup Suite updater")
    sub = parser.add_subparsers(dest="command", required=True)
    check_parser = sub.add_parser("check")
    check_parser.add_argument("--current", default="")
    for name in ("apply", "gui-apply"):
        apply_parser = sub.add_parser(name)
        apply_parser.add_argument("--version", required=True)
        apply_parser.add_argument("--state-dir", default="")
        if name == "apply":
            apply_parser.add_argument("--stop-running", action="store_true")
    follow_parser = sub.add_parser("follow")
    follow_parser.add_argument("--version", required=True)
    follow_parser.add_argument("--state-dir", default="")
    status_parser = sub.add_parser("status")
    status_parser.add_argument("--state-dir", default="")
    args = parser.parse_args()
    if not args.command == "check" and not args.state_dir:
        args.state_dir = default_state_dir()
    os.umask(0o022)
    try:
        if args.command == "check":
            result = check(args.current)
        elif args.command == "apply":
            result = apply_update(args.version, args.state_dir, "backup-suite", args.stop_running)
        elif args.command == "gui-apply":
            result = apply_update(args.version, args.state_dir, "gui")
        elif args.command == "follow":
            result = follow(args.version, args.state_dir)
            print("")
            print(json.dumps({"ok": result.get("state") == "done", "data": result}))
            return 0 if result.get("state") == "done" else 1
        else:
            result = read_status(args.state_dir)
        print(json.dumps({"ok": True, "data": result}))
        return 0
    except UpdateError as error:
        print(json.dumps({"ok": False, "error": str(error)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
