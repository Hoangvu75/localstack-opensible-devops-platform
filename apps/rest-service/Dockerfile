# rest-service (Go) — static build, minimal runtime image.
#
# COMPARISON WITH THE OTHER THREE SERVICES
#
# Key observation when placing four languages side-by-side: the Go image contains
# only a SINGLE static binary. No runtime, no node_modules, no JVM, no interpreter.
# Typically an order of magnitude smaller than Node and two orders smaller than Java.
#
# Trade-off: longer build times (compilation + module download) and no hot-patching.
FROM golang:1.22-alpine AS builder
WORKDIR /src

# Download dependencies in a separate layer for build cache efficiency.
COPY go.mod ./
RUN go mod download || true

COPY *.go ./
RUN go mod tidy

# CGO_ENABLED=0 produces a static binary runnable on scratch/distroless.
# -trimpath and -ldflags="-s -w" remove build paths and symbol tables, reducing binary size.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/rest-service .

# ------------------------------------------------------------------------------
FROM gcr.io/distroless/static-debian12:nonroot

# Distroless nonroot runs as uid 65532, with NO shell and NO package manager.
# Near-zero attack surface — also means `kubectl exec` is not available for debugging.
# An intentional trade-off for a service only serving HTTP.
#
# Note: uid 65532 differs from 1000 in other manifests. The manifest reflects this uid
# to prevent CrashLoopBackOff from mismatched runAsUser settings.
COPY --from=builder /out/rest-service /rest-service

ENV PORT=4000
EXPOSE 4000
ENTRYPOINT ["/rest-service"]
