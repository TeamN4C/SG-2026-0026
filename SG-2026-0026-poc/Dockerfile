FROM golang:1.26.3-bookworm@sha256:386d475a660466863d9f8c766fec64d7fdad3edac2c6a05020c09534d71edb4b

ARG CRIO_COMMIT=b24632ab44955fa84685640d4177f3c554e9f69c
ARG CRICTL_VERSION=v1.35.0

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    ca-certificates \
    containernetworking-plugins \
    conmon \
    crun \
    curl \
    gcc \
    git \
    iproute2 \
    iptables \
    jq \
    libc6-dev \
    libassuan-dev \
    libbtrfs-dev \
    libglib2.0-dev \
    libgpg-error-dev \
    libgpgme-dev \
    libseccomp-dev \
    libselinux1-dev \
    libsystemd-dev \
    libudev-dev \
    make \
    pkg-config \
    procps \
    runc \
    uidmap \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$(dpkg --print-architecture)" in \
        amd64) cri_arch=amd64; cri_sha256=2e141e5b22cb189c40365a11807d69b76b9b3caced89fac2f4ec879408ce2177 ;; \
        arm64) cri_arch=arm64; cri_sha256=519071de89b64c43e2a1661bb5489c6c3fd5e9e5fcef75e50e542b0c891f1118 ;; \
        *) echo "unsupported architecture" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/crictl.tar.gz \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${cri_arch}.tar.gz"; \
    echo "${cri_sha256}  /tmp/crictl.tar.gz" | sha256sum -c -; \
    tar -xzf /tmp/crictl.tar.gz -C /usr/local/bin crictl; \
    rm /tmp/crictl.tar.gz

RUN git clone https://github.com/cri-o/cri-o.git /src/cri-o \
    && git -C /src/cri-o checkout --detach "$CRIO_COMMIT" \
    && git -C /src/cri-o status --short \
    && make -C /src/cri-o \
        BUILDTAGS="containers_image_openpgp containers_image_ostree_stub" \
        bin/crio bin/pinns

COPY scenario.sh /usr/local/bin/sago-2026-0026-poc

ENTRYPOINT ["/usr/local/bin/sago-2026-0026-poc"]
