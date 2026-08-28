/**
 * cpu-service — real node CPU figures.
 *
 * Never invents numbers: readable values are real, unreadable ones are `null` with a reason.
 *
 * Two sources, two different APIs:
 *
 *   core API        capacity and allocatable
 *   metrics.k8s.io  actual usage, served by metrics-server
 *
 * metrics-server is a separate component and is not present in every cluster. Without it
 * capacity still reads but usage does not — and that state is reported, not hidden.
 */
// No SDK bootstrap here. The OpenTelemetry Operator injects the agent through NODE_OPTIONS
// at pod creation, so the SDK is already running before this file loads — which also removes
// the classic "import telemetry in the wrong order and lose every span" trap.
//

import express, { Request, Response } from 'express';
import * as k8s from '@kubernetes/client-node';
import { Kafka, Producer } from 'kafkajs';

const PORT = Number(process.env.PORT) || 4001;
const KAFKA_BROKERS = (process.env.KAFKA_BROKERS || 'redpanda.redpanda.svc.cluster.local:9092').split(',');
const TOPIC = process.env.METRICS_TOPIC || 'node-metrics';

const app = express();

const kc = new k8s.KubeConfig();
kc.loadFromDefault();
const coreApi = kc.makeApiClient(k8s.CoreV1Api);
const metricsApi = new k8s.Metrics(kc);

/**
 * Kubernetes expresses CPU as a "quantity": "12" = 12 cores, "250m" = 250 millicores,
 * "32000000n" = 32 million nanocores. metrics-server usually returns n while capacity returns
 * whole cores. Without one common unit the usage/capacity division is off by thousands.
 */
function cpuQuantityToMillicores(q: string | undefined): number | null {
  if (!q) return null;
  if (q.endsWith('n')) return parseInt(q.slice(0, -1), 10) / 1_000_000;
  if (q.endsWith('u')) return parseInt(q.slice(0, -1), 10) / 1_000;
  if (q.endsWith('m')) return parseInt(q.slice(0, -1), 10);
  const cores = parseFloat(q);
  return Number.isNaN(cores) ? null : cores * 1000;
}

interface NodeCpuMetric {
  name: string;
  role: 'control-plane' | 'worker';
  status: string;
  capacityMillicores: number | null;
  allocatableMillicores: number | null;
  usedMillicores: number | null;
  usedPercent: number | null;
  arch: string;
}

interface CpuPayload {
  service: 'cpu-service';
  timestamp: string;
  metricsAvailable: boolean;
  /** Why usage is missing — null when everything is fine. The frontend renders this string. */
  degradedReason: string | null;
  summary: {
    totalNodes: number;
    totalMillicores: number | null;
    averageUsagePercent: number | null;
  };
  nodes: NodeCpuMetric[];
}

async function getCpuMetrics(): Promise<CpuPayload> {
  const nodeList = await coreApi.listNode();

  // Fetch usage separately and let it fail on its own: a missing metrics-server must not take
  // away the capacity figures, which are still readable.
  let usageByNode = new Map<string, number | null>();
  let degradedReason: string | null = null;

  try {
    const nodeMetrics = await metricsApi.getNodeMetrics();
    for (const item of nodeMetrics.items) {
      usageByNode.set(item.metadata.name, cpuQuantityToMillicores(item.usage.cpu));
    }
  } catch (err) {
    degradedReason =
      'Could not read metrics.k8s.io — the cluster probably has no metrics-server. ' +
      'Capacity is still correct; usage is left blank.';
    console.warn(`[cpu-service] ${degradedReason}`, err);
  }

  const nodes: NodeCpuMetric[] = nodeList.body.items.map((node) => {
    const name = node.metadata?.name ?? 'unknown';
    const labels = node.metadata?.labels ?? {};
    const isControlPlane =
      'node-role.kubernetes.io/control-plane' in labels || 'node-role.kubernetes.io/master' in labels;

    const capacityMillicores = cpuQuantityToMillicores(node.status?.capacity?.cpu);
    const allocatableMillicores = cpuQuantityToMillicores(node.status?.allocatable?.cpu);
    const usedMillicores = usageByNode.get(name) ?? null;

    const usedPercent =
      usedMillicores !== null && capacityMillicores
        ? Math.round((usedMillicores / capacityMillicores) * 100)
        : null;

    return {
      name,
      role: isControlPlane ? 'control-plane' : 'worker',
      status: node.status?.conditions?.find((c) => c.type === 'Ready')?.status === 'True' ? 'Ready' : 'NotReady',
      capacityMillicores,
      allocatableMillicores,
      usedMillicores: usedMillicores === null ? null : Math.round(usedMillicores),
      usedPercent,
      arch: node.status?.nodeInfo?.architecture ?? 'unknown',
    };
  });

  const measured = nodes.filter((n) => n.usedPercent !== null);
  const totalMillicores = nodes.reduce((sum, n) => sum + (n.capacityMillicores ?? 0), 0);

  return {
    service: 'cpu-service',
    timestamp: new Date().toISOString(),
    metricsAvailable: measured.length > 0,
    degradedReason,
    summary: {
      totalNodes: nodes.length,
      totalMillicores: totalMillicores || null,
      averageUsagePercent: measured.length
        ? Math.round(measured.reduce((s, n) => s + (n.usedPercent ?? 0), 0) / measured.length)
        : null,
    },
    nodes,
  };
}

// No OpenTelemetry code in this file: the injected agent instruments http, express, the
// Kubernetes client and kafkajs, including traceparent propagation.
//
// What that costs: the business attributes metrics.available and metrics.node_count are gone.
// An agent cannot know them — that is the real boundary of zero-code instrumentation.
//
//
//
//

// ── HTTP ─────────────────────────────────────────────────────────────────────
app.get('/health', (_req: Request, res: Response) => {
  // liveness: the process being alive is enough.
  res.json({ status: 'UP', service: 'cpu-service' });
});

app.get('/ready', (_req: Request, res: Response) => {
  // No broker to be "not connected" to. If the process is up, it can serve.
  res.json({ status: 'READY', service: 'cpu-service' });
});

// No OpenTelemetry code here: the agent recognises kafkajs, creates the PRODUCER span and
// injects traceparent into the message headers, so the queue hop shares the trace of the
// HTTP call being served.
// ── Kafka producer ───────────────────────────────────────────────────────────
let producer: Producer | null = null;

async function startProducer(): Promise<void> {
  const kafka = new Kafka({ clientId: 'cpu-service', brokers: KAFKA_BROKERS });
  const p = kafka.producer();
  await p.connect();
  producer = p;
  console.log(`[cpu-service] connected to Kafka at ${KAFKA_BROKERS.join(',')}`);
}

// A broker that is not up must NOT kill the service: /api/metrics still has to answer.
// Publishing is a side effect, not part of the response.
startProducer().catch((err) => console.error('[cpu-service] could not connect to Kafka:', err));

// Fire-and-forget on purpose: the caller must not wait on the broker. The PRODUCER span is
// still created inside the request context, so it lands in the right place.
function publish(data: unknown): void {
  if (!producer) return;
  producer
    .send({ topic: TOPIC, messages: [{ key: 'cpu', value: JSON.stringify(data) }] })
    .catch((err) => console.error('[cpu-service] publish failed:', err));
}

app.get('/api/metrics', async (_req: Request, res: Response) => {
  try {
    const data = await getCpuMetrics();
    publish(data);
    res.json(data);
  } catch (err) {
    // Report the failure explicitly: callers must tell "no data" from "nobody answered".
    console.error('[cpu-service] /metrics failed:', err);
    res.status(503).json({ service: 'cpu-service', error: String(err) });
  }
});

const server = app.listen(PORT, () => console.log(`[cpu-service] HTTP :${PORT}`));

// Kubernetes sends SIGTERM, then SIGKILL after terminationGracePeriodSeconds. Without this a
// rolling update cuts in-flight requests.
async function shutdown(signal: string): Promise<void> {
  console.log(`[cpu-service] received ${signal}, shutting down`);
  server.close();
  process.exit(0);
}
process.on('SIGTERM', () => void shutdown('SIGTERM'));
process.on('SIGINT', () => void shutdown('SIGINT'));
