# Installation

## Install from a release (recommended)

Each release on [GitHub](https://github.com/itechmate-uk/backup-suite/releases) has
`backup-suite-<version>.tar.gz` and its SHA-256 checksum. On the server, as the login
that will use the GUI:

```bash
sha256sum -c backup-suite-<version>.tar.gz.sha256
tar -xzf backup-suite-<version>.tar.gz
cd backup-suite-<version>
sudo ./install.sh --install-deps
```

What `install.sh` does:

- **Mode.** With `sudo`: a system install (scripts in `/opt/backup-suite`, source in
  `/opt/backup-suite-src`, config in `/etc/backup-suite`, state in
  `/var/lib/backup-suite`); backups run as root. Without `sudo`: a user install
  (source in `~/.local/share/backup-suite-src`, config in `~/.config/backup-suite`);
  backups run as you.
- **Packages.** It needs rclone, python3, curl, flock, setfacl (system install) and
  Node.js 18 or newer (for the GUI). `--install-deps` installs what is missing with
  apt-get or dnf; otherwise it lists them and stops.
- **First install.** A starting configuration: `global.conf` from the example and
  empty `file-sources.conf`, `database-backups.conf` and `rclone.conf`; then
  `setup.sh`, which installs the scripts, the systemd units (timers stay off) and, in
  a system install, the GUI's control broker.
- **Upgrade** (Backup Suite already installed). A system install is upgraded with
  `production-deploy.sh`: it waits for a running backup (`--stop-running` stops it
  instead), keeps the configuration, credentials and the current resource setup
  (adaptive or fixed), runs the tests first and rolls back on failure. A user install
  is refreshed with `setup.sh --refresh-scripts --refresh-units`; its configuration
  is kept.
- **GUI.** It never runs as root. By default a systemd user service of the GUI
  admin: the user who ran `sudo`, or `--gui-admin LOGIN`; the installer sets it up
  as that login and turns on linger, so the GUI runs while nobody is logged in.
  `./install.sh --gui-only` (no sudo) installs or updates only your own GUI.
  `sudo ./install.sh --gui-system` installs one system-wide GUI instead (a system
  service run by the unprivileged account `backup-suite-gui`, for the members of the
  group `backup-suite-gui`). `--no-gui` skips the GUI.

Options: `--gui-admin LOGIN`, `--gui-only`, `--gui-system`, `--no-gui`,
`--install-deps`, `--profile NAME`, `--floor NAME`, `--fixed`, `--stop-running`,
`--dry-run` (first install only).

### Updates

After the first install, update from the GUI: **Admin → Updates** (the top bar
shows **Update available** when a newer release is out). It updates Backup Suite
first, then the GUI, from this project's GitHub releases:

- Only the latest published release can be installed, never an older one, and the
  download address is fixed in `bin/backup-suite-update.py`; the GUI cannot pass one.
- The archive must match the SHA-256 published with it, and every file in it must
  stay inside its folder; otherwise nothing is installed.
- Backup Suite is updated by the release's own `install.sh` in a transient unit
  (`backup-suite-update.service`, as root in a system install, started by the
  control broker), so the update survives the GUI restarting. In a system install
  that is `production-deploy.sh`: it waits for a running backup (or stops it, if
  chosen), runs the tests, and rolls back on failure. The status and log are in
  `<state>/updates/`.
- Your GUI updates itself as your login (`backup-suite-gui-update.service`); if the
  new GUI does not start, the previous copy (`~/.local/share/backup-suite-gui/app.previous`)
  is put back. By hand: `~/.local/share/backup-suite-gui/app/scripts/backup-suite-gui-server rollback`.

Running `install.sh` from a newer release still works as well.

After installing, as the GUI admin:

```bash
~/.local/share/backup-suite-gui/app/scripts/backup-suite-gui-server status
```

shows every way to connect (Tunnel Manager profile, launchers, phone, `ssh -L`). In
the GUI: add a destination (Admin → Destinations), set it as the default (Admin →
All settings → `RCLONE_REMOTE_ROOT`), add a backup job (+ New job), and switch the
schedule on (Admin → Actions & schedule). See [GUI.md](GUI.md).

### Making a release

Set the version in `VERSION` and `gui/package.json`, add release notes as
`docs/releases/v<version>.md`, commit, then tag and push:

```bash
git tag -a v1.0.0 -m "Backup Suite 1.0.0"
git push origin v1.0.0
```

The Release workflow (`.github/workflows/release.yml`) checks the source, runs the GUI
tests, builds the archive with `git archive` and publishes the release with it.

## Manual setup

The rest of this page describes `setup.sh` itself, for installing from a checkout
with your own configuration.

## Directory Layout

Source suite tree:

- `/home/user/tools/backup-suite`

Installed suite defaults depend on mode.

System mode defaults:

- scripts: `/opt/backup-suite`
- canonical source: `/opt/backup-suite-src`
- config: `/etc/backup-suite`
- state: `/var/lib/backup-suite`
- local DB dumps: `/var/backups/backup-suite/databases`

User mode defaults:

- scripts: `~/.local/share/backup-suite`
- config: `~/.config/backup-suite`
- state: `~/.local/state/backup-suite`
- local DB dumps: `~/backups/backup-suite/databases`

## Config Files

This repository ships only example config files.

When used as a live deployment tree, the canonical config files are:

- `global.conf`
- `file-sources.conf`
- `database-backups.conf`
- `rclone.conf`
- `mysql-profiles/*.cnf`

In user mode, setup deploys runtime config into `~/.config/backup-suite`.

In system mode, setup copies the suite source tree into `/opt/backup-suite-src`, then symlinks `/etc/backup-suite` back to that copied canonical source tree.

Example files remain alongside them for reference.

## Setup Script

Script:

- `/home/user/tools/backup-suite/setup.sh`

If the suite was downloaded or extracted from an archive and executable bits were not preserved, fix them once before running setup:

```bash
chmod 755 /home/user/tools/backup-suite/setup.sh /home/user/tools/backup-suite/bin/*.sh
```

Run it yourself after editing the real config files:

```bash
sudo /home/user/tools/backup-suite/setup.sh --dry-run
sudo /home/user/tools/backup-suite/setup.sh
```

In system-mode dry runs, the script previews deployment into `/opt/backup-suite-src` but reads templates and config from the current source tree during the preview. That avoids false errors when the target canonical source tree does not exist yet.

If you run setup without `sudo`, the suite can install itself in user mode automatically.

User mode example:

```bash
/home/user/tools/backup-suite/setup.sh --dry-run
/home/user/tools/backup-suite/setup.sh
```

If you run setup with `sudo` or while logged in directly as `root`, and `INSTALL_MODE="auto"`, the script first detects that system-wide installation is possible and then asks you to choose:

- `system` to install system-wide
- `cancel` to stop and re-run the script without `sudo` as the target user for a user-mode install

Optional refresh modes:

```bash
sudo /home/user/tools/backup-suite/setup.sh --refresh-scripts
sudo /home/user/tools/backup-suite/setup.sh --refresh-config
sudo /home/user/tools/backup-suite/setup.sh --refresh-units
```

## Setup Script Flags

Common `setup.sh` flags:

- `--dry-run`
	- preview what the setup script would do without writing changes

- `--refresh-scripts`
	- replace installed runtime scripts from the current source tree

- `--refresh-config`
	- refresh deployed config files or config symlinks from the source tree

- `--refresh-units`
	- regenerate and overwrite installed systemd service and timer units

- `--yes`
	- skip interactive confirmation prompts for overwrite operations that would otherwise ask first

Example combined refresh command:

```bash
sudo /home/user/tools/backup-suite/setup.sh --refresh-scripts --refresh-units --yes
```

This means:

- refresh installed scripts
- refresh installed systemd units
- do not stop for overwrite confirmation prompts

For the `--copy-links` to `--links` migration, keep `file-backup.timer` disabled while refreshing scripts/units and while running the migration dry-run and restore tests. Refreshing units does not enable a disabled timer. Enable it only after the explicit confirmed migration succeeds.

Overwrite behavior:

- existing installed files are kept by default
- refresh flags enable replacement attempts for that category only
- overwrite requires explicit confirmation unless you also pass `--yes`

Install mode behavior:

- `INSTALL_MODE="auto"` offers system-mode installation when run with `sudo` or while logged in directly as `root`
- `INSTALL_MODE="auto"` selects user mode when run without `sudo`
- you can force `INSTALL_MODE="user"` or `INSTALL_MODE="system"` in the config
- when run as root with `INSTALL_MODE="auto"`, the script asks for explicit confirmation before choosing system mode
- `INSTALL_MODE="user"` is not allowed when running with `sudo` or while logged in directly as `root`; for per-user installation, run the setup script as that user without `sudo`

## What the Setup Script Can Do

- install the suite under `/opt/backup-suite`
- in system mode, copy the suite source tree into `/opt/backup-suite-src`
- deploy runtime config symlinks into `/etc/backup-suite` or `~/.config/backup-suite`
- in system mode, add the canonical `/opt/backup-suite-src` source to file backup config as disabled by default if it is not already present
- install systemd service and timer units
- optionally enable the timers

In user mode, the setup script:

- installs into your home directory
- deploys config into your home config directory
- installs user-level units under `~/.config/systemd/user`
- uses `systemctl --user`
- assumes `rclone` is already installed and available in your PATH
- does not attempt to expand your permissions beyond what your user can already access

## Prerequisites

For both system mode and user mode, this suite assumes these commands are already installed and available:

- `rclone`
- `mysql`
- `mysqldump`

Optional but recommended:

- `zstd`

For user mode specifically, `rclone` is not installed by the setup script. It must already be installed for that user environment and available in the user's PATH.

User-level `rclone` install example for a user such as `web10`:

Check architecture:

```bash
uname -m
```

Example for `x86_64`:

```bash
mkdir -p "$HOME/tools/rclone" "$HOME/bin"
cd "$HOME/tools/rclone"
curl -LO https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -o rclone-current-linux-amd64.zip
cp rclone-*-linux-amd64/rclone "$HOME/bin/rclone"
chmod 755 "$HOME/bin/rclone"
```

Add it to PATH:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
. "$HOME/.bashrc"
```

Verify:

```bash
command -v rclone
rclone version
```
