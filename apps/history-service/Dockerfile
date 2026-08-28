# history-service — Kafka consumer, holds snapshot history in memory.
#
# This service answers a key learning question: "what does a message crossing a queue look
# like on a trace?". It is the OTHER end of the queue hop — three metric services publish,
# this one consumes, and OpenTelemetry links both ends into a single trace tree.
FROM python:3.12-slim AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# ------------------------------------------------------------------------------
FROM python:3.12-slim AS runner
WORKDIR /app

# uid 1000 to match securityContext in the manifest.
RUN useradd --uid 1000 --create-home --shell /usr/sbin/nologin appuser

COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
COPY --chown=appuser:appuser main.py ./

ENV PATH="/opt/venv/bin:$PATH"
# Do not buffer stdout: without this line, logs are buffered and `kubectl logs` looks like
# the service is hanging.
ENV PYTHONUNBUFFERED=1
ENV PORT=4004

# No OTEL_* variables. All configuration is in the "devops-apps" Instrumentation CR.
USER appuser
EXPOSE 4004
CMD ["python", "main.py"]
