# memory-service (Python) — two-stage build with virtualenv.
#
# Python image size sits between Go and Java: no static single binary like Go,
# but also avoids bundling an entire JVM like Java.
#
# Difference compared to Node services: requirements.txt STRICTLY pins every version,
# ensuring deterministic builds.
FROM python:3.12-slim AS builder
WORKDIR /app

# Build a separate virtualenv and copy the entire folder to the runtime stage.
# Cleaner than `--user` or PYTHONPATH because only a single directory is copied.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ------------------------------------------------------------------------------
FROM python:3.12-slim AS runner
WORKDIR /app

# uid 1000 to match securityContext in the manifest. The python:slim image has no default
# non-root user (unlike node:alpine which includes `node` uid 1000) — created explicitly.
RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin appuser

COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
COPY --chown=appuser:appuser main.py ./

ENV PATH="/opt/venv/bin:$PATH"
# Do not buffer stdout: without this line, logs are buffered and `kubectl logs` looks
# like the service is hanging while it runs normally.
ENV PYTHONUNBUFFERED=1
ENV PORT=4002

# No OTEL_* variables here. All config lives in the "devops-apps" Instrumentation CR
# (gitops/workloads/_shared/instrumentation.yaml) injected by the Operator at pod creation —
# changing the Collector endpoint does not require rebuilding images.
USER appuser
EXPOSE 4002
CMD ["python", "main.py"]
