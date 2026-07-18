FROM --platform=linux/amd64 ubuntu:24.04@sha256:52df9b1ee71626e0088f7d400d5c6b5f7bb916f8f0c82b474289a4ece6cf3faf

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    CARGO_HOME=/opt/rust/cargo-home \
    PATH=/opt/rust/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Freeze apt to one signed Ubuntu archive snapshot. The image digest and this
# timestamp together keep the host package set from moving between builds. The
# minimal base has the Ubuntu archive signing key but no CA bundle, so bootstrap
# only ca-certificates without TLS peer verification. APT still verifies the
# signed InRelease metadata and package hashes; every later download uses normal
# TLS verification.
RUN printf '%s\n' \
      'Types: deb' \
      'URIs: https://snapshot.ubuntu.com/ubuntu/20260715T000000Z' \
      'Suites: noble noble-updates noble-security' \
      'Components: main universe' \
      'Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg' \
      > /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::https::Verify-Peer=false update \
    && apt-get -o Acquire::https::Verify-Peer=false install \
      --yes --no-install-recommends ca-certificates \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
      bash \
      build-essential \
      cmake \
      coreutils \
      curl \
      diffutils \
      file \
      findutils \
      git \
      gzip \
      libssl-dev \
      patch \
      pkg-config \
      protobuf-compiler \
      python3 \
      unzip \
      xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install exact dated Rust components instead of resolving a mutable channel
# through rustup. Every archive is frozen in build/inputs.lock.json.
RUN set -eu; \
    install_component() { \
      archive_name="$1"; \
      extracted_dir="$2"; \
      expected_size="$3"; \
      expected_sha256="$4"; \
      url="https://static.rust-lang.org/dist/2026-04-16/${archive_name}"; \
      curl --fail --location --proto '=https' --tlsv1.2 \
        --output "/tmp/${archive_name}" "$url"; \
      test "$(wc -c < "/tmp/${archive_name}")" = "$expected_size"; \
      printf '%s  %s\n' "$expected_sha256" "/tmp/${archive_name}" \
        | sha256sum --check --strict -; \
      tar --extract --gzip --file "/tmp/${archive_name}" --directory /tmp; \
      "/tmp/${extracted_dir}/install.sh" \
        --prefix=/opt/rust --disable-ldconfig; \
      rm -rf "/tmp/${archive_name}" "/tmp/${extracted_dir}"; \
    }; \
    install_component \
      rustc-1.95.0-x86_64-unknown-linux-gnu.tar.gz \
      rustc-1.95.0-x86_64-unknown-linux-gnu \
      135179262 \
      fef749c4abb4b4bde5ebf773bec550003ce5b4410579cecd69a365e5c0c5106a; \
    install_component \
      cargo-1.95.0-x86_64-unknown-linux-gnu.tar.gz \
      cargo-1.95.0-x86_64-unknown-linux-gnu \
      15405121 \
      47ebc468721a6ff3fb27dff33e632a4cb6246d0ea061814bcd4fe601d18c69a8; \
    install_component \
      rust-std-1.95.0-x86_64-unknown-linux-gnu.tar.gz \
      rust-std-1.95.0-x86_64-unknown-linux-gnu \
      49435219 \
      edbd20f8fc0a617f85ffb79fa6c22aa6def0e570de3f94be1a6e5ab1f77f763c; \
    install_component \
      rust-std-1.95.0-aarch64-linux-android.tar.gz \
      rust-std-1.95.0-aarch64-linux-android \
      40649293 \
      90de6cc98ec27a824429bf8b9140ced0dfa9947d69b0ae0d20f4700e0b437c5e; \
    install_component \
      rust-src-1.95.0.tar.gz \
      rust-src-1.95.0 \
      5823939 \
      98548815569318eb60afe7189ace6bca4ba6e4ae59a54f111d276ab78d6ddd10; \
    test "$(rustc --version)" = 'rustc 1.95.0 (59807616e 2026-04-14)'; \
    test "$(cargo --version)" = 'cargo 1.95.0 (f2d3ce0bd 2026-03-21)'; \
    target_libdir="$(rustc --print target-libdir --target aarch64-linux-android)"; \
    test -d "$target_libdir"; \
    test "${target_libdir%/aarch64-linux-android/lib}" != "$target_libdir"

COPY build/fetch-inputs.sh /usr/local/bin/fetch-android-build-inputs
COPY build/build-rusty-v8.sh /usr/local/bin/build-rusty-v8-android
COPY build/build-codex-android.sh /usr/local/bin/build-codex-android
COPY build/android-target.env /usr/local/share/codex-android/android-target.env
COPY build/inputs.lock.json /usr/local/share/codex-android/inputs.lock.json
COPY build/rusty-v8-submodules.lock /usr/local/share/codex-android/rusty-v8-submodules.lock

ENV ANDROID_TARGET_ENV=/usr/local/share/codex-android/android-target.env \
    ANDROID_INPUTS_LOCK=/usr/local/share/codex-android/inputs.lock.json \
    RUSTY_V8_SUBMODULE_LOCK=/usr/local/share/codex-android/rusty-v8-submodules.lock

RUN chmod 0755 \
      /usr/local/bin/fetch-android-build-inputs \
      /usr/local/bin/build-rusty-v8-android \
      /usr/local/bin/build-codex-android

WORKDIR /work
CMD ["/bin/bash"]
