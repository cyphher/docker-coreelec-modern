#!/bin/bash
# Mechanical checks of the upstream releases docker-coreelec.sh depends on.
# Run by .github/workflows/upstream-check.yml; writes $OUT/status.json and $OUT/summary.md.
# Always exits 0: the result is in status.json ("result": "pass" | "fail").

set -u
OUT=${OUT:-out}
SCRIPT=${SCRIPT:-docker-coreelec.sh}
EXPECTED_BINS="dockerd docker containerd containerd-shim-runc-v2 ctr runc docker-init docker-proxy"
mkdir -p "$OUT"
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
CHECKS="$W/checks.tsv"; : > "$CHECKS"

add() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$CHECKS"; }   # status, name, detail

read -r DOCKER COMPOSE BUILDX <<< "$(bash "$SCRIPT" latest-versions 2>/dev/null)"
if [ -z "${DOCKER:-}" ] || [ -z "${COMPOSE:-}" ] || [ -z "${BUILDX:-}" ]; then
    add FAIL latest-versions "could not determine latest versions (got: '${DOCKER:-}' '${COMPOSE:-}' '${BUILDX:-}')"
else
    add PASS latest-versions "Docker $DOCKER, Compose $COMPOSE, Buildx $BUILDX"

    # 1. The aarch64 static tarball exists and contains what the script copies and tests.
    url="https://download.docker.com/linux/static/stable/aarch64/docker-$DOCKER.tgz"
    if curl -fsSL --retry 3 -o "$W/aarch64.tgz" "$url"; then
        list=$(tar -tzf "$W/aarch64.tgz" | sed -n 's#^docker/##p' | grep -v '^$' | sort)
        missing=""; for b in $EXPECTED_BINS; do echo "$list" | grep -qx "$b" || missing="$missing $b"; done
        extra=$(for f in $list; do case " $EXPECTED_BINS " in *" $f "*) ;; *) printf '%s ' "$f" ;; esac; done)
        if [ -z "$missing" ]; then add PASS aarch64-tarball "all expected binaries present"
        else add FAIL aarch64-tarball "missing:$missing"; fi
        [ -n "$extra" ] && add INFO aarch64-tarball-extra "new files in the tarball: $extra"
    else
        add FAIL aarch64-tarball "download failed: $url"
    fi

    # 2. The daemon.json the script writes is accepted by the real new dockerd.
    #    Validation does not depend on the CPU, so the x86_64 build of the same version is used.
    url="https://download.docker.com/linux/static/stable/x86_64/docker-$DOCKER.tgz"
    if curl -fsSL --retry 3 -o "$W/x86.tgz" "$url" && tar -xzf "$W/x86.tgz" -C "$W"; then
        for variant in default min-api-version; do
            if [ "$variant" = min-api-version ]; then
                MIN_API_VERSION=1.24 bash "$SCRIPT" print-default-config > "$W/$variant.json"
            else
                bash "$SCRIPT" print-default-config > "$W/$variant.json"
            fi
            if out=$(sudo "$W/docker/dockerd" --validate --config-file "$W/$variant.json" 2>&1); then
                add PASS "config-$variant" "$out"
            else
                add FAIL "config-$variant" "$(echo "$out" | tr '\n' ' ')"
            fi
        done
    else
        add FAIL config-validate "download failed: $url"
    fi

    # 3. Compose asset and its checksum.
    base="https://github.com/docker/compose/releases/download/$COMPOSE"
    if curl -fsSIL -o /dev/null "$base/docker-compose-linux-aarch64" \
       && curl -fsSL "$base/docker-compose-linux-aarch64.sha256" | grep -Eq '^[0-9a-f]{64}'; then
        add PASS compose-asset "docker-compose-linux-aarch64 and .sha256 present"
    else
        add FAIL compose-asset "docker-compose-linux-aarch64 or its .sha256 missing in $COMPOSE"
    fi

    # 4. Buildx asset and its checksum entry.
    base="https://github.com/docker/buildx/releases/download/$BUILDX"
    f="buildx-$BUILDX.linux-arm64"
    if curl -fsSIL -o /dev/null "$base/$f" \
       && curl -fsSL "$base/checksums.txt" | awk -v f="$f" '$2==f || $2=="*"f {found=1} END {exit !found}'; then
        add PASS buildx-asset "$f and checksums.txt entry present"
    else
        add FAIL buildx-asset "$f or its checksums.txt entry missing in $BUILDX"
    fi
fi

result=pass; grep -q '^FAIL' "$CHECKS" && result=fail

jq -n --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg docker "${DOCKER:-}" \
      --arg compose "${COMPOSE:-}" --arg buildx "${BUILDX:-}" --arg result "$result" \
      --rawfile checks "$CHECKS" '
  { checked_at: $checked_at, docker: $docker, compose: $compose, buildx: $buildx, result: $result,
    checks: ($checks | split("\n") | map(select(length > 0) | split("\t")
             | { status: .[0], name: .[1], detail: .[2] })) }' > "$OUT/status.json"

{
    echo "## Upstream check: $result"
    echo
    echo "Docker \`${DOCKER:-?}\` · Compose \`${COMPOSE:-?}\` · Buildx \`${BUILDX:-?}\` · $(date -u '+%F %H:%M UTC')"
    echo
    echo "| | Check | Detail |"
    echo "| --- | --- | --- |"
    while IFS=$'\t' read -r st name detail; do
        case "$st" in PASS) icon="✅" ;; FAIL) icon="❌" ;; *) icon="ℹ️" ;; esac
        echo "| $icon | $name | ${detail//|/\\|} |"
    done < "$CHECKS"
} > "$OUT/summary.md"

cat "$OUT/summary.md"
exit 0
