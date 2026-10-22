#!/bin/bash
#
# Installs or upgrades Backup Suite from a release (or a checkout), GUI included.
#
#   sudo ./install.sh     system install: backups run as root and may back up any
#                         folder under FILE_JOB_SOURCE_ROOTS (/home /var/www /srv /opt)
#   ./install.sh          user install: backups run as you, for your own files
#   ./install.sh --gui-only
#                         only the GUI, for your login, without sudo
#
# The GUI never runs as root. By default it is a user service of the admin
# login (like agentw-gui); --gui-system installs one shared system service run
# by its own unprivileged account instead.
#
# A first install creates a starting configuration (no backup jobs, no
# destinations) and installs the GUI; everything else is set up in the GUI.
# Updates are installed from the GUI (the Updates button); running this again
# from a newer release upgrades too, keeping the configuration, credentials
# and the resource setup.

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VERSION=$(cat "$SOURCE_DIR/VERSION" 2>/dev/null || echo unknown)
SYSTEM_INSTALL_DIR="/opt/backup-suite"
SYSTEM_CANONICAL_DIR="/opt/backup-suite-src"
SYSTEM_CONFIG_DIR="/etc/backup-suite"
USER_CANONICAL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/backup-suite-src"
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/backup-suite"
NODE_MIN_MAJOR=18

INSTALL_GUI=1
USER_GUI=1
SYSTEM_GUI=0
GUI_ONLY=0
SYSTEM_GUI_UNIT="/etc/systemd/system/backup-suite-gui.service"
INSTALL_DEPS=0
DRY_RUN=0
GUI_ADMINS=()
DEPLOY_ARGS=()
STAGING_DIR=""
FRESH_INSTALL=0

usage() {
    cat <<'EOF'
Usage: sudo ./install.sh [options]     the recommended setup: Backup Suite for the
                                       whole server (as root) and a GUI that runs
                                       as your login (no root)
       sudo ./install.sh --gui-system  optional: one shared GUI service instead
       ./install.sh [options]          optional: a user install, no root at all
                                       (your own files only)
       ./install.sh --gui-only         only the GUI, for your login (no sudo)

Installs Backup Suite and its browser GUI, or upgrades an existing install
(configuration, credentials and resource setup are kept). The GUI never runs
as root: it is a user service of the admin login, or with --gui-system one
system service run by the unprivileged account backup-suite-gui.

Options:
  --gui-admin LOGIN  a login that may use the GUI (system install; repeatable;
                     default: the user who ran sudo). The first one gets its
                     own GUI service, unless --gui-system.
  --gui-system       one GUI for the whole server (system service, shared by the
                     members of group backup-suite-gui) instead of a per-login GUI
  --gui-only         install or update only the GUI
  --no-gui           do not install the GUI
  --no-user-gui      do not install a per-login GUI (a system-wide GUI that is
                     installed is still updated; used by the updater)
  --install-deps     install missing packages with apt-get or dnf
                     (rclone, python3, nodejs, curl, acl)
  --profile NAME     resource profile slow|moderate|fast (upgrade: default keeps
                     the current one)
  --floor NAME       adaptive floor slow|moderate (upgrade: default keeps the
                     current one)
  --fixed            use a single profile, no adaptive stepping
  --stop-running     upgrade: stop a running backup instead of waiting for it
  --dry-run          first install only: show what would be done, change nothing
  -h, --help         show this help
EOF
}

log() {
    printf '[backup-suite-install] %s\n' "$*"
}

die() {
    printf '[backup-suite-install] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --gui-admin)
            [ "$#" -ge 2 ] || die "--gui-admin needs a login"
            GUI_ADMINS+=("$2")
            shift
            ;;
        --no-gui) INSTALL_GUI=0 ;;
        --no-user-gui) USER_GUI=0 ;;
        --gui-system) SYSTEM_GUI=1; USER_GUI=0 ;;
        --gui-only) GUI_ONLY=1 ;;
        --install-deps) INSTALL_DEPS=1 ;;
        --profile|--floor)
            [ "$#" -ge 2 ] || die "$1 needs a value"
            DEPLOY_ARGS+=("$1" "$2")
            shift
            ;;
        --fixed|--stop-running) DEPLOY_ARGS+=("$1") ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

for required in setup.sh production-deploy.sh bin/common.sh bin/backup-control.py config/global.conf.example gui/server.js gui/scripts/backup-suite-gui-server; do
    [ -e "$SOURCE_DIR/$required" ] || die "$SOURCE_DIR/$required is missing; extract the whole release archive and run install.sh from it."
done

if [ "$(id -u)" -eq 0 ]; then
    MODE="system"
else
    MODE="user"
fi

# ---------------------------------------------------------------- packages

node_major() {
    "$1" -e 'process.stdout.write(String(process.versions.node.split(".")[0]))' 2>/dev/null || printf '0'
}

find_node() {
    local candidate
    for candidate in "${BACKUP_SUITE_GUI_NODE:-}" /usr/bin/node /usr/local/bin/node "$(command -v node 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        if [ "$(node_major "$candidate")" -ge "$NODE_MIN_MAJOR" ]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

missing_packages() {
    local missing=()
    command -v rclone >/dev/null 2>&1 || missing+=(rclone)
    command -v python3 >/dev/null 2>&1 || missing+=(python3)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v flock >/dev/null 2>&1 || missing+=(util-linux)
    if [ "$MODE" = "system" ]; then
        command -v setfacl >/dev/null 2>&1 || missing+=(acl)
    fi
    if [ "$INSTALL_GUI" -eq 1 ] && ! find_node >/dev/null; then
        missing+=(nodejs)
    fi
    printf '%s\n' "${missing[@]}"
}

install_packages() {
    local packages=("$@")
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "${packages[@]}"
    else
        die "No apt-get or dnf here; install these packages yourself: ${packages[*]}"
    fi
}

check_packages() {
    local missing=()
    local name

    for name in bash systemctl install sed awk find; do
        command -v "$name" >/dev/null 2>&1 || die "Required command not found: $name (Backup Suite needs a systemd Linux host)."
    done
    mapfile -t missing < <(missing_packages | sed '/^$/d')
    [ "${#missing[@]}" -gt 0 ] || return 0

    if [ "$INSTALL_DEPS" -eq 1 ]; then
        [ "$MODE" = "system" ] || die "--install-deps needs sudo. Missing: ${missing[*]}"
        log "Installing: ${missing[*]}"
        install_packages "${missing[@]}"
        mapfile -t missing < <(missing_packages | sed '/^$/d')
        if [ "${#missing[@]}" -gt 0 ]; then
            if printf '%s\n' "${missing[@]}" | grep -qx nodejs; then
                die "Node.js $NODE_MIN_MAJOR or newer is needed for the GUI, but this system's package is older. Install Node.js $NODE_MIN_MAJOR+ (https://nodejs.org or NodeSource), or use --no-gui."
            fi
            die "Still missing after installing: ${missing[*]}"
        fi
        return 0
    fi

    {
        echo "Missing packages: ${missing[*]}"
        echo "Install them with:  sudo ./install.sh --install-deps   (apt-get or dnf)"
        echo "or yourself, for example: sudo apt-get install ${missing[*]}"
        if printf '%s\n' "${missing[@]}" | grep -qx nodejs; then
            echo "The GUI needs Node.js $NODE_MIN_MAJOR or newer (or install without it: --no-gui)."
        fi
    } >&2
    exit 1
}

# ---------------------------------------------------------- configuration

# A starting configuration: global.conf from the example, no jobs, no
# databases, no destinations. Existing files are never touched.
write_starting_config() {
    local config_dir="$1"

    install -d -m 750 "$config_dir" "$config_dir/mysql-profiles"
    if [ ! -f "$config_dir/global.conf" ]; then
        install -m 600 "$config_dir/global.conf.example" "$config_dir/global.conf"
    fi
    if [ ! -f "$config_dir/file-sources.conf" ]; then
        cat > "$config_dir/file-sources.conf" <<'EOF'
# Backup jobs, one per line. Add and edit them in the GUI (+ New job), or see
# file-sources.conf.example for the format.
EOF
        chmod 600 "$config_dir/file-sources.conf"
    fi
    if [ ! -f "$config_dir/database-backups.conf" ]; then
        cat > "$config_dir/database-backups.conf" <<'EOF'
# Database backups, one per line. See database-backups.conf.example for the format.
EOF
        chmod 600 "$config_dir/database-backups.conf"
    fi
    if [ ! -f "$config_dir/rclone.conf" ]; then
        cat > "$config_dir/rclone.conf" <<'EOF'
# Destinations (rclone remotes). Add them in the GUI: Admin -> Destinations.
EOF
        chmod 600 "$config_dir/rclone.conf"
    fi
}

# A copy of the release without version-control files and without any config
# the source tree may carry, so only the starting configuration is installed.
copy_release() {
    local target="$1"

    install -d -m 755 "$target"
    tar -C "$SOURCE_DIR" --exclude=./.git --exclude=./config/global.conf --exclude=./config/file-sources.conf \
        --exclude=./config/database-backups.conf --exclude=./config/rclone.conf --exclude='./config/mysql-profiles/*.cnf' \
        --exclude=./tmp --exclude=./.ai-metadata -cf - . | tar -C "$target" -xf -
}

fix_modes() {
    local tree="$1"
    chmod 755 "$tree/install.sh" "$tree/setup.sh" "$tree/production-deploy.sh" "$tree/production-file-backup-migrate.sh" \
        "$tree"/bin/*.sh "$tree"/bin/*.py "$tree"/gui/scripts/backup-suite-gui-server "$tree"/gui/scripts/backup-suite-gui-watchdog \
        "$tree/tests/run.sh" 2>/dev/null || true
}

# ---------------------------------------------------------------- the GUI

# install_gui_as <login> <gui source dir>
install_gui_as() {
    local login="$1"
    local gui_dir="$2"
    local uid home runtime_dir waited=0

    uid=$(id -u "$login")
    home=$(getent passwd "$login" | cut -d: -f6)
    runtime_dir="/run/user/$uid"
    if [ ! -S "$runtime_dir/bus" ]; then
        # The GUI is a user service of the admin login; it needs that login's
        # systemd manager, also while nobody is logged in (linger).
        log "Enabling linger for $login so the GUI runs with nobody logged in."
        loginctl enable-linger "$login"
        while [ ! -S "$runtime_dir/bus" ] && [ "$waited" -lt 20 ]; do
            sleep 1
            waited=$((waited + 1))
        done
        [ -S "$runtime_dir/bus" ] || die "The systemd user manager of $login did not start. Log in as $login and run: $gui_dir/scripts/backup-suite-gui-server install"
    fi
    runuser -u "$login" -- env -i HOME="$home" USER="$login" LOGNAME="$login" PATH="/usr/local/bin:/usr/bin:/bin" \
        XDG_RUNTIME_DIR="$runtime_dir" DBUS_SESSION_BUS_ADDRESS="unix:path=$runtime_dir/bus" \
        ${BACKUP_SUITE_GUI_NODE:+BACKUP_SUITE_GUI_NODE="$BACKUP_SUITE_GUI_NODE"} \
        bash "$gui_dir/scripts/backup-suite-gui-server" install
}

# A GUI admin must be in the broker's group; the socket's ACL lets a running
# GUI connect at once (a new group membership alone needs a new login).
grant_broker_access() {
    local login="$1"
    getent group backup-suite-gui >/dev/null || return 0
    if ! id -nG "$login" | tr ' ' '\n' | grep -Fxq backup-suite-gui; then
        usermod -a -G backup-suite-gui "$login"
        log "Added $login to backup-suite-gui, so its GUI may use the control broker."
    fi
    if [ -x "$SYSTEM_INSTALL_DIR/bin/install-gui-broker.sh" ] && [ -S /run/backup-suite/control.sock ]; then
        "$SYSTEM_INSTALL_DIR/bin/install-gui-broker.sh" --refresh-acl || true
    fi
}

install_gui_system() {
    local login="${GUI_ADMINS[0]}"
    local gui_copy

    grant_broker_access "$login"

    # The admin login must be able to read the GUI it copies; the release may
    # sit where only root can read it, so hand it a private copy.
    STAGING_DIR=$(mktemp -d /tmp/backup-suite-gui-install.XXXXXX)
    gui_copy="$STAGING_DIR/gui"
    cp -a "$SOURCE_DIR/gui" "$gui_copy"
    chown -R "$login": "$STAGING_DIR"
    chmod 700 "$STAGING_DIR"
    log "Installing the GUI as $login."
    install_gui_as "$login" "$gui_copy"
}

install_gui_systemwide() {
    log "Installing the system-wide GUI (run by the account backup-suite-gui)."
    fix_modes "$SOURCE_DIR"
    bash "$SOURCE_DIR/gui/scripts/backup-suite-gui-server" install --system
    for admin in "${GUI_ADMINS[@]}"; do
        if ! id -nG "$admin" | tr ' ' '\n' | grep -Fxq backup-suite-gui; then
            usermod -a -G backup-suite-gui "$admin"
            log "Added $admin to backup-suite-gui (it may use the GUI after logging in again)."
        fi
    done
}

system_gui_next_steps() {
    cat <<'TEXT'

Open the GUI: it listens on /run/backup-suite-gui/gui.sock, for the members of
the group backup-suite-gui. From your computer, as one of them:
  ssh -N -L 127.0.0.1:14337:/run/backup-suite-gui/gui.sock LOGIN@SERVER
then open http://127.0.0.1:14337/ (the GUI's Ways to connect has a Tunnel
Manager profile and launchers too).
TEXT
}

gui_next_steps() {
    local who="$1"
    local script="~/.local/share/backup-suite-gui/app/scripts/backup-suite-gui-server"
    cat <<EOF

Open the GUI (as $who):
  $script status
shows every way to connect: a Tunnel Manager profile to import, launcher
scripts for Windows, macOS and Linux, phone apps, or one ssh -L command.
The GUI listens only on a private socket on this server and is reached
through an SSH tunnel.
EOF
}

first_steps() {
    cat <<'EOF'

First steps in the GUI:
  1. Admin -> Destinations: add where backups go (Google Drive, Dropbox,
     OneDrive, S3, ...).
  2. Admin -> All settings: set RCLONE_REMOTE_ROOT, the default destination
     (for example mydrive:server-backups).
  3. + New job: pick a folder to back up.
  4. Admin -> Actions & schedule: switch the file backup schedule on.
  Optional: Admin -> Notifications (ntfy) to be told about failures.
EOF
}

# ------------------------------------------------------------- the install

log "Backup Suite $VERSION, $MODE install, from $SOURCE_DIR"

[ "$SYSTEM_GUI" -eq 0 ] || [ "$MODE" = "system" ] || die "--gui-system needs sudo."
[ "$INSTALL_GUI" -eq 1 ] || [ "$GUI_ONLY" -eq 0 ] || die "--gui-only and --no-gui exclude each other."
if [ -f "$SYSTEM_GUI_UNIT" ] && [ "$MODE" = "system" ] && [ "$INSTALL_GUI" -eq 1 ]; then
    # A system-wide GUI is installed: keep that one, do not add a per-login GUI.
    SYSTEM_GUI=1
    USER_GUI=0
fi
if [ "$MODE" = "system" ] && [ "$INSTALL_GUI" -eq 1 ] && [ "$USER_GUI" -eq 1 ]; then
    if [ "${#GUI_ADMINS[@]}" -eq 0 ]; then
        if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
            GUI_ADMINS=("$SUDO_USER")
        else
            die "Name the login that will use the GUI: --gui-admin LOGIN (it must not be root), or install without it: --no-gui"
        fi
    fi
    for admin in "${GUI_ADMINS[@]}"; do
        [ "$admin" != "root" ] || die "The GUI admin must be a normal login, not root."
        id -u "$admin" >/dev/null 2>&1 || die "No such login: $admin"
    done
fi

check_packages

if [ "$GUI_ONLY" -eq 1 ]; then
    if [ "$SYSTEM_GUI" -eq 1 ]; then
        install_gui_systemwide
        system_gui_next_steps
    elif [ "$MODE" = "system" ]; then
        install_gui_system
        gui_next_steps "${GUI_ADMINS[0]}"
    else
        fix_modes "$SOURCE_DIR"
        log "Installing the GUI for $(id -un)."
        bash "$SOURCE_DIR/gui/scripts/backup-suite-gui-server" install
        gui_next_steps "$(id -un)"
    fi
    log "The GUI of Backup Suite $VERSION is installed."
    exit 0
fi

if [ "$MODE" = "system" ]; then
    if [ -f "$SYSTEM_CONFIG_DIR/global.conf" ] && [ -d "$SYSTEM_INSTALL_DIR/bin" ]; then
        [ "$DRY_RUN" -eq 0 ] || die "--dry-run is for a first install; for an upgrade run: sudo $SOURCE_DIR/production-deploy.sh --check"
        log "Backup Suite is installed; upgrading it (configuration and credentials are kept)."
        fix_modes "$SOURCE_DIR"
        deploy_admin_args=()
        for admin in "${GUI_ADMINS[@]}"; do
            deploy_admin_args+=(--gui-admin "$admin")
        done
        bash "$SOURCE_DIR/production-deploy.sh" "${DEPLOY_ARGS[@]}" "${deploy_admin_args[@]}"
    else
        [ ! -e "$SYSTEM_CANONICAL_DIR" ] || die "$SYSTEM_CANONICAL_DIR exists but Backup Suite is not fully installed ($SYSTEM_CONFIG_DIR/global.conf or $SYSTEM_INSTALL_DIR/bin is missing). Move it away and run install.sh again."
        FRESH_INSTALL=1
        STAGING_DIR=$(mktemp -d /tmp/backup-suite-install.XXXXXX)
        copy_release "$STAGING_DIR/src"
        fix_modes "$STAGING_DIR/src"
        write_starting_config "$STAGING_DIR/src/config"
        setup_args=(--yes)
        [ "$DRY_RUN" -eq 0 ] || setup_args+=(--dry-run)
        for admin in "${GUI_ADMINS[@]}"; do
            setup_args+=(--gui-admin "$admin")
        done
        log "Installing into $SYSTEM_INSTALL_DIR (source $SYSTEM_CANONICAL_DIR, config $SYSTEM_CONFIG_DIR)."
        bash "$STAGING_DIR/src/setup.sh" "${setup_args[@]}"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "Dry run: nothing was changed."
            exit 0
        fi
        if [ "${#DEPLOY_ARGS[@]}" -gt 0 ]; then
            profile_args=()
            set -- "${DEPLOY_ARGS[@]}"
            profile="" floor="" fixed=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --profile) profile="$2"; shift ;;
                    --floor) floor="$2"; shift ;;
                    --fixed) fixed=1 ;;
                esac
                shift
            done
            profile="${profile:-moderate}"
            if [ -n "$floor" ] && [ "$fixed" -eq 0 ]; then
                BACKUP_SUITE_CONFIG_DIR="$SYSTEM_CONFIG_DIR" "$SYSTEM_INSTALL_DIR/bin/backup-profile.sh" adaptive "$profile" "$floor"
            else
                BACKUP_SUITE_CONFIG_DIR="$SYSTEM_CONFIG_DIR" "$SYSTEM_INSTALL_DIR/bin/backup-profile.sh" set "$profile"
            fi
        fi
        rm -rf "$STAGING_DIR"
        STAGING_DIR=""
    fi
    if [ "$INSTALL_GUI" -eq 1 ] && [ "$SYSTEM_GUI" -eq 1 ]; then
        install_gui_systemwide
        [ "$FRESH_INSTALL" -eq 0 ] || system_gui_next_steps
    elif [ "$INSTALL_GUI" -eq 1 ] && [ "$USER_GUI" -eq 1 ]; then
        install_gui_system
        gui_next_steps "${GUI_ADMINS[0]}"
    fi
else
    if [ -f "$USER_CONFIG_DIR/global.conf" ]; then
        [ "$DRY_RUN" -eq 0 ] || die "--dry-run is for a first install."
        current_tree=$(cd -- "$(dirname -- "$(readlink -f "$USER_CONFIG_DIR/global.conf")")/.." && pwd)
        log "Backup Suite is installed from $current_tree; upgrading it (configuration and credentials are kept)."
        if [ "$current_tree" != "$SOURCE_DIR" ]; then
            [ ! -d "$current_tree/.git" ] || die "That install runs from a git checkout. Update it there: git -C $current_tree pull && $current_tree/setup.sh --refresh-scripts --refresh-units --yes"
            copy_release "$current_tree"
        fi
        fix_modes "$current_tree"
        "$current_tree/setup.sh" --refresh-scripts --refresh-units --yes
    else
        [ ! -e "$USER_CANONICAL_DIR" ] || die "$USER_CANONICAL_DIR exists but $USER_CONFIG_DIR/global.conf does not. Move it away and run install.sh again."
        FRESH_INSTALL=1
        current_tree="$USER_CANONICAL_DIR"
        if [ "$DRY_RUN" -eq 1 ]; then
            STAGING_DIR=$(mktemp -d)
            current_tree="$STAGING_DIR/src"
        fi
        copy_release "$current_tree"
        fix_modes "$current_tree"
        write_starting_config "$current_tree/config"
        setup_args=(--yes)
        [ "$DRY_RUN" -eq 0 ] || setup_args+=(--dry-run)
        log "Installing for $(id -un) (source $USER_CANONICAL_DIR, config $USER_CONFIG_DIR)."
        "$current_tree/setup.sh" "${setup_args[@]}"
        if [ "$DRY_RUN" -eq 1 ]; then
            log "Dry run: nothing was changed."
            exit 0
        fi
    fi
    if [ "$INSTALL_GUI" -eq 1 ] && [ "$USER_GUI" -eq 1 ]; then
        log "Installing the GUI."
        "$current_tree/gui/scripts/backup-suite-gui-server" install
        gui_next_steps "$(id -un)"
    fi
fi

[ "$FRESH_INSTALL" -eq 0 ] || first_steps
log "Backup Suite $VERSION is installed."
