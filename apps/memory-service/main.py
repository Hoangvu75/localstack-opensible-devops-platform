"""
memory-service — real node memory figures, in Python.

One of four languages sharing no code — only a JSON payload shape and W3C Trace Context,
which the agent injects and reads by itself. See README §9.5.

Never invents numbers: readable values are real, unreadable ones are None with a reason.

  capacity        node.status.capacity (core API)
  metrics.k8s.io  actual usage (metrics-server)
"""
import asyncio
import json
import os
import re
import signal
from datetime import datetime, timezone
from typing import Any, Optional

from aiohttp import web
from aiokafka import AIOKafkaProducer
from kubernetes import client, config

PORT = int(os.getenv("PORT", "4002"))
KAFKA_BROKERS = os.getenv("KAFKA_BROKERS", "redpanda.redpanda.svc.cluster.local:9092")
TOPIC = os.getenv("METRICS_TOPIC", "node-metrics")
# No OpenTelemetry code in this file: the Operator injects the agent (annotation
# inject-python), which instruments aiohttp, the Kubernetes client and aiokafka, including
# traceparent propagation.
#
# What that costs: the business attributes metrics.available and metrics.node_count are gone.
# An agent cannot know them — that is the real boundary of zero-code instrumentation.
#
#
#
#

# ── Kubernetes ───────────────────────────────────────────────────────────────
# Do NOT let a config error kill the process at startup: CrashLoopBackOff would take /health
#
# with it, along with any way to see why. Degrade instead and report the reason over HTTP.
core_api = None
custom_api = None
K8S_ERROR: Optional[str] = None

try:
    try:
        config.load_incluster_config()
    except config.ConfigException:
        config.load_kube_config()
    core_api = client.CoreV1Api()
    custom_api = client.CustomObjectsApi()
except Exception as err:  # noqa: BLE001
    K8S_ERROR = f"could not load the Kubernetes config: {err}"
    print(f"[memory-service] {K8S_ERROR}", flush=True)

# Kubernetes memory uses BINARY suffixes (Ki/Mi/Gi = 1024), not decimal. Mixing the two is
# off by ~7% at Gi — enough to make a 90% alert fire wrongly, or stay silent wrongly.
MEMORY_UNITS = {
    "Ki": 1024, "Mi": 1024**2, "Gi": 1024**3, "Ti": 1024**4,
    "K": 1000, "M": 1000**2, "G": 1000**3, "T": 1000**4,
}
_QUANTITY = re.compile(r"^(\d+(?:\.\d+)?)([A-Za-z]*)$")
GIB = 1024**3


def memory_quantity_to_bytes(q: Optional[str]) -> Optional[float]:
    if not q:
        return None
    m = _QUANTITY.match(q)
    if not m:
        return None
    value, unit = m.groups()
    multiplier = MEMORY_UNITS.get(unit, 1) if unit else 1
    if not multiplier:
        return None
    return float(value) * multiplier


def to_gib(b: Optional[float]) -> Optional[float]:
    return None if b is None else round(b / GIB, 2)


def _collect() -> dict[str, Any]:
    """The Kubernetes API calls — RUNS IN ITS OWN THREAD.

    The Python client is synchronous (urllib3). Calling it straight from a coroutine would
    BLOCK the event loop, and aiohttp would serve nothing else while waiting — easy to write
    and hard to notice under light load.
    """
    if core_api is None:
        raise RuntimeError(K8S_ERROR or "Kubernetes client not ready")

    node_list = core_api.list_node()

    usage_by_node: dict[str, Optional[float]] = {}
    degraded_reason: Optional[str] = None

    # Fetch usage separately and let it fail on its own: a missing metrics-server must not take
    # away the capacity figures, which are still readable.
    try:
        metrics = custom_api.list_cluster_custom_object(
            "metrics.k8s.io", "v1beta1", "nodes"
        )
        for item in metrics.get("items", []):
            name = item.get("metadata", {}).get("name")
            usage_by_node[name] = memory_quantity_to_bytes(
                item.get("usage", {}).get("memory")
            )
    except Exception as err:  # noqa: BLE001 — catch everything to degrade softly
        degraded_reason = (
            "Could not read metrics.k8s.io — the cluster probably has no metrics-server. "
            "Capacity is still correct; usage is left blank."
        )
        print(f"[memory-service] {degraded_reason} ({err})", flush=True)

    nodes = []
    for node in node_list.items:
        name = node.metadata.name or "unknown"
        labels = node.metadata.labels or {}
        is_control_plane = (
            "node-role.kubernetes.io/control-plane" in labels
            or "node-role.kubernetes.io/master" in labels
        )
        conditions = {c.type: c.status for c in (node.status.conditions or [])}

        total_bytes = memory_quantity_to_bytes((node.status.capacity or {}).get("memory"))
        alloc_bytes = memory_quantity_to_bytes((node.status.allocatable or {}).get("memory"))
        used_bytes = usage_by_node.get(name)

        nodes.append({
            "name": name,
            "role": "control-plane" if is_control_plane else "worker",
            "status": "Ready" if conditions.get("Ready") == "True" else "NotReady",
            "totalGiB": to_gib(total_bytes),
            "allocatableGiB": to_gib(alloc_bytes),
            "usedGiB": to_gib(used_bytes),
            "freeGiB": to_gib(total_bytes - used_bytes)
            if used_bytes is not None and total_bytes is not None
            else None,
            "usedPercent": round(used_bytes / total_bytes * 100)
            if used_bytes is not None and total_bytes
            else None,
            # Kubernetes reports this itself when a node is running out — a real signal, not a guess.
            "memoryPressure": conditions.get("MemoryPressure") == "True",
        })

    measured = [n for n in nodes if n["usedPercent"] is not None]
    total_gib = sum(n["totalGiB"] or 0 for n in nodes)
    used_gib = sum(n["usedGiB"] or 0 for n in measured)

    return {
        "service": "memory-service",
        "language": "python",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "metricsAvailable": len(measured) > 0,
        "degradedReason": degraded_reason,
        "summary": {
            "totalNodes": len(nodes),
            "totalGiB": round(total_gib, 2) if total_gib else None,
            "usedGiB": round(used_gib, 2) if measured else None,
            "averageUsagePercent": round(used_gib / total_gib * 100)
            if measured and total_gib
            else None,
        },
        "nodes": nodes,
    }


async def get_memory_metrics() -> dict[str, Any]:
    return await asyncio.to_thread(_collect)


# ── HTTP endpoint ────────────────────────────────────────────────────────────
# No OpenTelemetry code here either. The agent recognises aiokafka, creates the PRODUCER span
# and injects traceparent into the headers, so the queue hop shares the HTTP call's trace.
# ── Producer Kafka ───────────────────────────────────────────────────────────
producer: Optional[AIOKafkaProducer] = None


async def start_producer() -> None:
    global producer
    p = AIOKafkaProducer(bootstrap_servers=KAFKA_BROKERS, client_id="memory-service")
    await p.start()
    producer = p
    print(f"[memory-service] connected to Kafka at {KAFKA_BROKERS}", flush=True)


async def publish(data: dict[str, Any]) -> None:
    """Fire-and-forget on purpose: the caller must not wait on the broker.

    send() returns a future immediately, unlike send_and_wait(). The PRODUCER span is still
    created inside the request context, so it lands in the right place in the tree.
    """
    if producer is None:
        return
    try:
        await producer.send(TOPIC, json.dumps(data).encode(), key=b"memory")
    except Exception as err:  # noqa: BLE001
        print(f"[memory-service] publish failed: {err}", flush=True)


async def metrics(_req: web.Request) -> web.Response:
    try:
        data = await get_memory_metrics()
        await publish(data)
        return web.json_response(data)
    except Exception as err:  # noqa: BLE001
        # Report the failure explicitly: callers must tell "no data" from "nobody answered".
        print(f"[memory-service] /metrics failed: {err}", flush=True)
        return web.json_response(
            {"service": "memory-service", "error": str(err)}, status=503
        )


# ── HTTP ─────────────────────────────────────────────────────────────────────
# HTTP instrumentation is deliberately off here: the only two endpoints are health probes, and
# those are exactly what should stay out of traces — measured at ~99% of all spans. Filtering
# lives in the Collector (filter/health) so it covers every language.
async def health(_req: web.Request) -> web.Response:
    return web.json_response({"status": "UP", "service": "memory-service"})


async def ready(_req: web.Request) -> web.Response:
    # No broker to be "not connected" to. If the process is up, it can serve.
    return web.json_response({"status": "READY", "service": "memory-service"})


async def main() -> None:
    # A broker that is not up must NOT kill the service — publishing is a side effect.
    try:
        await start_producer()
    except Exception as err:  # noqa: BLE001
        print(f"[memory-service] could not connect to Kafka: {err}", flush=True)

    app = web.Application()
    app.router.add_get("/health", health)
    app.router.add_get("/ready", ready)
    app.router.add_get("/api/metrics", metrics)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", PORT)
    await site.start()
    print(f"[memory-service] HTTP :{PORT}", flush=True)

    # Kubernetes sends SIGTERM, then SIGKILL after terminationGracePeriodSeconds. Without this a
    # rolling update cuts in-flight requests AND drops buffered spans — losing the trace of the
    # last request before the failure.
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop.set)
    await stop.wait()

    print("[memory-service] shutting down", flush=True)
    await runner.cleanup()
    if nc.is_connected:
        await nc.drain()



if __name__ == "__main__":
    asyncio.run(main())
