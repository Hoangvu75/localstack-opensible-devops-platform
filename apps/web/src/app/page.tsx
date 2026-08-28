'use client';

/**
 * Kubernetes node metrics dashboard.
 *
 * Rule this file enforces: missing data renders as "—", never as a guessed number.
 * Every metric is nullable and a degraded state shows as a banner. See README §9.13.
 */

import { useState, useEffect, useCallback } from 'react';

type Nullable<T> = T | null;

interface NodeMetric {
  name: string;
  role: 'control-plane' | 'worker';
  status: string;
  cpu: {
    capacityMillicores: Nullable<number>;
    usedMillicores: Nullable<number>;
    usedPercent: Nullable<number>;
  };
  memory: {
    totalGiB: Nullable<number>;
    usedGiB: Nullable<number>;
    freeGiB: Nullable<number>;
    usedPercent: Nullable<number>;
    memoryPressure: Nullable<boolean>;
  };
  disk: {
    capacityGiB: Nullable<number>;
    imagesGiB: Nullable<number>;
    diskPressure: Nullable<boolean>;
    usedPercent: Nullable<number>;
  };
}

interface ClusterSummary {
  totalNodes: Nullable<number>;
  totalMillicores: Nullable<number>;
  avgCpuPercent: Nullable<number>;
  totalMemoryGiB: Nullable<number>;
  usedMemoryGiB: Nullable<number>;
  avgMemoryPercent: Nullable<number>;
  totalDiskGiB: Nullable<number>;
  avgDiskPercent: Nullable<number>;
}

interface SourceState {
  status: string;
  error: Nullable<string>;
  degradedReason: Nullable<string>;
}

const EMPTY_SUMMARY: ClusterSummary = {
  totalNodes: null,
  totalMillicores: null,
  avgCpuPercent: null,
  totalMemoryGiB: null,
  usedMemoryGiB: null,
  avgMemoryPercent: null,
  totalDiskGiB: null,
  avgDiskPercent: null,
};

/** null renders as "—", never as 0 and never as a guess. */
const fmt = (v: Nullable<number>, suffix = ''): string => (v === null || v === undefined ? '—' : `${v}${suffix}`);

const colorFor = (percent: Nullable<number>): string => {
  if (percent === null) return 'rgba(255,255,255,0.25)';
  if (percent < 50) return '#00f5ff';
  if (percent < 75) return '#ffe66d';
  return '#ff3cac';
};

const CARD: React.CSSProperties = {
  background: 'rgba(255, 255, 255, 0.04)',
  backdropFilter: 'blur(16px)',
  borderRadius: '18px',
  padding: '20px',
  border: '1px solid rgba(255, 255, 255, 0.08)',
};

export default function Home() {
  const [nodes, setNodes] = useState<NodeMetric[]>([]);
  const [summary, setSummary] = useState<ClusterSummary>(EMPTY_SUMMARY);
  const [sources, setSources] = useState<Record<string, SourceState>>({});
  const [degraded, setDegraded] = useState(false);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const [autoRefresh, setAutoRefresh] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<string>('');

  const fetchMetrics = useCallback(async () => {
    try {
      const res = await fetch('/api/k8s-metrics', { cache: 'no-store' });
      const data = await res.json();

      // 503 still carries a JSON body with `sources`, naming the link that broke.
      // Read it instead of discarding it.
      setSources(data.sources ?? {});
      setDegraded(Boolean(data.degraded) || !res.ok);
      setNodes(Array.isArray(data.nodes) ? data.nodes : []);
      setSummary(data.summary ?? EMPTY_SUMMARY);
      setFetchError(res.ok ? null : data.error ?? `HTTP ${res.status}`);
      setLastUpdated(new Date().toLocaleTimeString());
    } catch (err) {
      // Clear stale data on failure. Keeping the previous fetch would leave the screen
      // looking alive while the backend is down.
      setNodes([]);
      setSummary(EMPTY_SUMMARY);
      setSources({});
      setDegraded(true);
      setFetchError(String(err));
      setLastUpdated(new Date().toLocaleTimeString());
    }
  }, []);

  useEffect(() => {
    fetchMetrics();
    if (!autoRefresh) return;
    const interval = setInterval(fetchMetrics, 3000);
    return () => clearInterval(interval);
  }, [fetchMetrics, autoRefresh]);

  const masterNodes = nodes.filter((n) => n.role === 'control-plane');
  const workerNodes = nodes.filter((n) => n.role === 'worker');

  const problems = Object.entries(sources)
    .filter(([, s]) => s.status !== 'OK' || s.degradedReason)
    .map(([name, s]) => `${name}: ${s.error ?? s.degradedReason ?? s.status}`);

  return (
    <>
      <div className="aurora" />
      <div className="grid" />
      <div className="noise" />
      <div className="orb one" />
      <div className="orb two" />

      <main style={{ maxWidth: '1200px', margin: '0 auto', padding: '30px 20px', width: '100%' }}>
        <header style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '25px', flexWrap: 'wrap', gap: '15px' }}>
          <div>
            <div style={{ display: 'flex', alignItems: 'center', gap: '10px', marginBottom: '6px' }}>
              <span style={{ height: '10px', width: '10px', backgroundColor: degraded ? '#ff3cac' : '#00f5ff', borderRadius: '50%', display: 'inline-block', boxShadow: `0 0 10px ${degraded ? '#ff3cac' : '#00f5ff'}` }} />
              <span style={{ fontSize: '13px', fontWeight: 600, letterSpacing: '0.08em', textTransform: 'uppercase', color: degraded ? '#ff3cac' : '#00f5ff' }}>
                Polyglot Microservices · GitOps · OpenTelemetry
              </span>
            </div>
            <h1 style={{ fontSize: '28px', fontWeight: 800, background: 'linear-gradient(135deg, #fff 40%, #00f5ff 100%)', WebkitBackgroundClip: 'text', WebkitTextFillColor: 'transparent' }}>
              Kubernetes Node Metrics Monitor
            </h1>
          </div>

          <div style={{ display: 'flex', gap: '12px', alignItems: 'center', background: 'rgba(255, 255, 255, 0.05)', padding: '10px 18px', borderRadius: '30px', backdropFilter: 'blur(10px)', border: '1px solid rgba(255, 255, 255, 0.1)' }}>
            {(['cpu', 'memory', 'disk'] as const).map((key) => {
              const s = sources[key];
              const ok = s?.status === 'OK';
              return (
                <div key={key} style={{ display: 'flex', alignItems: 'center', gap: '5px', fontSize: '12px', color: ok ? '#00f5ff' : '#ff3cac', fontWeight: 600 }}>
                  <span>{ok ? '●' : '○'}</span> {key.toUpperCase()}
                  <span style={{ color: 'rgba(255,255,255,0.4)', fontWeight: 400 }}>{s?.status ?? '—'}</span>
                </div>
              );
            })}
          </div>
        </header>

        {/* Degraded banner: incomplete data has to be visible, not inferred from a chart
            that still looks smooth. */}
        {(degraded || problems.length > 0) && (
          <div style={{ background: 'rgba(255, 60, 172, 0.12)', border: '1px solid rgba(255, 60, 172, 0.45)', borderRadius: '14px', padding: '14px 18px', marginBottom: '20px' }}>
            <div style={{ fontSize: '13px', fontWeight: 700, color: '#ff3cac', marginBottom: problems.length ? '8px' : 0 }}>
              ⚠ Incomplete data — cells showing “—” could not be read; they are not zeros
            </div>
            {fetchError && (
              <div style={{ fontSize: '12px', color: 'rgba(255,255,255,0.75)', marginBottom: '4px' }}>{fetchError}</div>
            )}
            {problems.map((p) => (
              <div key={p} style={{ fontSize: '12px', color: 'rgba(255,255,255,0.75)', lineHeight: 1.6 }}>• {p}</div>
            ))}
          </div>
        )}

        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '25px', background: 'rgba(20, 25, 45, 0.7)', padding: '12px 20px', borderRadius: '16px', border: '1px solid rgba(255, 255, 255, 0.08)' }}>
          <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.7)' }}>
            Source: <strong style={{ color: '#00f5ff' }}>metrics.k8s.io</strong> • Updated: <strong style={{ color: '#fff' }}>{lastUpdated || 'loading…'}</strong>
          </div>
          <div style={{ display: 'flex', gap: '12px', alignItems: 'center' }}>
            <button
              onClick={() => setAutoRefresh(!autoRefresh)}
              style={{ background: autoRefresh ? 'rgba(0, 245, 255, 0.15)' : 'rgba(255, 255, 255, 0.08)', color: autoRefresh ? '#00f5ff' : '#fff', border: `1px solid ${autoRefresh ? '#00f5ff' : 'rgba(255,255,255,0.2)'}`, padding: '6px 14px', borderRadius: '8px', fontSize: '12px', cursor: 'pointer', fontWeight: 600 }}
            >
              {autoRefresh ? '⚡ Auto-refresh: ON (3s)' : '⏸️ Paused'}
            </button>
            <button
              onClick={fetchMetrics}
              style={{ background: 'linear-gradient(135deg, #784ba0, #2b86c5)', color: '#fff', border: 'none', padding: '6px 16px', borderRadius: '8px', fontSize: '12px', cursor: 'pointer', fontWeight: 600 }}
            >
              🔄 Refresh
            </button>
          </div>
        </div>

        {/* Cluster summary */}
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(260px, 1fr))', gap: '18px', marginBottom: '30px' }}>
          <div style={CARD}>
            <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.6)', marginBottom: '8px', display: 'flex', justifyContent: 'space-between' }}>
              <span>Nodes</span><span>☸️ K8s Cluster</span>
            </div>
            <div style={{ fontSize: '32px', fontWeight: 800, color: '#fff' }}>{fmt(summary.totalNodes)}</div>
            <div style={{ fontSize: '12px', color: '#00f5ff', marginTop: '6px' }}>
              {masterNodes.length} control-plane • {workerNodes.length} worker
            </div>
          </div>

          <SummaryCard
            label="CPU"
            corner={summary.avgCpuPercent === null ? 'no data yet' : `${summary.avgCpuPercent}% average`}
            value={summary.totalMillicores === null ? '—' : `${(summary.totalMillicores / 1000).toFixed(0)}`}
            unit="cores"
            percent={summary.avgCpuPercent}
          />

          <SummaryCard
            label="RAM"
            corner={`${fmt(summary.usedMemoryGiB)} / ${fmt(summary.totalMemoryGiB)} GiB`}
            value={fmt(summary.avgMemoryPercent, '%')}
            unit="used"
            percent={summary.avgMemoryPercent}
          />

          {/* Disk deliberately has no percentage bar: metrics-server does not report used
              capacity, and this dashboard does not invent it. */}
          <div style={CARD}>
            <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.6)', marginBottom: '8px', display: 'flex', justifyContent: 'space-between' }}>
              <span>Ephemeral storage</span><span style={{ color: 'rgba(255,255,255,0.4)' }}>capacity</span>
            </div>
            <div style={{ fontSize: '32px', fontWeight: 800, color: '#fff' }}>
              {fmt(summary.totalDiskGiB)} <span style={{ fontSize: '16px', fontWeight: 400 }}>GiB</span>
            </div>
            <div style={{ fontSize: '11px', color: 'rgba(255,255,255,0.45)', marginTop: '8px', lineHeight: 1.5 }}>
              “Used” requires node-exporter — metrics-server does not report it
            </div>
          </div>
        </div>

        <h2 style={{ fontSize: '18px', fontWeight: 700, marginBottom: '14px', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>👑</span> Control-plane ({masterNodes.length})
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(350px, 1fr))', gap: '20px', marginBottom: '35px' }}>
          {masterNodes.length === 0 && <EmptyState />}
          {masterNodes.map((node) => <NodeCard key={node.name} node={node} isMaster />)}
        </div>

        <h2 style={{ fontSize: '18px', fontWeight: 700, marginBottom: '14px', display: 'flex', alignItems: 'center', gap: '8px' }}>
          <span>👷</span> Worker ({workerNodes.length})
        </h2>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(350px, 1fr))', gap: '20px', marginBottom: '40px' }}>
          {workerNodes.length === 0 && <EmptyState />}
          {workerNodes.map((node) => <NodeCard key={node.name} node={node} />)}
        </div>

        <footer style={{ borderTop: '1px solid rgba(255,255,255,0.1)', paddingTop: '20px', display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: '12px', color: 'rgba(255,255,255,0.5)', flexWrap: 'wrap', gap: '10px' }}>
          <div>HTTP FAN-OUT • REDPANDA • REST GATEWAY :4000 • metrics.k8s.io</div>
          <div>OPENSIBLE GITOPS • EKS MONITORING LAB</div>
        </footer>
      </main>
    </>
  );
}

function EmptyState() {
  return (
    <div style={{ ...CARD, textAlign: 'center', color: 'rgba(255,255,255,0.45)', fontSize: '13px', padding: '30px' }}>
      No node data. Check rest-service and the Kubernetes API.
    </div>
  );
}

function SummaryCard({ label, corner, value, unit, percent }: { label: string; corner: string; value: string; unit: string; percent: Nullable<number> }) {
  return (
    <div style={CARD}>
      <div style={{ fontSize: '13px', color: 'rgba(255,255,255,0.6)', marginBottom: '8px', display: 'flex', justifyContent: 'space-between' }}>
        <span>{label}</span>
        <span style={{ color: colorFor(percent), fontWeight: 700 }}>{corner}</span>
      </div>
      <div style={{ fontSize: '32px', fontWeight: 800, color: '#fff' }}>
        {value} <span style={{ fontSize: '16px', fontWeight: 400 }}>{unit}</span>
      </div>
      <Bar percent={percent} />
    </div>
  );
}

/**
 * Progress bar. A null percentage renders as hatching rather than a 0% bar: 0% reads as
 * "idle", hatching reads as "unknown", and those are different claims.
 */
function Bar({ percent, gradientFrom = '#2b86c5' }: { percent: Nullable<number>; gradientFrom?: string }) {
  if (percent === null) {
    return (
      <div
        title="no data"
        style={{
          width: '100%',
          height: '6px',
          borderRadius: '3px',
          marginTop: '10px',
          background: 'repeating-linear-gradient(45deg, rgba(255,255,255,0.10) 0 4px, transparent 4px 8px)',
        }}
      />
    );
  }
  return (
    <div style={{ width: '100%', height: '6px', background: 'rgba(255,255,255,0.1)', borderRadius: '3px', marginTop: '10px', overflow: 'hidden' }}>
      <div style={{ width: `${percent}%`, height: '100%', background: `linear-gradient(90deg, ${gradientFrom}, ${colorFor(percent)})`, transition: 'width 0.5s ease' }} />
    </div>
  );
}

function NodeCard({ node, isMaster }: { node: NodeMetric; isMaster?: boolean }) {
  const cores = node.cpu.capacityMillicores === null ? '—' : (node.cpu.capacityMillicores / 1000).toFixed(0);

  return (
    <div
      style={{
        background: isMaster ? 'linear-gradient(145deg, rgba(120, 75, 160, 0.15), rgba(20, 25, 45, 0.8))' : 'rgba(20, 25, 45, 0.75)',
        backdropFilter: 'blur(20px)',
        borderRadius: '20px',
        padding: '24px',
        border: `1px solid ${isMaster ? 'rgba(120, 75, 160, 0.4)' : 'rgba(255, 255, 255, 0.08)'}`,
        boxShadow: isMaster ? '0 8px 32px rgba(120, 75, 160, 0.2)' : '0 8px 24px rgba(0, 0, 0, 0.3)',
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: '18px', gap: '10px' }}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontSize: '14px', fontWeight: 700, color: '#fff', wordBreak: 'break-all' }}>{node.name}</div>
          <div style={{ fontSize: '12px', color: isMaster ? '#ff3cac' : '#00f5ff', fontWeight: 600, marginTop: '2px' }}>
            {isMaster ? 'CONTROL-PLANE' : 'WORKER'}
          </div>
        </div>
        <span
          style={{
            background: node.status === 'Ready' ? 'rgba(0, 245, 255, 0.15)' : 'rgba(255, 60, 172, 0.15)',
            color: node.status === 'Ready' ? '#00f5ff' : '#ff3cac',
            padding: '4px 10px',
            borderRadius: '20px',
            fontSize: '11px',
            fontWeight: 700,
            whiteSpace: 'nowrap',
            border: `1px solid ${node.status === 'Ready' ? 'rgba(0, 245, 255, 0.3)' : 'rgba(255, 60, 172, 0.3)'}`,
          }}
        >
          ● {node.status}
        </span>
      </div>

      {/* CPU */}
      <div style={{ marginBottom: '16px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '13px', marginBottom: '6px' }}>
          <span style={{ color: 'rgba(255,255,255,0.7)' }}>⚡ CPU ({cores} cores)</span>
          <span style={{ fontWeight: 700, color: colorFor(node.cpu.usedPercent) }}>
            {fmt(node.cpu.usedPercent, '%')}
            <span style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}> ({fmt(node.cpu.usedMillicores, 'm')})</span>
          </span>
        </div>
        <Bar percent={node.cpu.usedPercent} />
      </div>

      {/* RAM */}
      <div style={{ marginBottom: '16px' }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '13px', marginBottom: '6px' }}>
          <span style={{ color: 'rgba(255,255,255,0.7)' }}>
            🧠 RAM ({fmt(node.memory.totalGiB)} GiB)
            {node.memory.memoryPressure && <span style={{ color: '#ff3cac', fontWeight: 700 }}> ⚠ pressure</span>}
          </span>
          <span style={{ fontWeight: 700, color: colorFor(node.memory.usedPercent) }}>
            {fmt(node.memory.usedPercent, '%')}
            <span style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}> ({fmt(node.memory.usedGiB)} GiB)</span>
          </span>
        </div>
        <Bar percent={node.memory.usedPercent} gradientFrom="#784ba0" />
      </div>

      {/* Disk: only the figures actually read, no invented percentage */}
      <div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '13px', marginBottom: '6px' }}>
          <span style={{ color: 'rgba(255,255,255,0.7)' }}>
            💾 Disk ({fmt(node.disk.capacityGiB)} GiB)
            {node.disk.diskPressure && <span style={{ color: '#ff3cac', fontWeight: 700 }}> ⚠ pressure</span>}
          </span>
          <span style={{ fontSize: '11px', color: 'rgba(255,255,255,0.5)' }}>
            image cache: {fmt(node.disk.imagesGiB)} GiB
          </span>
        </div>
        <Bar percent={node.disk.usedPercent} />
      </div>
    </div>
  );
}
