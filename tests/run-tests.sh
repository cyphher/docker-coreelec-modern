#!/bin/bash
# Test suite for docker-coreelec.sh.
# Runs every scenario inside a scratch directory (DCE_ROOT) with mocked docker, systemctl,
# curl and friends, so it needs no CoreELEC box, no root and no network.
#
#   bash tests/run-tests.sh

set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../docker-coreelec.sh
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

PASS=0; FAILS=0
ok()    { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()   { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }

# ------------------------------------------------------------------ mocks
M=$W/mocks; P=$W/pkg; mkdir -p "$M" "$P/docker"
export MOCK_STATE=$W/state

# docker CLI: the engine that is "up" is whichever dockerd path is in $S/up
cat > "$M/docker-cli" <<'EOF'
#!/bin/bash
S=$MOCK_STATE
up()  { [ -s "$S/up" ]; }
eng() { "$(cat "$S/up")" --version | sed -n 's/.*version \([^,]*\),.*/\1/p'; }
case "$1" in
  version) up || exit 1; eng ;;
  info)    up || exit 1; echo "$(eng), cgroup v1" ;;
  ps)      up || exit 1
           case "$*" in
             *-aq*) cat "$S/running" 2>/dev/null; echo id_stopped ;;
             *-q*)  cat "$S/running" 2>/dev/null ;;
             *)     sed 's/^/c-/' "$S/running" 2>/dev/null ;;
           esac ;;
  stop)    : > "$S/running" ;;
  start)   shift; for i in "$@"; do echo "$i" >> "$S/running"; done; sort -u -o "$S/running" "$S/running" ;;
  image)   if [ -f "$S/arch32" ]; then echo arm; else echo arm64; fi ;;
  inspect) [ "$2" = "-f" ] || { echo "[]"; exit 0; }
           id=${4:-}
           case "$3" in
             *AutoRemove*)   case "$id" in id_rm*) echo true ;; *) echo false ;; esac ;;
             *State*)        if [ -f "$S/failnew" ] && eng | grep -q '^29'; then echo falsetrue; else echo truefalse; fi ;;
             *Config.Image*) echo "img-$id" ;;
             *Image*)        echo "sha-$id" ;;
             *Name*)         echo "/c-$id" ;;
           esac ;;
  logs)    echo "mock log line" ;;
esac
exit 0
EOF

# systemctl: models the docker unit (symlink = add-on, regular file = ours) and dependents
cat > "$M/systemctl" <<'EOF'
#!/bin/bash
S=$MOCK_STATE
SVC=$DCE_ROOT/storage/.config/system.d/service.system.docker.service
echo "systemctl $*" >> "$S/calls"
args=(); for a in "$@"; do [ "$a" = "--no-block" ] || args+=("$a"); done; set -- "${args[@]}"
engine_for_unit() {
  if [ -L "$SVC" ]; then echo "$(dirname "$(dirname "$(readlink "$SVC")")")/bin/dockerd"
  elif [ -f "$SVC" ]; then echo "$DCE_ROOT/storage/.docker/bin/dockerd"; fi
}
case "${1:-}" in
  stop)    if [ "${2:-}" = service.system.docker.service ]; then : > "$S/up"; : > "$S/active"; fi ;;
  start)   shift
           for u in "$@"; do
             if [ "$u" = service.system.docker.service ]; then
               e=$(engine_for_unit); [ -n "$e" ] || exit 1
               if [ -f "$S/brokendaemon" ] && "$e" --version | grep -q 'version 29'; then continue; fi
               echo "$e" > "$S/up"
             else
               [ -s "$S/up" ] || continue
               if [ -f "$S/failunit" ] && grep -q 'bin/dockerd' "$S/up" && "$(cat "$S/up")" --version | grep -q 'version 29'; then continue; fi
               echo "$u" >> "$S/active"
             fi
           done ;;
  is-active) [ "${2:-}" = -q ] && shift; grep -qx "${2:-}" "$S/active" 2>/dev/null; exit $? ;;
  list-dependencies) cat "$S/revdeps" 2>/dev/null ;;
  enable)  case "${2:-}" in */*) [ -f "$SVC" ] && [ ! -L "$SVC" ] || ln -sf "$2" "$SVC" ;; esac ;;
  disable) [ -L "$SVC" ] && rm -f "$SVC" ;;
esac
exit 0
EOF

# systemd-run: when enabled, runs the command with ONLY the --setenv variables (like real
# transient units do), so the tests show which settings reach the background run.
cat > "$M/systemd-run" <<EOF
#!/bin/bash
M=$M
EOF
cat >> "$M/systemd-run" <<'EOF'
[ -f "$MOCK_STATE/sdrun_ok" ] || exit 1
envs=(); while [ $# -gt 0 ]; do
  case "$1" in --setenv=*) envs+=("${1#--setenv=}") ;; --unit=*) ;; *) break ;; esac; shift
done
env -i PATH="$M:/usr/bin:/bin" MOCK_STATE="$MOCK_STATE" "${envs[@]}" "$@" >/dev/null 2>&1 </dev/null &
exit 0
EOF

cat > "$M/uname" <<'EOF'
#!/bin/bash
if [ "${1:-}" = -m ]; then echo "${MOCK_ARCH:-aarch64}"; else echo 4.9.113; fi
EOF

cat > "$M/curl" <<EOF
#!/bin/bash
P=$P
EOF
cat >> "$M/curl" <<'EOF'
out=""; url="${*: -1}"; eff=0
while [ $# -gt 0 ]; do case "$1" in -o) out=$2; shift;; -w) eff=1; shift;; esac; shift; done
if [ $eff = 1 ]; then
  case "$url" in
    *compose*) echo https://github.com/docker/compose/releases/tag/v2.40.3 ;;
    *buildx*)  echo https://github.com/docker/buildx/releases/tag/v0.29.1 ;;
  esac; exit 0
fi
case "$url" in
  */aarch64/) echo '<a href="docker-29.2.0.tgz"> <a href="docker-29.10.1.tgz"> <a href="docker-29.9.0.tgz"> <a href="docker-rootless-extras-29.10.1.tgz">' ;;
  */docker-29.10.1.tgz) cp "$P/docker.tgz" "$out" ;;
  */docker-compose-linux-aarch64.sha256) echo "$(sha256sum "$P/compose" | cut -d' ' -f1) *docker-compose-linux-aarch64" ;;
  */docker-compose-linux-aarch64) cp "$P/compose" "$out" ;;
  */checksums.txt) echo "$(sha256sum "$P/buildx" | cut -d' ' -f1) *buildx-v0.29.1.linux-arm64"; echo "abc *buildx-v0.29.1.linux-amd64" ;;
  */buildx-v0.29.1.linux-arm64) cp "$P/buildx" "$out" ;;
  *) exit 22 ;;
esac
EOF

printf '#!/bin/bash\nexit 1\n' > "$M/pidof"
printf '#!/bin/bash\nexit 1\n' > "$M/mountpoint"
printf '#!/bin/bash\necho "mock journal: something went wrong"\n' > "$M/journalctl"
printf '#!/bin/bash\nexit 0\n' > "$M/killall"
chmod +x "$M"/*

mk_dockerd() {   # $1 = file, $2 = version
    cat > "$1" <<EOF
#!/bin/bash
if [ "\${1:-}" = "--validate" ]; then
  if grep -q cluster-store "\$3"; then echo 'the following directives dont match any configuration option: cluster-store'; exit 1; fi
  echo "configuration OK"; exit 0
fi
echo "Docker version $2, build abc"
EOF
    chmod +x "$1"
}

# the "new release" served by the curl mock
mk_dockerd "$P/docker/dockerd" 29.10.1
for b in containerd containerd-shim-runc-v2 ctr docker-init docker-proxy runc; do
    printf '#!/bin/bash\necho %s 29\n' "$b" > "$P/docker/$b"
done
cp "$M/docker-cli" "$P/docker/docker"
chmod +x "$P"/docker/*
tar -czf "$P/docker.tgz" -C "$P" docker
printf '#!/bin/bash\necho 2.40.3\n' > "$P/compose"
printf '#!/bin/bash\necho "github.com/docker/buildx v0.29.1 abc"\n' > "$P/buildx"
chmod +x "$P/compose" "$P/buildx"

# ------------------------------------------------------------------ scenario setup
new_box() {
    export DCE_ROOT=$W/box
    rm -rf "$DCE_ROOT" "$MOCK_STATE"
    mkdir -p "$DCE_ROOT/storage/.config/system.d" "$DCE_ROOT/var/run" "$MOCK_STATE"
    : > "$MOCK_STATE/active"
    B=$DCE_ROOT/storage/.docker
    SVC=$DCE_ROOT/storage/.config/system.d/service.system.docker.service
    CONF=$DCE_ROOT/storage/.config/docker/daemon.json
    AD=$DCE_ROOT/storage/.kodi/addons/service.system.docker
    ADATA=$DCE_ROOT/storage/.kodi/userdata/addon_data/service.system.docker
    LOGF=$DCE_ROOT/storage/docker-coreelec.log
}

running() { printf 'id_wireguard\nid_pihole\nid_medusa\n' > "$MOCK_STATE/running"; }

setup_legacy() {
    new_box
    mkdir -p "$B/bin" "$B/data-root/containers/abc" "$DCE_ROOT/storage/.config/docker"
    mk_dockerd "$B/bin/dockerd" 22.06.0-beta.0-167-gec89e7cde1.m
    for b in containerd runc rootlesskit vpnkit ctop; do printf '#!/bin/bash\necho old\n' > "$B/bin/$b"; done
    printf '#!/bin/bash\necho compose-v1-wrapper\n' > "$B/bin/docker-compose"
    cp "$M/docker-cli" "$B/bin/docker"; chmod +x "$B"/bin/*
    cat > "$CONF" <<EOF
{
  "cluster-store": "",
  "data-root": "$B/data-root",
  "storage-driver": "overlay2"
}
EOF
    printf '[Service]\nExecStart=/storage/.docker/bin/dockerd\n' > "$SVC"
    echo old-meta > "$B/data-root/containers/abc/config.v2.json"
    echo big-log > "$B/data-root/containers/abc/abc-json.log"
    running; echo "$B/bin/dockerd" > "$MOCK_STATE/up"
}

setup_addon() {   # $1 = "noconf" to leave out docker.conf
    new_box
    mkdir -p "$AD/bin" "$AD/system.d" "$ADATA/config" "$ADATA/docker/containers/abc"
    mk_dockerd "$AD/bin/dockerd" 27.5.1
    cp "$M/docker-cli" "$AD/bin/docker"; chmod +x "$AD"/bin/*
    printf '[Service]\nExecStart=%s/bin/dockerd\n' "$AD" > "$AD/system.d/service.system.docker.service"
    ln -s "$AD/system.d/service.system.docker.service" "$SVC"
    if [ "${1:-}" != noconf ]; then
        printf 'DOCKER_DAEMON_OPTS="--data-root=%s/docker --dns 1.1.1.1"\nDOCKER_STORAGE_OPTS="--storage-driver=overlay2"\n' "$ADATA" > "$ADATA/config/docker.conf"
    fi
    echo addon-meta > "$ADATA/docker/containers/abc/config.v2.json"
    # a unit like the add-on's examples: docker run --rm, managed by systemd
    printf '[Unit]\nRequires=service.system.docker.service\n[Service]\nExecStart=%s/bin/docker run --rm sabnzbd\n' "$AD" \
        > "$DCE_ROOT/storage/.config/system.d/sabnzbd.service"
    printf 'service.system.docker.service\n  kodi.target\n  sabnzbd.service\n' > "$MOCK_STATE/revdeps"
    echo sabnzbd.service > "$MOCK_STATE/active"
    touch "$MOCK_STATE/arch32"
    running; echo id_rm_sabnzbd >> "$MOCK_STATE/running"
    echo "$AD/bin/dockerd" > "$MOCK_STATE/up"
}

run() {   # run the tool non-interactively, in the foreground
    PATH=$M:$PATH NO_DETACH=1 WAIT_TRIES=2 SETTLE_SECONDS=0 bash "$SCRIPT" "$@" -y > "$W/out.txt" 2>&1
}
engine_is() { [ "$(cat "$MOCK_STATE/up")" = "$1" ]; }
json_ok()   { python3 -m json.tool "$1"; }
has()       { grep -q -- "$2" "$1"; }
hasnt()     { ! grep -q -- "$2" "$1"; }
running_ok() { for i in id_wireguard id_pihole id_medusa; do grep -qx "$i" "$MOCK_STATE/running" || return 1; done; }
unit_active() { grep -qx "$1" "$MOCK_STATE/active"; }
wait_log() { for _ in $(seq 1 20); do grep -q "$1" "$LOGF" 2>/dev/null && return 0; sleep 1; done; return 1; }

# ------------------------------------------------------------------ tests
echo "help and status"
new_box
check "help works" bash -c "PATH=$M:\$PATH bash '$SCRIPT' help | grep -q 'Commands:'"
check "status works without Docker" bash -c "PATH=$M:\$PATH bash '$SCRIPT' status | grep -q 'no Docker installed'"
check "status shows (none) for backups" bash -c "PATH=$M:\$PATH bash '$SCRIPT' status | grep -q '(none)'"

echo "maintainer commands"
new_box
check "print-default-config is valid JSON" bash -c "PATH=$M:\$PATH bash '$SCRIPT' print-default-config | python3 -m json.tool"
check "print-default-config honours MIN_API_VERSION" bash -c "PATH=$M:\$PATH MIN_API_VERSION=1.24 bash '$SCRIPT' print-default-config | grep -q min-api-version"
check "latest-versions" bash -c "test \"\$(PATH=$M:\$PATH bash '$SCRIPT' latest-versions)\" = '29.10.1 v2.40.3 v0.29.1'"
check "maintainer commands change nothing" test ! -e "$DCE_ROOT/storage/.docker/bin"

echo "fresh install"
new_box; run install; rc=$?
check "exit code 0" test "$rc" = 0
check "log says DONE" has "$LOGF" "DONE"
check "dockerd 29.10.1 installed" bash -c "'$B/bin/dockerd' --version | grep -q 29.10.1"
check "compose and buildx plugins" test -x "$B/cli-plugins/docker-compose" -a -x "$B/cli-plugins/docker-buildx"
check "docker-compose symlink" test -L "$B/bin/docker-compose"
check "docker-coreelec command" test -L "$B/bin/docker-coreelec" -a -f "$B/docker-coreelec.sh"
check "marker written" test -f "$B/.docker-coreelec-modern"
check "daemon.json is valid JSON" json_ok "$CONF"
check "daemon.json data-root" has "$CONF" "\"data-root\": \"$B/data-root\""
check "graph driver kept (no containerd store)" has "$CONF" '"containerd-snapshotter": false'
check "no min-api-version by default" hasnt "$CONF" min-api-version
check "service is a regular file" test -f "$SVC" -a ! -L "$SVC"
check "service enabled" has "$MOCK_STATE/calls" "enable service.system.docker.service"
check "PATH added to .profile" has "$DCE_ROOT/storage/.profile" "$B/bin"
check "new engine running" engine_is "$B/bin/dockerd"
check "update-tmp cleaned up" test ! -e "$B/update-tmp"

echo "install again"
run install
check "reports up to date" has "$W/out.txt" "up to date"

echo "forced reinstall keeps a valid daemon.json"
sum1=$(md5sum < "$CONF")
FORCE=1 run install
check "update finished" has "$LOGF" "DONE"
check "daemon.json kept" test "$sum1" = "$(md5sum < "$CONF")"
check "said it kept the config" has "$LOGF" "will be kept"

echo "update of docker-coreelec-modern, then rollback"
new_box; run install; mk_dockerd "$B/bin/dockerd" 29.2.0; echo "$B/bin/dockerd" > "$MOCK_STATE/up"; running
run install
check "updated to 29.10.1" bash -c "'$B/bin/dockerd' --version | grep -q 29.10.1"
check "backup kind modern" bash -c "ls -d '$B'/backup/*_modern"
run rollback
check "back on 29.2.0" bash -c "'$B/bin/dockerd' --version | grep -q 29.2.0"
check "marker kept" test -f "$B/.docker-coreelec-modern"
check "containers running" running_ok

echo "MIN_API_VERSION"
new_box; MIN_API_VERSION=1.24 run install
check "min-api-version written" has "$CONF" '"min-api-version": "1.24"'
check "still valid JSON" json_ok "$CONF"

echo "upgrade from tamusiunas/docker-coreelec"
setup_legacy; run install
check "finished" has "$LOGF" "DONE"
check "invalid old daemon.json replaced" hasnt "$CONF" cluster-store
check "data-root carried over" has "$CONF" "\"data-root\": \"$B/data-root\""
check "obsolete binaries removed" test ! -e "$B/bin/rootlesskit"
check "ctop kept" test -f "$B/bin/ctop"
check "Compose v1 wrapper replaced" test -L "$B/bin/docker-compose"
check "all containers running again" running_ok
check "backup has old binaries" bash -c "ls '$B'/backup/*_legacy/bin/rootlesskit"
check "backup has old daemon.json" bash -c "grep -q cluster-store '$B'/backup/*_legacy/daemon.json"
check "container logs left out of backup" bash -c "! ls '$B'/backup/*_legacy/data-root-meta/containers/abc/abc-json.log"

echo "tamusiunas upgrade, a container does not come back -> automatic rollback"
setup_legacy; touch "$MOCK_STATE/failnew"; run install; rc=$?
check "exit code not 0" test "$rc" != 0
check "reports rolling back" has "$W/out.txt" "rolling back"
check "old dockerd back" bash -c "'$B/bin/dockerd' --version | grep -q 22.06"
check "old binaries back" test -f "$B/bin/rootlesskit"
check "old daemon.json back" has "$CONF" cluster-store
check "marker removed again" test ! -e "$B/.docker-coreelec-modern"
check "metadata restored" has "$B/data-root/containers/abc/config.v2.json" old-meta
check "container log still there" test -f "$B/data-root/containers/abc/abc-json.log"
check "containers running again" running_ok

for fp in after_stop in_backup install_files; do
    echo "tamusiunas upgrade, failure at '$fp' -> old Docker back"
    setup_legacy; DCE_TEST_FAIL=$fp run install
    check "old dockerd in place" bash -c "'$B/bin/dockerd' --version | grep -q 22.06"
    check "old engine running" engine_is "$B/bin/dockerd"
    check "containers running" running_ok
done

echo "migration from the Kodi add-on"
setup_addon; run install
check "finished" has "$LOGF" "DONE"
check "add-on moved into backup" bash -c "test ! -e '$AD' && ls -d '$B'/backup/*_addon/addon"
check "data-root moved" test -f "$B/data-root/containers/abc/config.v2.json" -a ! -e "$ADATA/docker"
check "meta records the move" bash -c "grep -q DATA_MOVED=1 '$B'/backup/*_addon/meta"
check "daemon.json points to new data-root" has "$CONF" "\"data-root\": \"$B/data-root\""
check "service replaced by ours" test -f "$SVC" -a ! -L "$SVC"
check "user unit rewritten" has "$DCE_ROOT/storage/.config/system.d/sabnzbd.service" "$B/bin/docker run"
check "user unit original in backup" bash -c "grep -q '$AD/bin/docker' '$B'/backup/*_addon/units/sabnzbd.service"
check "new engine running" engine_is "$B/bin/dockerd"
check "all containers running" running_ok
check "--rm container not started by ID" hasnt "$MOCK_STATE/running" id_rm_sabnzbd
check "dependent service started again" unit_active sabnzbd.service
check "targets not touched" hasnt "$MOCK_STATE/calls" "start kodi.target"
check "lists 32-bit containers" has "$LOGF" "32-bit images"
check "warned about --dns not carried over" has "$W/out.txt" "1.1.1.1"

echo "migration, the dependent service does not come back -> automatic rollback"
setup_addon; touch "$MOCK_STATE/failunit"; run install
check "reports rolling back" has "$W/out.txt" "rolling back"
check "add-on back" test -x "$AD/bin/dockerd"
check "service active again on the add-on" unit_active sabnzbd.service

echo "migration, new Docker does not start -> automatic rollback"
setup_addon; touch "$MOCK_STATE/brokendaemon"; run install
check "reports rolling back" has "$W/out.txt" "rolling back"
check "add-on back in place" test -x "$AD/bin/dockerd"
check "data-root back" has "$ADATA/docker/containers/abc/config.v2.json" addon-meta
check "add-on service enabled again" test -L "$SVC"
check "our files removed" test ! -e "$B/bin/dockerd" -a ! -e "$CONF"
check "user unit restored" has "$DCE_ROOT/storage/.config/system.d/sabnzbd.service" "$AD/bin/docker run"
check "add-on engine running" engine_is "$AD/bin/dockerd"
check "containers running again" running_ok

for fp in in_backup after_addon_disable; do
    echo "migration, failure at '$fp' -> add-on back"
    setup_addon; DCE_TEST_FAIL=$fp run install
    check "add-on in place" test -x "$AD/bin/dockerd"
    check "add-on service linked" test -L "$SVC"
    check "data-root in place" test -f "$ADATA/docker/containers/abc/config.v2.json"
    check "add-on engine running" engine_is "$AD/bin/dockerd"
    check "containers running" running_ok
done

echo "migration without docker.conf"
setup_addon noconf; run install
check "finished" has "$LOGF" "DONE"
check "default add-on data-root moved" test -f "$B/data-root/containers/abc/config.v2.json"

echo "migration with data-root behind a symlink stays in place"
setup_addon; mkdir -p "$DCE_ROOT/otherdisk"; mv "$ADATA/docker" "$DCE_ROOT/otherdisk/docker"; ln -s "$DCE_ROOT/otherdisk/docker" "$ADATA/docker"
run install
check "finished" has "$LOGF" "DONE"
check "data not moved" test -L "$ADATA/docker" -a -f "$DCE_ROOT/otherdisk/docker/containers/abc/config.v2.json"
check "daemon.json points at the old path" has "$CONF" "\"data-root\": \"$ADATA/docker\""

echo "manual rollback after a successful migration"
setup_addon; run install; run rollback
check "rollback finished" has "$LOGF" "rollback finished"
check "add-on back" test -x "$AD/bin/dockerd"
check "data-root back" test -f "$ADATA/docker/containers/abc/config.v2.json"
check "add-on engine running" engine_is "$AD/bin/dockerd"
check "backup marked restored" bash -c "ls '$B'/backup/*_addon/restored"
run rollback
check "second rollback finds nothing left" has "$W/out.txt" "no backup found"

echo "rollback refused when the add-on was installed again"
setup_addon; run install; mkdir -p "$AD/bin"; mk_dockerd "$AD/bin/dockerd" 27.5.1
before=$(cat "$MOCK_STATE/up"); run rollback
check "refused" has "$W/out.txt" "installed again"
check "nothing stopped" engine_is "$before"

echo "uninstall"
new_box; run install; mkdir -p "$B/data-root/volumes/x"; run uninstall
check "binaries removed" test ! -e "$B/bin/dockerd"
check "service removed" test ! -e "$SVC"
check "data kept" test -d "$B/data-root/volumes/x"
check "config set aside" test -f "$CONF.removed"
check "PATH removed from .profile" hasnt "$DCE_ROOT/storage/.profile" "$B/bin"
new_box; run install; mkdir -p "$B/data-root/volumes/x"; run uninstall --purge
check "--purge deletes data" test ! -e "$B/data-root"

echo "background run when the SSH session drops (setsid fallback)"
setup_legacy
PATH=$M:$PATH WAIT_TRIES=2 SETTLE_SECONDS=0 timeout 3 bash "$SCRIPT" install -y > "$W/out.txt" 2>&1
check "background run finished" wait_log DONE
check "lock released" test ! -e "$DCE_ROOT/var/run/docker-coreelec.lock"

echo "background run through systemd-run keeps the settings"
new_box; run install; mkdir -p "$B/data-root/volumes/x"; touch "$MOCK_STATE/sdrun_ok"
PATH=$M:$PATH WAIT_TRIES=2 SETTLE_SECONDS=0 timeout 3 bash "$SCRIPT" uninstall --purge -y > "$W/out.txt" 2>&1
check "uninstall finished" wait_log "DONE: Docker removed"
check "--purge survived into the background" test ! -e "$B/data-root"

echo "refusals"
new_box; MOCK_ARCH=armv7l run install
check "refuses a 32-bit kernel" has "$W/out.txt" "64-bit (aarch64) kernel"
setup_legacy; mkdir -p "$AD/bin"; mk_dockerd "$AD/bin/dockerd" 27.5.1; run install
check "refuses add-on plus docker-coreelec" has "$W/out.txt" "Uninstall the add-on in Kodi first"
new_box; run uninstall
check "uninstall without Docker" has "$W/out.txt" "not installed"
new_box; mkdir -p "$DCE_ROOT/var/run/docker-coreelec.lock"; run install
check "refuses while another run is active" has "$W/out.txt" "another docker-coreelec run is active"

echo
echo "passed: $PASS  failed: $FAILS"
[ "$FAILS" -eq 0 ]
