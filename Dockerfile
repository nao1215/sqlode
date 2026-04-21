# syntax=docker/dockerfile:1.7

# ---------- builder ----------
# Produces the self-contained `sqlode` escript. We pin the Gleam
# version to match the erlef/setup-beam toolchain used in CI so the
# artefact is byte-identical with what the release workflow ships.
FROM ghcr.io/gleam-lang/gleam:v1.15.2-erlang-alpine AS builder

WORKDIR /build

# `gleam deps download` reaches rebar3 for Erlang-native dependencies.
RUN apk add --no-cache bash curl \
    && curl -fsSL https://s3.amazonaws.com/rebar3/rebar3 -o /usr/local/bin/rebar3 \
    && chmod +x /usr/local/bin/rebar3

# Resolve deps first so later source edits hit a cache layer.
COPY gleam.toml manifest.toml ./
RUN gleam deps download

# Copy source, build the project, and bundle the escript. An
# explicit `gleam build` pass materialises the sqlode BEAM files in
# `build/dev/erlang/sqlode/ebin` so gleescript can include them in
# the escript archive.
COPY src ./src
RUN gleam build
RUN gleam run -m gleescript

# ---------- runtime ----------
# Minimal Erlang image so evaluators do not have to install Erlang/OTP
# themselves. `escript` (part of Erlang/OTP) runs the packaged CLI.
# OTP must match the version used by the gleam-lang/gleam builder
# image above (OTP 28 for Gleam v1.15.2) — otherwise the escript's
# compiled BEAM modules fail to load at runtime.
FROM erlang:28-alpine AS runtime

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
