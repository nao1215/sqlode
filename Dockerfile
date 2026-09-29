# syntax=docker/dockerfile:1.27

# ---------- builder ----------
# Produces the self-contained `sqlode` escript. We pin the Gleam
# version to match the erlef/setup-beam toolchain used in CI so the
# artefact is byte-identical with what the release workflow ships.
FROM ghcr.io/gleam-lang/gleam:v1.18.1-erlang-alpine@sha256:7c82e4a284b7c05c26eac34db497ea0e63ce7cb04bd019d966d70338eb172b68 AS builder

WORKDIR /build

# `gleam deps download` reaches rebar3 for Erlang-native dependencies.
RUN apk add --no-cache bash curl \
    && curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# Resolve deps first so later source edits hit a cache layer.
COPY gleam.toml manifest.toml ./
RUN gleam deps download

# Copy source and bundle the escript the same way release.yml does:
# packed from the production Erlang shipment, so it carries sqlode and
# its runtime dependencies only.
COPY src ./src
COPY scripts/build_escript.sh scripts/escript.erl ./scripts/
RUN sh scripts/build_escript.sh /build/sqlode

# ---------- runtime ----------
# Minimal Erlang image so evaluators do not have to install Erlang/OTP
# themselves. `escript` (part of Erlang/OTP) runs the packaged CLI.
# OTP must match the version used by the gleam-lang/gleam builder
# image above (OTP 29 for Gleam v1.18.1) — otherwise the escript's
# compiled BEAM modules fail to load at runtime.
FROM erlang:29-alpine@sha256:e7a27e743d17abf139518a69ba3861b43a88ad8396296f0a859d7f37031dbde0 AS runtime

LABEL org.opencontainers.image.source="https://github.com/nao1215/sqlode"
LABEL org.opencontainers.image.description="sqlode — typed Gleam code generator for SQL schemas and queries."
LABEL org.opencontainers.image.licenses="MIT"

COPY --from=builder /build/sqlode /usr/local/bin/sqlode
RUN chmod +x /usr/local/bin/sqlode

# `/work` is the conventional bind-mount target — users run
# `docker run --rm -v "$PWD:/work" ghcr.io/nao1215/sqlode:latest generate`.
WORKDIR /work

ENTRYPOINT ["escript", "/usr/local/bin/sqlode"]
CMD ["--help"]
