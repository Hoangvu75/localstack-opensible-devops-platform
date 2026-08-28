# disk-service (Java) — built with Maven, runs on JRE.
#
# SIZE COMPARISON IN THIS PROJECT
#
#   Go     : static binary on distroless         → smallest, a few tens of MB
#   Node   : runtime + node_modules              → medium
#   Python : venv + interpreter                  → medium
#   Java   : fat jar + JRE                       → largest
#
# That is the real cost of running on the JVM, and the reason placing four languages side-by-side
# in one repo is valuable: differences become measurable facts rather than debates.
FROM maven:3.9-eclipse-temurin-21 AS builder
WORKDIR /build

# Download dependencies in a separate layer: code changes do not re-download the entire Maven repo,
# which is typically the slowest part of Java builds.
COPY pom.xml ./
RUN mvn -B -q dependency:go-offline

COPY src ./src
RUN mvn -B -q package -DskipTests

# ------------------------------------------------------------------------------
FROM eclipse-temurin:21-jre-alpine AS runner
WORKDIR /app

# uid 1000 to match securityContext in the manifest. The Temurin image has no pre-existing non-root user.
RUN addgroup -g 1000 app && adduser -D -u 1000 -G app app

COPY --from=builder --chown=app:app /build/target/disk-service.jar ./disk-service.jar

ENV PORT=4003

# NO OTEL_* environment variables in this image. They are now defined in the Instrumentation
# CR "devops-apps" (gitops/workloads/_shared/instrumentation.yaml) — centralized for all four
# languages rather than scattered across Dockerfiles requiring image rebuilds on change.

# Limit heap based on container memory percentage. Without this flag, older JVMs misread host
# NODE RAM instead of cgroup limits and allocate an oversized heap — leading to unexplained OOMKills.
# JVM 21 detects cgroups automatically, but explicit configuration remains clearer in manifests.
# No -javaagent here. The Operator injects it via JAVA_TOOL_OPTIONS at pod creation, and the JVM merges
# it with JAVA_OPTS below — avoiding conflicts.
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75 -XX:+UseSerialGC"

USER app
EXPOSE 4003
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/disk-service.jar"]
