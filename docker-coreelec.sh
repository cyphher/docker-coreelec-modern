#!/bin/bash
# docker-coreelec - a modern, 64-bit Docker Engine for CoreELEC
# https://github.com/cyphher/docker-coreelec-modern
# SPDX-License-Identifier: MIT
#
# Installs the official static aarch64 Docker binaries from download.docker.com,
# plus Docker Compose v2 and Buildx, into /storage/.docker. Nothing is compiled.
#
#   bash docker-coreelec.sh status       show what is installed and what is available
#   bash docker-coreelec.sh install      fresh install, migrate from the Kodi Docker add-on,
#                                        upgrade tamusiunas/docker-coreelec, or update
#   bash docker-coreelec.sh rollback     restore the state from before the last install/update
#   bash docker-coreelec.sh uninstall    remove this Docker (keeps images, containers, volumes)
#   bash docker-coreelec.sh self-update  get the newest version of this script
#
# See README.md for all options.

TOOL_VERSION="1.0.1"
REPO_URL="https://github.com/cyphher/docker-coreelec-modern"
RAW_URL="https://raw.githubusercontent.com/cyphher/docker-coreelec-modern/main/docker-coreelec.sh"

set -u

# ---------------------------------------------------------------- paths
# DCE_ROOT is only used by the test suite to run everything inside a scratch directory.
R=${DCE_ROOT:-}

BASE=$R/storage/.docker
BIN=$BASE/bin
PLUG=$BASE/cli-plugins
DEFAULT_DATA_ROOT=$BASE/data-root
CONF_DIR=$R/storage/.config/docker
CONF=$CONF_DIR/daemon.json
SYSD=$R/storage/.config/system.d
SVC_NAME=service.system.docker.service
SVC=$SYSD/$SVC_NAME
BACKUPS=$BASE/backup
TMP=$BASE/update-tmp
MARKER=$BASE/.docker-coreelec-modern
SELF_COPY=$BASE/docker-coreelec.sh
LOG=$R/storage/docker-coreelec.log
LOCK=$R/var/run/docker-coreelec.lock
PROFILE=$R/storage/.profile

ADDON_ID=service.system.docker
ADDON_DIR=$R/storage/.kodi/addons/$ADDON_ID
ADDON_DATA=$R/storage/.kodi/userdata/addon_data/$ADDON_ID
ADDON_CONF=$ADDON_DATA/config/docker.conf

STATIC_URL=https://download.docker.com/linux/static/stable/aarch64
KEEP_BACKUPS=${KEEP_BACKUPS:-3}
WAIT_TRIES=${WAIT_TRIES:-60}            # x 2 s waiting for dockerd
SETTLE_SECONDS=${SETTLE_SECONDS:-20}    # time containers get to come up before checking
MIN_FREE_MB=500
META_ITEMS="containers image network engine-id containerd/daemon/io.containerd.metadata.v1.bolt"
OBSOLETE_BINS="rootlesskit rootlesskit-docker-proxy dockerd-rootless.sh dockerd-rootless-setuptool.sh vpnkit"
PASS_ENV="DOCKER_VERSION COMPOSE_VERSION BUILDX_VERSION MIN_API_VERSION FORCE PURGE DCE_ROOT
WAIT_TRIES SETTLE_SECONDS KEEP_BACKUPS http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
no_proxy NO_PROXY CURL_CA_BUNDLE DCE_TEST_FAIL"

export PATH="$BIN:$PATH"
export HOME=$R/storage

FAILED=""
ASSUME_YES=0
PURGE=${PURGE:-0}
PHASE=""          # "" -> nothing touched, stopped -> engine stopped, changed -> files changed
RECOVERING=0
BACKUP_DIR=""

# ---------------------------------------------------------------- output

log()  { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }
warn() { log "WARNING: $*"; }
say()  { echo "$*"; }

die() {
    log "ERROR: $*"
    recover
    exit 1
}

fail_point() {   # used by the test suite to simulate failures at specific moments
    [ "${DCE_TEST_FAIL:-}" = "$1" ] && die "simulated failure at '$1'"
    return 0
}

usage() {
    cat <<EOF
docker-coreelec $TOOL_VERSION - modern 64-bit Docker for CoreELEC
$REPO_URL

Usage: bash $0 <command> [-y]

Commands:
  status       Show the current setup, versions and 32-bit containers
  install      Install, migrate or update to the latest stable Docker
  update       Same as install
  rollback     Restore the state from before the last install/update
  uninstall    Remove Docker (images, containers and volumes are kept)
               add --purge to delete them and the backups as well
  self-update  Replace this script with the newest version from GitHub
  help         Show this help

For maintainers (change nothing):
  print-default-config   Print the daemon.json a fresh install would write
  latest-versions        Print the latest Docker, Compose and Buildx versions

Options:
  -y           Do not ask for confirmation

Environment variables:
  DOCKER_VERSION=29.9.0   Install this Docker version instead of the latest
  COMPOSE_VERSION=v2.x.y  Install this Compose version instead of the latest
  BUILDX_VERSION=v0.x.y   Install this Buildx version instead of the latest
  MIN_API_VERSION=1.24    Accept older API clients (e.g. old Portainer) in a new daemon.json
  FORCE=1                 Reinstall even if everything is up to date
EOF
}

# ---------------------------------------------------------------- detection

detect_setup() {
    ADDON_PRESENT=0
    [ -x "$ADDON_DIR/bin/dockerd" ] && ADDON_PRESENT=1
    if [ -x "$BIN/dockerd" ] && [ -f "$MARKER" ]; then
        SETUP=modern
    elif [ -x "$BIN/dockerd" ]; then
        SETUP=legacy
    elif [ "$ADDON_PRESENT" = 1 ]; then
        SETUP=addon
    else
        SETUP=none
    fi
    if [ "$SETUP" = addon ]; then DOCKER_CLI=$ADDON_DIR/bin/docker; else DOCKER_CLI=$BIN/docker; fi
}

setup_label() {
    case "$1" in
        modern) echo "docker-coreelec-modern" ;;
        legacy) echo "docker-coreelec (tamusiunas)" ;;
        addon)  echo "Kodi Docker add-on ($ADDON_ID)" ;;
        none)   echo "no Docker installed" ;;
    esac
}

dk() { "$DOCKER_CLI" "$@"; }

dockerd_version() { "$1" --version 2>/dev/null | sed -n 's/.*version \([^,]*\),.*/\1/p'; }

installed_version() {
    case "$SETUP" in
        addon) dockerd_version "$ADDON_DIR/bin/dockerd" ;;
        none)  echo "-" ;;
        *)     dockerd_version "$BIN/dockerd" ;;
    esac
}

cur_compose() { [ -x "$PLUG/docker-compose" ] && "$PLUG/docker-compose" version --short 2>/dev/null | sed 's/^v//'; }
cur_buildx()  { [ -x "$PLUG/docker-buildx" ] && "$PLUG/docker-buildx" version 2>/dev/null | awk '{print $2}' | sed 's/^v//'; }

conf_data_root() { sed -n 's/.*"data-root"[^"]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -n 1; }

addon_opt() {   # value of a --flag in the add-on's docker.conf
    sed -n "s/.*--$1[= ]\([^\" ]*\).*/\1/p" "$ADDON_CONF" 2>/dev/null | head -n 1
}

addon_extra_opts() {   # add-on daemon options this tool does not carry over
    sed -n 's/^DOCKER_[A-Z_]*_OPTS="\(.*\)"/\1/p' "$ADDON_CONF" 2>/dev/null | tr ' ' '\n' \
        | grep -v -e '^$' -e '^--data-root' -e '^--graph' -e '^--storage-driver' | tr '\n' ' '
}

old_data_root() {
    local d=""
    case "$SETUP" in
        addon)
            d=$(addon_opt data-root)
            [ -n "$d" ] || d=$(addon_opt graph)
            [ -n "$d" ] || d=$ADDON_DATA/docker ;;
        modern|legacy)
            d=$(conf_data_root "$CONF")
            [ -n "$d" ] || d=$DEFAULT_DATA_ROOT ;;
        none) d=$DEFAULT_DATA_ROOT ;;
    esac
    echo "$d"
}

can_move_data_root() {   # $1 = from, $2 = to; true if a fast same-filesystem mv is safe
    [ -d "$1" ] || return 1
    [ "$1" = "$2" ] && return 1
    [ -L "$1" ] && return 1
    mountpoint -q "$1" 2>/dev/null && return 1
    if [ -e "$2" ]; then
        [ -d "$2" ] && [ -z "$(ls -A "$2" 2>/dev/null)" ] || return 1
    fi
    mkdir -p "$(dirname "$2")"
    [ "$(stat -c %d "$1")" = "$(stat -c %d "$(dirname "$2")")" ]
}

compute_targets() {   # sets OLD_VERSION OLD_DATA_ROOT NEW_DATA_ROOT STORAGE_DRIVER MOVE_DATA
    OLD_VERSION=$(installed_version)
    OLD_DATA_ROOT=$(old_data_root)
    NEW_DATA_ROOT=$OLD_DATA_ROOT
    STORAGE_DRIVER=overlay2
    MOVE_DATA=0
    if [ "$SETUP" = addon ]; then
        STORAGE_DRIVER=$(addon_opt storage-driver); STORAGE_DRIVER=${STORAGE_DRIVER:-overlay2}
        if can_move_data_root "$OLD_DATA_ROOT" "$DEFAULT_DATA_ROOT"; then
            MOVE_DATA=1; NEW_DATA_ROOT=$DEFAULT_DATA_ROOT
        fi
    fi
}

free_kb() { df -P -k "$1" 2>/dev/null | awk 'NR==2{print $4}'; }

# ---------------------------------------------------------------- versions

gh_latest() {   # newest release tag of a GitHub repo, e.g. v2.40.0
    curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" \
        | sed 's#.*/tag/##'
}

docker_latest() {   # highest x.y.z in the static binaries directory
    curl -fsSL "$STATIC_URL/" \
        | grep -o 'docker-[0-9]*\.[0-9]*\.[0-9]*\.tgz' \
        | sed 's/^docker-//; s/\.tgz$//' \
        | sort -u -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

resolve_versions() {
    NEW_DOCKER=${DOCKER_VERSION:-$(docker_latest)}
    NEW_COMPOSE=${COMPOSE_VERSION:-$(gh_latest docker/compose)}
    NEW_BUILDX=${BUILDX_VERSION:-$(gh_latest docker/buildx)}
    [ -n "$NEW_DOCKER" ] && [ -n "$NEW_COMPOSE" ] && [ -n "$NEW_BUILDX" ] \
        || die "could not look up the latest versions (no internet or DNS?)"
}

# ---------------------------------------------------------------- engine control

wait_engine() {   # $1 = expected server version (optional)
    local i v
    for i in $(seq 1 "$WAIT_TRIES"); do
        v=$(dk version --format '{{.Server.Version}}' 2>/dev/null)
        if [ -n "$v" ] && { [ -z "${1:-}" ] || [ "$v" = "$1" ]; }; then return 0; fi
        [ "$i" -lt "$WAIT_TRIES" ] && sleep 2
    done
    return 1
}

record_running() {   # $1 = dir; saves running containers and dependent units
    local id u
    : > "$1/running.txt"; : > "$1/units.txt"
    dk info >/dev/null 2>&1 || return 0
    # Only containers that are really running; --rm containers are recreated by whatever
    # started them (usually a systemd unit), so they are not started by ID afterwards.
    for id in $(dk ps -q --filter status=running 2>/dev/null); do
        [ "$(dk inspect -f '{{.HostConfig.AutoRemove}}' "$id" 2>/dev/null)" = true ] && continue
        echo "$id" >> "$1/running.txt"
    done
    # Services that depend on Docker are stopped together with it; remember the active ones.
    systemctl list-dependencies --reverse --plain --no-legend "$SVC_NAME" 2>/dev/null \
        | sed 's/^[^A-Za-z0-9@_.-]*//' | while read -r u; do
            case "$u" in *.service) ;; *) continue ;; esac
            [ "$u" = "$SVC_NAME" ] && continue
            systemctl is-active -q "$u" 2>/dev/null && echo "$u"
        done > "$1/units.txt"
    # shellcheck disable=SC2046
    dk inspect $(dk ps -aq 2>/dev/null) > "$1/containers.json" 2>/dev/null
    return 0
}

stop_engine() {
    local ids i
    if dk info >/dev/null 2>&1; then
        ids=$(dk ps -q)
        if [ -n "$ids" ]; then
            log "Stopping containers: $(dk ps --format '{{.Names}}' | tr '\n' ' ')"
            # shellcheck disable=SC2086
            dk stop -t 30 $ids >>"$LOG" 2>&1
        fi
    fi
    log "Stopping the Docker service"
    systemctl stop "$SVC_NAME" >>"$LOG" 2>&1
    for i in $(seq 1 30); do
        if ! pidof dockerd >/dev/null && ! pidof containerd >/dev/null; then return 0; fi
        sleep 1
    done
    warn "dockerd/containerd did not stop cleanly, killing them"
    killall dockerd containerd 2>/dev/null
    sleep 3
}

start_saved() {   # $1 = dir with running.txt / units.txt; sets FAILED
    local id st name u
    FAILED=""
    if [ -s "$1/running.txt" ]; then
        log "Starting containers"
        # shellcheck disable=SC2046
        dk start $(cat "$1/running.txt") >>"$LOG" 2>&1
    fi
    if [ -s "$1/units.txt" ]; then
        log "Starting services: $(tr '\n' ' ' < "$1/units.txt")"
        # shellcheck disable=SC2046
        systemctl start --no-block $(cat "$1/units.txt") >>"$LOG" 2>&1
    fi
    [ -s "$1/running.txt" ] || [ -s "$1/units.txt" ] || return 0
    sleep "$SETTLE_SECONDS"
    while read -r id; do
        [ -n "$id" ] || continue
        st=$(dk inspect -f '{{.State.Running}}{{.State.Restarting}}' "$id" 2>/dev/null)
        if [ "$st" != "truefalse" ]; then
            name=$(dk inspect -f '{{.Name}}' "$id" 2>/dev/null | tr -d /)
            FAILED="$FAILED ${name:-$id}"
        fi
    done < "$1/running.txt"
    while read -r u; do
        [ -n "$u" ] || continue
        systemctl is-active -q "$u" 2>/dev/null || FAILED="$FAILED $u"
    done < "$1/units.txt"
    [ -z "$FAILED" ]
}

images_32bit() {   # prints "container (image) arch" for containers not using arm64 images
    local c img arch ref
    for c in $(dk ps -aq 2>/dev/null); do
        img=$(dk inspect -f '{{.Image}}' "$c" 2>/dev/null)
        arch=$(dk image inspect -f '{{.Architecture}}' "$img" 2>/dev/null)
        if [ -n "$arch" ] && [ "$arch" != "arm64" ]; then
            ref=$(dk inspect -f '{{.Config.Image}}' "$c" 2>/dev/null)
            echo "$(dk inspect -f '{{.Name}}' "$c" 2>/dev/null | tr -d /) ($ref) $arch"
        fi
    done
}

# ---------------------------------------------------------------- recovery

manual_help() {
    log "Docker could not be brought back automatically. Nothing was deleted:"
    [ -n "$BACKUP_DIR" ] && log "  backup of the previous setup: $BACKUP_DIR"
    log "  log of this run: $LOG"
    log "Rebooting the box often helps. See 'Manual recovery' in $REPO_URL"
}

recover() {   # called by die(): put back whatever was running before
    [ "$RECOVERING" = 1 ] && { manual_help; return; }
    RECOVERING=1
    case "$PHASE" in
        stopped)
            log "Nothing was changed yet; starting the previous Docker again"
            systemctl start --no-block "$SVC_NAME" >>"$LOG" 2>&1
            if wait_engine; then
                start_saved "$TMP" || warn "not running:$FAILED"
            else
                manual_help
            fi ;;
        changed)
            restore_backup "$BACKUP_DIR" ;;
    esac
}

# ---------------------------------------------------------------- downloads

sha_check() {   # $1 = file, $2 = expected sha256
    command -v sha256sum >/dev/null || die "sha256sum is missing, cannot verify downloads"
    [ -n "$2" ] || die "no checksum found for $(basename "$1")"
    [ "$(sha256sum "$1" | awk '{print $1}')" = "$2" ]
}

download_and_test() {
    local f exp
    rm -rf "$TMP"; mkdir -p "$TMP" || die "cannot create $TMP"

    log "Downloading Docker $NEW_DOCKER"
    curl -fL --retry 3 -o "$TMP/docker.tgz" "$STATIC_URL/docker-$NEW_DOCKER.tgz" >>"$LOG" 2>&1 \
        || die "download of Docker $NEW_DOCKER failed"
    tar -tzf "$TMP/docker.tgz" >/dev/null 2>&1 || die "the Docker archive is damaged"
    tar -xzf "$TMP/docker.tgz" -C "$TMP" || die "unpacking Docker failed"

    log "Downloading Docker Compose $NEW_COMPOSE"
    f=docker-compose-linux-aarch64
    curl -fL --retry 3 -o "$TMP/docker-compose" \
        "https://github.com/docker/compose/releases/download/$NEW_COMPOSE/$f" >>"$LOG" 2>&1 \
        || die "download of Docker Compose failed"
    exp=$(curl -fsSL "https://github.com/docker/compose/releases/download/$NEW_COMPOSE/$f.sha256" | awk '{print $1}')
    sha_check "$TMP/docker-compose" "$exp" || die "Docker Compose checksum mismatch"

    log "Downloading Docker Buildx $NEW_BUILDX"
    f="buildx-$NEW_BUILDX.linux-arm64"
    curl -fL --retry 3 -o "$TMP/docker-buildx" \
        "https://github.com/docker/buildx/releases/download/$NEW_BUILDX/$f" >>"$LOG" 2>&1 \
        || die "download of Docker Buildx failed"
    exp=$(curl -fsSL "https://github.com/docker/buildx/releases/download/$NEW_BUILDX/checksums.txt" \
        | awk -v f="$f" '$2==f || $2=="*"f {print $1}')
    sha_check "$TMP/docker-buildx" "$exp" || die "Docker Buildx checksum mismatch"

    chmod +x "$TMP"/docker/* "$TMP/docker-compose" "$TMP/docker-buildx"

    # Make sure the new binaries actually run on this box before anything is stopped.
    for f in dockerd containerd runc docker; do
        "$TMP/docker/$f" --version >>"$LOG" 2>&1 || die "the new $f does not run on this box"
    done
    "$TMP/docker-compose" version >>"$LOG" 2>&1 || die "the new Docker Compose does not run"
    "$TMP/docker-buildx" version >>"$LOG" 2>&1 || die "the new Docker Buildx does not run"
    echo "$NEW_DOCKER $NEW_COMPOSE $NEW_BUILDX" > "$TMP/ready"
    log "New binaries downloaded and tested"
}

# ---------------------------------------------------------------- configuration

write_default_config() {   # $1 = file, $2 = data-root, $3 = storage driver
    {
        echo "{"
        echo "  \"data-root\": \"$2\","
        echo "  \"storage-driver\": \"$3\","
        echo "  \"exec-opts\": [\"native.cgroupdriver=systemd\"],"
        echo "  \"log-driver\": \"journald\","
        echo "  \"group\": \"root\","
        echo "  \"live-restore\": true,"
        if [ -n "${MIN_API_VERSION:-}" ]; then
            echo "  \"features\": { \"containerd-snapshotter\": false },"
            echo "  \"min-api-version\": \"$MIN_API_VERSION\""
        else
            echo "  \"features\": { \"containerd-snapshotter\": false }"
        fi
        echo "}"
    } > "$1"
}

validate_config() {   # $1 = daemon.json; checked by the NEW dockerd
    # dockerd looks up docker-proxy (userland-proxy-path) in PATH. On a fresh install the
    # new binaries are only in $TMP/docker, and on an update an older docker-proxy may be
    # in PATH, so the new binary directory goes first.
    PATH="$TMP/docker:$PATH" "$TMP/docker/dockerd" --validate --config-file "$1"
}

decide_config() {   # writes $TMP/config_action (keep|new) and, for new, $TMP/daemon.json.new
    local action=new
    if [ -f "$CONF" ] && { [ "$SETUP" = modern ] || [ "$SETUP" = legacy ]; }; then
        if validate_config "$CONF" >"$TMP/validate.txt" 2>&1; then
            action=keep
            log "Your existing daemon.json is valid for Docker $NEW_DOCKER and will be kept"
        else
            log "Your daemon.json is not valid for Docker $NEW_DOCKER and will be replaced"
            log "(the old file is saved in the backup). Docker said:"
            sed 's/^/    /' "$TMP/validate.txt" | tee -a "$LOG"
        fi
    fi
    if [ "$action" = new ]; then
        write_default_config "$TMP/daemon.json.new" "$NEW_DATA_ROOT" "$STORAGE_DRIVER"
        validate_config "$TMP/daemon.json.new" >"$TMP/validate.txt" 2>&1 \
            || { sed 's/^/    /' "$TMP/validate.txt" | tee -a "$LOG"; die "the new daemon.json is not accepted by Docker $NEW_DOCKER"; }
    fi
    echo "$action" > "$TMP/config_action"
}

write_service() {
    mkdir -p "$SYSD"
    cat > "$SVC" <<EOF
[Unit]
Description=Docker Application Container Engine (docker-coreelec-modern)
Documentation=$REPO_URL
After=network.target

[Service]
Type=notify
Environment=PATH=$BIN:/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
ExecStart=$BIN/dockerd --config-file $CONF
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutStartSec=0
Restart=always
RestartSec=2
Delegate=yes
KillMode=process
OOMScoreAdjust=-500
LimitNOFILE=infinity
LimitNPROC=infinity
TasksMax=infinity

[Install]
WantedBy=multi-user.target
Alias=docker.service
EOF
}

profile_add()    { grep -qF "$BIN" "$PROFILE" 2>/dev/null || echo "export PATH=$BIN:\$PATH" >> "$PROFILE"; }
profile_remove() {
    [ -f "$PROFILE" ] || return 0
    grep -vF "$BIN" "$PROFILE" > "$PROFILE.tmp"; mv -f "$PROFILE.tmp" "$PROFILE"
}

# Systemd units that start containers with the add-on's docker binary (like the
# add-on's own examples) are pointed at the new binary. Originals go into the backup.
rewrite_addon_units() {
    local f
    for f in "$SYSD"/*.service "$SYSD"/*.timer; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        [ "$f" = "$SVC" ] && continue
        if grep -qF "$ADDON_DIR/bin/" "$f"; then
            mkdir -p "$BACKUP_DIR/units"
            cp -a "$f" "$BACKUP_DIR/units/" || die "backing up $f failed"
            sed -i "s#$ADDON_DIR/bin/#$BIN/#g" "$f"
            log "Updated $(basename "$f") to use the new docker binary"
        fi
    done
    for f in "$R/storage/.config/autostart.sh" "$R/storage/.cache/cron/crontabs/root"; do
        [ -f "$f" ] && grep -qF "$ADDON_DIR/bin" "$f" \
            && warn "$f still refers to $ADDON_DIR/bin; change it to $BIN yourself"
    done
    return 0
}

install_files() {
    local f
    fail_point install_files
    log "Installing the new binaries"
    mkdir -p "$BIN" "$PLUG" "$CONF_DIR"
    cp -f "$TMP"/docker/* "$BIN/" || die "copying the binaries to $BIN failed"
    for f in $OBSOLETE_BINS; do rm -f "$BIN/$f"; done
    cp -f "$TMP/docker-compose" "$TMP/docker-buildx" "$PLUG/" || die "copying the plugins failed"
    # 'docker-compose' (with a dash) keeps working, now as Compose v2.
    rm -f "$BIN/docker-compose"
    ln -s "$PLUG/docker-compose" "$BIN/docker-compose"
    # Keep a copy of this tool so 'docker-coreelec update' works later.
    if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF_COPY")" ]; then
        cp -f "$0" "$SELF_COPY" || die "copying the tool to $SELF_COPY failed"
    fi
    chmod +x "$SELF_COPY"
    rm -f "$BIN/docker-coreelec"
    ln -s "$SELF_COPY" "$BIN/docker-coreelec"
    echo "$TOOL_VERSION" > "$MARKER"
    if [ "$(cat "$TMP/config_action" 2>/dev/null)" != keep ]; then
        cp -f "$TMP/daemon.json.new" "$CONF" || die "writing $CONF failed"
    fi
    write_service
    profile_add
}

# ---------------------------------------------------------------- backup / restore

meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n 1; }

meta_size_kb() {   # $1 = data-root; size of what backup_create copies from it
    local item total=0 s f
    for item in $META_ITEMS; do
        [ -e "$1/$item" ] || continue
        if [ "$item" = containers ]; then
            s=0
            while read -r f; do s=$((s + $(stat -c %s "$f" 2>/dev/null || echo 0))); done <<EOF
$(find "$1/containers" -type f ! -name '*-json.log*' 2>/dev/null)
EOF
            total=$((total + s / 1024 + 1))
        else
            total=$((total + $(du -sk "$1/$item" 2>/dev/null | awk '{print $1}')))
        fi
    done
    echo "$total"
}

copy_meta() {   # $1 = data-root, $2 = destination; container logs are left out
    local item p
    for item in $META_ITEMS; do
        [ -e "$1/$item" ] || continue
        if [ "$item" = containers ]; then
            (cd "$1" && find containers ! -name '*-json.log*') | while read -r p; do
                if [ -d "$1/$p" ] && [ ! -L "$1/$p" ]; then
                    mkdir -p "$2/$p" || exit 1
                else
                    cp -a "$1/$p" "$2/$p" || exit 1
                fi
            done || return 1
        else
            mkdir -p "$2/$(dirname "$item")" && cp -a "$1/$item" "$2/$item" || return 1
        fi
    done
}

restore_meta() {   # $1 = backup dir, $2 = data-root
    local item src d
    for item in $META_ITEMS; do
        src="$1/data-root-meta/$item"
        [ -e "$src" ] || continue
        if [ "$item" = containers ]; then
            # Copy the saved definitions over the live ones; logs stay where they are.
            mkdir -p "$2/containers"
            for d in "$src"/*; do
                [ -e "$d" ] && { cp -a "$d" "$2/containers/" || return 1; }
            done
        else
            rm -rf "${2:?}/$item"
            mkdir -p "$(dirname "$2/$item")"
            cp -a "$src" "$2/$item" || return 1
        fi
    done
}

check_backup_space() {
    local need have
    need=$(( $(meta_size_kb "$OLD_DATA_ROOT") + MIN_FREE_MB * 1024 ))
    [ -d "$BIN" ] && need=$((need + $(du -sk "$BIN" | awk '{print $1}')))
    have=$(free_kb "$BASE")
    [ "${have:-0}" -ge "$need" ] \
        || die "not enough free space on /storage for the backup: need $((need / 1024)) MB, have $((${have:-0} / 1024)) MB"
}

backup_create() {
    local seq
    # A running number keeps the order right even for two backups in the same second.
    mkdir -p "$BACKUPS"
    seq=$(( $(cat "$BACKUPS/.seq" 2>/dev/null || echo 0) + 1 ))
    echo "$seq" > "$BACKUPS/.seq"
    BACKUP_DIR="$BACKUPS/$(date +%Y%m%d-%H%M%S)-$(printf '%04d' "$seq")_$SETUP"
    mkdir -p "$BACKUP_DIR/data-root-meta" || die "cannot create $BACKUP_DIR"
    log "Creating a backup in $BACKUP_DIR"
    cp "$TMP/running.txt" "$TMP/units.txt" "$BACKUP_DIR/" || die "backup failed"
    cp "$TMP/containers.json" "$BACKUP_DIR/" 2>/dev/null
    case "$SETUP" in
        modern|legacy)
            cp -a "$BIN" "$BACKUP_DIR/bin" || die "backing up $BIN failed"
            if [ -d "$PLUG" ]; then cp -a "$PLUG" "$BACKUP_DIR/cli-plugins" || die "backing up $PLUG failed"; fi
            if [ -f "$CONF" ]; then cp -a "$CONF" "$BACKUP_DIR/daemon.json" || die "backing up $CONF failed"; fi
            if [ -f "$SVC" ];  then cp -a "$SVC" "$BACKUP_DIR/$SVC_NAME" || die "backing up $SVC failed"; fi ;;
        addon)
            if [ -f "$ADDON_CONF" ]; then cp -a "$ADDON_CONF" "$BACKUP_DIR/docker.conf" || die "backup failed"; fi ;;
    esac
    # Engine metadata (container definitions, image index, networks), not image layers,
    # volumes or container logs. Needed to go back cleanly if the new version misbehaves.
    copy_meta "$OLD_DATA_ROOT" "$BACKUP_DIR/data-root-meta" || die "backing up Docker's metadata failed"
    fail_point in_backup
    # Written last: a backup without meta is incomplete and is never restored.
    cat > "$BACKUP_DIR/meta" <<EOF
KIND=$SETUP
OLD_VERSION=$OLD_VERSION
OLD_DATA_ROOT=$OLD_DATA_ROOT
NEW_DATA_ROOT=$NEW_DATA_ROOT
DATA_MOVED=0
EOF
}

restore_problem() {   # $1 = backup dir; prints why it cannot be restored (before touching anything)
    local kind
    kind=$(meta_get "$1" KIND)
    case "$kind" in
        modern|legacy) [ -x "$1/bin/dockerd" ] || echo "the backup has no Docker binaries" ;;
        addon)
            if [ -d "$1/addon" ] && [ -e "$ADDON_DIR" ]; then
                echo "the Kodi Docker add-on is installed again; uninstall it in Kodi first"
            elif [ ! -d "$1/addon" ] && [ ! -d "$ADDON_DIR" ]; then
                echo "the Kodi add-on is missing from the backup"
            elif [ "$(meta_get "$1" DATA_MOVED)" = 1 ] && [ -e "$(meta_get "$1" OLD_DATA_ROOT)" ] \
                 && [ -n "$(ls -A "$(meta_get "$1" OLD_DATA_ROOT)" 2>/dev/null)" ]; then
                echo "$(meta_get "$1" OLD_DATA_ROOT) is in use again; move it away first"
            fi ;;
        none) ;;
        *) echo "$1 is not a complete backup" ;;
    esac
}

restore_backup() {   # $1 = backup dir
    local b=$1 kind old_dr new_dr moved problem
    RECOVERING=1
    kind=$(meta_get "$b" KIND)
    old_dr=$(meta_get "$b" OLD_DATA_ROOT)
    new_dr=$(meta_get "$b" NEW_DATA_ROOT)
    moved=$(meta_get "$b" DATA_MOVED)
    problem=$(restore_problem "$b")
    [ -z "$problem" ] || die "cannot restore $b: $problem"
    log "Restoring backup $b (previous setup: $(setup_label "$kind"))"

    DOCKER_CLI=$BIN/docker
    [ -x "$BIN/dockerd" ] && stop_engine
    systemctl disable "$SVC_NAME" >>"$LOG" 2>&1

    case "$kind" in
        modern|legacy)
            # Copy first, then swap, so a failed copy leaves the current files in place.
            rm -rf "$BIN.restore" "$PLUG.restore"
            cp -a "$b/bin" "$BIN.restore" || die "copying binaries from the backup failed"
            if [ -d "$b/cli-plugins" ]; then
                cp -a "$b/cli-plugins" "$PLUG.restore" || die "copying plugins from the backup failed"
            fi
            rm -rf "$BIN"; mv "$BIN.restore" "$BIN"
            rm -rf "$PLUG"; [ -d "$PLUG.restore" ] && mv "$PLUG.restore" "$PLUG"
            [ -f "$b/daemon.json" ] && cp -a "$b/daemon.json" "$CONF"
            [ -f "$b/$SVC_NAME" ] && cp -a "$b/$SVC_NAME" "$SVC"
            [ "$kind" = legacy ] && rm -f "$MARKER"
            restore_meta "$b" "$old_dr" || warn "restoring Docker's metadata failed"
            systemctl daemon-reload
            systemctl enable "$SVC_NAME" >>"$LOG" 2>&1
            DOCKER_CLI=$BIN/docker ;;
        addon)
            rm -rf "$BIN" "$PLUG" "$MARKER" "$SELF_COPY" "$CONF" "$SVC"
            profile_remove
            if [ "$moved" = 1 ] && [ -d "$new_dr" ]; then
                log "Moving Docker data back to $old_dr"
                [ -d "$old_dr" ] && rmdir "$old_dr" 2>/dev/null
                mkdir -p "$(dirname "$old_dr")"
                mv "$new_dr" "$old_dr" || die "moving $new_dr back to $old_dr failed"
            fi
            restore_meta "$b" "$old_dr" || warn "restoring Docker's metadata failed"
            if [ -d "$b/units" ]; then cp -a "$b"/units/* "$SYSD/" || warn "restoring units failed"; fi
            if [ -d "$b/addon" ]; then
                mv "$b/addon" "$ADDON_DIR" || die "moving the Kodi add-on back failed"
            fi
            systemctl daemon-reload
            systemctl enable "$ADDON_DIR/system.d/$SVC_NAME" >>"$LOG" 2>&1
            DOCKER_CLI=$ADDON_DIR/bin/docker ;;
        none)
            rm -rf "$BIN" "$PLUG" "$MARKER" "$SELF_COPY" "$CONF" "$SVC"
            profile_remove
            systemctl daemon-reload
            touch "$b/restored"
            log "Fresh install removed again"
            return 0 ;;
    esac

    systemctl start --no-block "$SVC_NAME" >>"$LOG" 2>&1
    wait_engine || die "Docker does not start after restoring either. Check: journalctl -u $SVC_NAME -n 50"
    log "Previous Docker is running again: $(dk version --format '{{.Server.Version}}' 2>/dev/null)"
    start_saved "$b" || warn "not running:$FAILED"
    touch "$b/restored"
}

prune_backups() {
    ls -1d "$BACKUPS"/*/ 2>/dev/null | sort -r | tail -n +$((KEEP_BACKUPS + 1)) | while read -r d; do
        log "Removing old backup $d"
        rm -rf "$d"
    done
}

latest_backup() {   # newest complete backup that has not been restored yet
    local d
    for d in $(ls -1d "$BACKUPS"/*/ 2>/dev/null | sort -r); do
        [ -f "$d/meta" ] || continue
        [ -f "$d/restored" ] && continue
        echo "${d%/}"; return 0
    done
}

# ---------------------------------------------------------------- preflight

preflight() {
    [ -n "$R" ] || [ "$(id -u)" = 0 ] || die "run this as root"
    [ "$(uname -m)" = "aarch64" ] \
        || die "this box runs a $(uname -m) kernel; docker-coreelec needs a 64-bit (aarch64) kernel"
    command -v systemctl >/dev/null || die "systemd not found; is this CoreELEC?"
    command -v curl >/dev/null || die "curl not found"
    [ -f "$0" ] || die "save this script to a file first (for example /storage/docker-coreelec.sh) and run it from there"
    [ -d "$LOCK" ] && die "another docker-coreelec run is active (if not, remove $LOCK)"
    mkdir -p "$BASE"
}

check_free_space() {
    [ "$(free_kb "$BASE")" -ge $((MIN_FREE_MB * 1024)) ] || die "less than $MIN_FREE_MB MB free on /storage"
}

# ---------------------------------------------------------------- commands

do_status() {
    local v
    detect_setup
    say "docker-coreelec $TOOL_VERSION"
    say "Box:            $(uname -m), kernel $(uname -r)"
    say "Free space:     $(( $(free_kb "$R/storage") / 1024 )) MB on /storage"
    say "Current setup:  $(setup_label "$SETUP")"
    [ "$SETUP" != addon ] && [ "$ADDON_PRESENT" = 1 ] && say "                (the Kodi Docker add-on is installed as well!)"
    v=$(dk info --format '{{.ServerVersion}}, cgroup v{{.CgroupVersion}}' 2>/dev/null)
    say "Engine:         ${v:-not running}"
    say ""
    say "                installed          latest"
    printf "Docker          %-18s %s\n" "$(installed_version)" "${DOCKER_VERSION:-$(docker_latest)}"
    printf "Compose         %-18s %s\n" "$(cur_compose || echo '-')" "${COMPOSE_VERSION:-$(gh_latest docker/compose)}"
    printf "Buildx          %-18s %s\n" "$(cur_buildx || echo '-')" "${BUILDX_VERSION:-$(gh_latest docker/buildx)}"
    if dk info >/dev/null 2>&1; then
        say ""
        say "Running containers: $(dk ps --format '{{.Names}}' | tr '\n' ' ')"
        v=$(images_32bit)
        if [ -n "$v" ]; then
            say "Containers on 32-bit images (recreate them to switch to 64-bit):"
            printf '%s\n' "$v" | sed 's/^/  /'
        fi
    fi
    say ""
    say "Backups:"
    v=$(ls -1d "$BACKUPS"/*/ 2>/dev/null)
    if [ -n "$v" ]; then printf '%s\n' "$v" | sed 's/^/  /'; else say "  (none)"; fi
}

plan_install() {
    detect_setup
    if [ "$ADDON_PRESENT" = 1 ] && [ "$SETUP" != addon ]; then
        die "both $(setup_label "$SETUP") and the Kodi Docker add-on are installed. Uninstall the add-on in Kodi first."
    fi
    check_free_space
    resolve_versions
    compute_targets
    say ""
    say "Current setup:  $(setup_label "$SETUP")$( [ "$SETUP" != none ] && echo " (Docker $OLD_VERSION)")"
    say "Will install:   Docker $NEW_DOCKER, Compose $NEW_COMPOSE, Buildx $NEW_BUILDX"
    say ""
    case "$SETUP" in
        none)
            say "This is a fresh install. Docker will keep its data in $DEFAULT_DATA_ROOT." ;;
        addon)
            say "Migration from the Kodi Docker add-on:"
            say " - the add-on is switched off and moved into a backup (rollback puts it back)"
            say " - your containers, images and volumes are kept"
            if [ "$MOVE_DATA" = 1 ]; then
                say " - Docker data moves from $OLD_DATA_ROOT to $NEW_DATA_ROOT (instant, same disk)"
            else
                say " - Docker data stays in $OLD_DATA_ROOT"
            fi
            say " - existing containers keep their 32-bit images until you recreate them"
            [ -n "$(addon_extra_opts)" ] && say " - NOT carried over, add these to daemon.json yourself: $(addon_extra_opts)" ;;
        legacy)
            say "Upgrade of tamusiunas/docker-coreelec. Your containers, images and volumes are kept." ;;
        modern)
            if [ "$OLD_VERSION" = "$NEW_DOCKER" ] && [ "$(cur_compose)" = "${NEW_COMPOSE#v}" ] \
               && [ "$(cur_buildx)" = "${NEW_BUILDX#v}" ] && [ "${FORCE:-}" != 1 ]; then
                say "Everything is up to date. To reinstall anyway: FORCE=1 bash $0 install"
                exit 0
            fi
            say "Update of docker-coreelec-modern." ;;
    esac
    if [ "$SETUP" != none ]; then
        say ""
        say "Running containers are stopped and started again (a minute or two). If you are"
        say "connected through a VPN that runs in Docker, your connection will drop: the script"
        say "keeps going in the background and restores the old setup by itself if anything fails."
    fi
    say "Log file: $LOG"
}

prepare_install() {   # foreground part after confirmation: everything that needs the network
    download_and_test
    decide_config
}

do_install() {
    detect_setup
    compute_targets
    resolve_versions
    log "docker-coreelec $TOOL_VERSION: $(setup_label "$SETUP") -> Docker $NEW_DOCKER"
    if [ "$(cat "$TMP/ready" 2>/dev/null)" != "$NEW_DOCKER $NEW_COMPOSE $NEW_BUILDX" ]; then
        download_and_test
        decide_config
    fi
    [ -f "$TMP/config_action" ] || decide_config

    record_running "$TMP"
    check_backup_space

    if [ "$SETUP" != none ]; then
        stop_engine
        PHASE=stopped
    fi
    fail_point after_stop
    backup_create
    PHASE=changed

    if [ "$SETUP" = addon ]; then
        log "Switching off the Kodi Docker add-on"
        systemctl disable "$SVC_NAME" >>"$LOG" 2>&1
        [ -L "$SVC" ] && rm -f "$SVC"
        fail_point after_addon_disable
        mv "$ADDON_DIR" "$BACKUP_DIR/addon" || die "moving the add-on into the backup failed"
        if [ "$MOVE_DATA" = 1 ]; then
            log "Moving Docker data to $NEW_DATA_ROOT"
            [ -d "$NEW_DATA_ROOT" ] && rmdir "$NEW_DATA_ROOT"
            mv "$OLD_DATA_ROOT" "$NEW_DATA_ROOT" || die "moving Docker data to $NEW_DATA_ROOT failed"
            sed -i 's/^DATA_MOVED=0/DATA_MOVED=1/' "$BACKUP_DIR/meta"
        fi
        rewrite_addon_units
    fi

    install_files
    systemctl daemon-reload
    systemctl enable "$SVC_NAME" >>"$LOG" 2>&1

    DOCKER_CLI=$BIN/docker
    log "Starting Docker $NEW_DOCKER"
    systemctl start --no-block "$SVC_NAME" >>"$LOG" 2>&1
    if ! wait_engine "$NEW_DOCKER"; then
        log "Docker $NEW_DOCKER does not start. Last lines from the journal:"
        journalctl -u "$SVC_NAME" -n 40 --no-pager >>"$LOG" 2>&1
        die "Docker $NEW_DOCKER did not start; rolling back"
    fi
    log "Docker $(dk version --format '{{.Server.Version}}') is running"

    if ! start_saved "$TMP"; then
        log "Did not come back up:$FAILED"
        for c in $FAILED; do
            case "$c" in *.service) continue ;; esac
            log "--- last log lines of $c:"
            dk logs --tail 15 "$c" >>"$LOG" 2>&1
        done
        die "not everything came back; rolling back"
    fi
    PHASE=""

    cp -f "$TMP/config_action" "$BACKUP_DIR/" 2>/dev/null
    rm -rf "$TMP"
    prune_backups
    log "DONE: Docker $NEW_DOCKER, Compose $NEW_COMPOSE, Buildx $NEW_BUILDX."
    { [ -s "$BACKUP_DIR/running.txt" ] || [ -s "$BACKUP_DIR/units.txt" ]; } \
        && log "Everything that was running is running again."
    if [ "$SETUP" = addon ]; then
        local old32
        old32=$(images_32bit)
        if [ -n "$old32" ]; then
            log "These containers still use 32-bit images. They work, but recreate them"
            log "(pull + recreate, or 'Recreate' with 'Pull latest image' in Portainer) to go 64-bit:"
            printf '%s\n' "$old32" | sed 's/^/    /' | tee -a "$LOG"
        fi
        log "Reboot once at a convenient moment so Kodi forgets the old add-on."
    fi
    log "Open a new SSH session (or run: export PATH=$BIN:\$PATH) to use the new docker command."
    log "Undo this with: docker-coreelec rollback"
}

plan_rollback() {
    local b problem
    detect_setup
    b=$(latest_backup)
    [ -n "$b" ] || die "no backup found in $BACKUPS"
    problem=$(restore_problem "$b")
    [ -z "$problem" ] || die "cannot restore $b: $problem"
    say "Will restore:   $b"
    say "Previous setup: $(setup_label "$(meta_get "$b" KIND)"), Docker $(meta_get "$b" OLD_VERSION)"
    say "Running containers are stopped and started again on the restored setup."
    say "Log file: $LOG"
}

do_rollback() {
    local b
    b=$(latest_backup)
    [ -n "$b" ] || die "no backup found in $BACKUPS"
    restore_backup "$b"
    log "DONE: rollback finished"
}

plan_uninstall() {
    detect_setup
    case "$SETUP" in
        modern|legacy) ;;
        addon) die "Docker was installed by the Kodi add-on; remove it in Kodi instead" ;;
        none)  die "Docker is not installed" ;;
    esac
    say "Will remove Docker from $BASE and stop all containers."
    if [ "$PURGE" = 1 ]; then
        say "--purge: images, containers, volumes ($(old_data_root)) and all backups are DELETED."
    else
        say "Images, containers and volumes in $(old_data_root) and the backups are kept."
    fi
}

do_uninstall() {
    local dr
    detect_setup
    dr=$(old_data_root)
    stop_engine
    systemctl disable "$SVC_NAME" >>"$LOG" 2>&1
    rm -rf "$BIN" "$PLUG" "$MARKER" "$SELF_COPY" "$SVC" "$TMP"
    [ -f "$CONF" ] && mv -f "$CONF" "$CONF.removed"
    profile_remove
    systemctl daemon-reload
    if [ "$PURGE" = 1 ]; then
        log "Deleting $dr and $BACKUPS"
        rm -rf "${dr:?}" "$BACKUPS"
    fi
    log "DONE: Docker removed$( [ "$PURGE" = 1 ] || echo ". Your data is still in $dr")"
}

do_self_update() {
    local target new v code rc err
    target=$(readlink -f "$0")
    new=$(mktemp) || die "cannot create a temporary file"
    code=$(curl -fsSL -w '%{http_code}' -o "$new" "$RAW_URL" 2>"$new.err"); rc=$?
    if [ "$rc" != 0 ]; then
        err=$(head -n 1 "$new.err" 2>/dev/null)
        rm -f "$new" "$new.err"
        log "ERROR: self-update failed: could not download $RAW_URL"
        case "$code" in
            ""|000) say "  no HTTP response (curl exit code $rc${err:+: $err})" ;;
            *)      say "  HTTP status $code (curl exit code $rc)" ;;
        esac
        say "  The current script was not changed: $target"
        case "$code" in
            404) say "  Hint: the file or repository was not found; check that $REPO_URL is reachable and public." ;;
            *)   say "  Hint: check the internet connection and DNS of this box, and that github.com is reachable." ;;
        esac
        exit 1
    fi
    rm -f "$new.err"
    bash -n "$new" 2>/dev/null && grep -q '^TOOL_VERSION=' "$new" \
        || { rm -f "$new"; die "the downloaded script looks broken; the current script was not changed"; }
    v=$(sed -n 's/^TOOL_VERSION="\(.*\)"/\1/p' "$new")
    if [ "$v" = "$TOOL_VERSION" ] && [ "${FORCE:-}" != 1 ]; then
        rm -f "$new"; say "Already the newest version ($TOOL_VERSION)."; return 0
    fi
    cat "$new" > "$target" && rm -f "$new"
    [ -f "$SELF_COPY" ] && [ "$target" != "$(readlink -f "$SELF_COPY")" ] && cp -f "$target" "$SELF_COPY"
    say "Updated docker-coreelec $TOOL_VERSION -> $v"
}

# ---------------------------------------------------------------- main

CMD=${1:-help}
[ $# -gt 0 ] && shift
for a in "$@"; do
    case "$a" in
        -y|--yes) ASSUME_YES=1 ;;
        --purge)  PURGE=1 ;;
        *) echo "Unknown option: $a"; usage; exit 1 ;;
    esac
done

case "$CMD" in
    status)             do_status; exit 0 ;;
    # For maintainers and CI: no changes to the system.
    print-default-config)
        write_default_config /dev/stdout "$DEFAULT_DATA_ROOT" overlay2; exit 0 ;;
    latest-versions)
        echo "${DOCKER_VERSION:-$(docker_latest)} ${COMPOSE_VERSION:-$(gh_latest docker/compose)} ${BUILDX_VERSION:-$(gh_latest docker/buildx)}"; exit 0 ;;
    help|-h|--help)     usage; exit 0 ;;
    self-update)        do_self_update; exit $? ;;
    install|update)     CMD=install ;;
    rollback|uninstall) ;;
    *) echo "Unknown command: $CMD"; usage; exit 1 ;;
esac

if [ -z "${DCE_DETACHED:-}" ]; then
    preflight
    "plan_$CMD"
    if [ "$ASSUME_YES" != 1 ]; then
        printf "\nContinue? [y/N] "
        read -r answer
        case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 0 ;; esac
    fi
    [ -f "$LOG" ] && mv -f "$LOG" "$LOG.old"
    : > "$LOG"
    # Downloads happen here, in the foreground, so problems show up right away.
    [ "$CMD" = install ] && prepare_install
    # Pin the versions that were shown, so the background run installs exactly those.
    export DOCKER_VERSION=${NEW_DOCKER:-${DOCKER_VERSION:-}}
    export COMPOSE_VERSION=${NEW_COMPOSE:-${COMPOSE_VERSION:-}}
    export BUILDX_VERSION=${NEW_BUILDX:-${BUILDX_VERSION:-}}
    export PURGE MIN_API_VERSION=${MIN_API_VERSION:-} FORCE=${FORCE:-}

    if [ "${NO_DETACH:-}" = 1 ]; then
        DCE_DETACHED=1 exec bash "$0" "$CMD"
    fi
    SELF=$(readlink -f "$0")
    BASH_BIN=$(command -v bash)
    SETENV=(--setenv=DCE_DETACHED=1)
    for v in $PASS_ENV; do
        [ -n "${!v:-}" ] && SETENV+=("--setenv=$v=${!v}")
    done
    # Keep running even when the SSH session drops (stopping a VPN container does that).
    if ! { command -v systemd-run >/dev/null &&
           systemd-run --unit="docker-coreelec-$(date +%s)" "${SETENV[@]}" \
               "$BASH_BIN" "$SELF" "$CMD" >/dev/null 2>&1; }; then
        DCE_DETACHED=1 setsid nohup "$BASH_BIN" "$SELF" "$CMD" >/dev/null 2>&1 </dev/null &
    fi
    echo
    echo "Running in the background now; it keeps going if your connection drops."
    echo "Following the log (Ctrl+C only stops following):"
    echo
    sleep 2
    exec tail -f "$LOG"
fi

mkdir -p "$(dirname "$LOCK")"
mkdir "$LOCK" 2>/dev/null || die "another docker-coreelec run is active (if not, remove $LOCK)"
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

"do_$CMD"
