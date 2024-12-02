# Stalwart Dockerfile
FROM docker.io/lukemathwalker/cargo-chef:latest-rust-slim-bookworm AS chef
WORKDIR /build
RUN mkdir -p /build/.cargo

FROM chef AS planner
COPY . .
RUN cargo chef prepare --recipe-path /recipe.json

FROM chef AS version
COPY Cargo.toml .
RUN echo -n $(grep -m1 "version = \".*\"" Cargo.toml | cut -d'"' -f2) > /version && \
    date -u +"%Y-%m-%dT%H:%M:%SZ" > /date
    
FROM chef AS builder
COPY --from=planner /build/.cargo /build/.cargo
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -yq \
    build-essential \
    libclang-16-dev \
    pkg-config \
    libssl-dev && \
    git && \
    echo "[target.x86_64-unknown-linux-gnu]\nrustflags = [\"-C\", \"target-cpu=native\", \"-C\", \"codegen-units=16\"]\n" > /build/.cargo/config.toml && \
    echo "CARGO_BUILD_JOBS=$(nproc)" >> /build/.cargo/env

# Build dependencies separately for better caching
COPY --from=planner /recipe.json /recipe.json
RUN RUSTFLAGS="-C target-cpu=native" cargo chef cook --release --recipe-path /recipe.json

# Build application
COPY . .
RUN RUSTFLAGS="-C target-cpu=native" cargo build --release -p mail-server -p stalwart-cli --no-default-features --features "sqlite postgres mysql rocks elastic s3 redis azure" && \
    mv "/build/target/release" "/output"

RUN git rev-parse --short HEAD > /git-rev
FROM debian:bookworm-slim
COPY --from=version /version /tmp/version
COPY --from=version /date /tmp/date
COPY --from=builder /git-rev /tmp/git-rev

ENV VERSION=$(cat /tmp/version) \
    VCS_REF=$(cat /tmp/git-rev) \
    CREATED_AT=$(cat /tmp/date)
    
# OpenContainer Initiative labels
LABEL org.opencontainers.image.title="Stalwart Mail Server" \
      org.opencontainers.image.description="Secure & Modern All-in-One Mail Server (IMAP, JMAP, POP3, SMTP) - Community Build without Enterprise Features" \
      org.opencontainers.image.source="https://github.com/stalwartlabs/mail-server" \
      org.opencontainers.image.created="${CREATED_AT}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.vendor="OhEmmaGee" \
      org.opencontainers.image.documentation="https://stalw.art/docs" \
      org.opencontainers.image.base.name="debian:bookworm-slim"


WORKDIR /opt/stalwart-mail
RUN export DEBIAN_FRONTEND=noninteractive && \
    apt-get update && \
    apt-get install -yq ca-certificates libssl3 && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /output/stalwart-mail /usr/local/bin
COPY --from=builder /output/stalwart-cli /usr/local/bin
COPY ./resources/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod -R 755 /usr/local/bin

CMD ["/usr/local/bin/stalwart-mail"]
VOLUME [ "/opt/stalwart-mail" ]
EXPOSE 443 25 110 587 465 143 993 995 4190 8080
ENTRYPOINT ["/bin/sh", "/usr/local/bin/entrypoint.sh"]
