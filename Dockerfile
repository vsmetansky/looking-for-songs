# syntax=docker/dockerfile:1

# Build stage: resolve dependencies into a venv with uv.
# Same base image as the runtime stage so the venv's interpreter paths match.
FROM python:3.14-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /bin/uv

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Only the manifests, so this layer stays cached until dependencies change.
# --no-install-project: the project has no build-system, it runs from source.
COPY pyproject.toml uv.lock ./
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-dev --no-install-project


# Runtime stage: just the venv and the source, no uv and no build cache.
FROM python:3.14-slim

RUN useradd --create-home --uid 1000 app
WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app main.py ./
COPY --chown=app:app looking_for_songs ./looking_for_songs

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    HOST=0.0.0.0

USER app

# Cloud Run injects PORT (8080); run() already reads it, and HOST above
# overrides the 127.0.0.1 default that would be unreachable in a container.
EXPOSE 8080

CMD ["python", "main.py"]
