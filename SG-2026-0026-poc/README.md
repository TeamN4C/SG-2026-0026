# SG-2026-0026 — CVE-2026-62146 Persisted ShmPath Poisoning PoC

This PoC builds CRI-O v1.36.3 at commit
`b24632ab44955fa84685640d4177f3c554e9f69c` and runs it as a nested runtime
inside Docker. A Pod sandbox is created with
`io.kubernetes.cri-o.ShmPath=<selected-directory>` in its annotations. Before
CRI-O restarts, containers use the shared-memory directory created by the
runtime. After the restart, a container created in the same sandbox uses the
selected directory as the read-write source for `/dev/shm`.

## Result

```text
[+] persisted ShmPath: /var/tmp/sago-2026-0026-poc/attacker-selected-directory
[+] before restart: /dev/shm source is CRI-O-owned
[+] after restart: /dev/shm source = /var/tmp/sago-2026-0026-poc/attacker-selected-directory
[+] host marker: container-write-after-restart
[PASS] persisted sandbox state controlled the post-restart /dev/shm bind source
```

## Run

```sh
chmod +x run
./run
```

Requirements:

- Docker Engine with privileged-container support
- Internet access while building the image and pulling the nested images
- `linux/amd64` or `linux/arm64`

The verifier runs in a privileged Docker container. Use a disposable test
host.

## Sequence

1. Build the affected CRI-O commit.
2. Start CRI-O with isolated `vfs` storage and a private Unix socket.
3. Create a sandbox containing the selected `ShmPath` annotation.
4. Create a container and record its `/dev/shm` mount source.
5. Remove the container and restart CRI-O.
6. Create another container in the same sandbox.
7. Write `/dev/shm/proof.txt` and verify the file in the selected directory.

## Patched build

The same scenario can be run against the `release-1.36` fix:

```sh
docker build --pull \
  --build-arg CRIO_COMMIT=e2fa878d41bce3c2668e93bd29179d8f770fb13f \
  -t sg-2026-0026-poc:patched .
docker run --rm --privileged --cgroupns=host sg-2026-0026-poc:patched
```

The patched build rejects the supplied internal value at the persistence
check.

## Files

| File | Purpose |
| --- | --- |
| `run` | Builds and starts the verifier |
| `Dockerfile` | Builds CRI-O and the test image |
| `scenario.sh` | Creates the sandbox and checks the mount source before and after restart |
