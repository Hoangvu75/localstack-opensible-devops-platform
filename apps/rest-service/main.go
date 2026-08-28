// rest-service — the single HTTP gateway, fanning out to three services over HTTP.
//
// Written in Go while the other three use different languages: this is the test of
// OpenTelemetry's language-neutrality claim. Four services, four languages, one trace tree,
// held together only by W3C Trace Context — a text header no SDK has to agree on beyond its
// format. See README §9.5.
//
// Never invents numbers: a service that does not answer becomes `null` plus a reason, and
// `degraded: true`.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

const requestTimeout = 2500 * time.Millisecond

// Three sources. Addresses come from the environment so the manifest decides, not the code.
var sources = []struct{ name, envKey, fallback string }{
	{"cpu", "CPU_SERVICE_URL", "http://cpu-service-svc.devops-apps.svc.cluster.local:4001/api/metrics"},
	{"memory", "MEMORY_SERVICE_URL", "http://memory-service-svc.devops-apps.svc.cluster.local:4002/api/metrics"},
	{"disk", "DISK_SERVICE_URL", "http://disk-service-svc.devops-apps.svc.cluster.local:4003/api/metrics"},
}

// The entire "propagate the trace over the network" story, in one line.
//
// otelhttp.NewTransport creates the CLIENT span and injects traceparent into every outgoing
// request. The three services on the other end read it via their injected agents, so nobody
// writes an adapter. The earlier NATS version needed a carrier type plus a hand-rolled
// PRODUCER span — about 20 lines that HTTP makes disappear. See README §9.3.
//
//
var httpClient = &http.Client{
	Timeout:   requestTimeout,
	Transport: otelhttp.NewTransport(http.DefaultTransport),
}

type sourceResult struct {
	Data   map[string]any `json:"-"`
	Status string         `json:"status"`
	Error  *string        `json:"error"`
}

// askService queries one source and NEVER returns an error to the caller.
//
// Each source fails independently: a broken disk call must not lose a working CPU answer.
// That is why this returns sourceResult rather than (data, error).
func askService(ctx context.Context, name, url string) sourceResult {
	errStr := func(s string) *string { return &s }

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return sourceResult{Status: "BAD_REQUEST", Error: errStr(err.Error())}
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		return sourceResult{
			Status: "NO_RESPONSE",
			Error:  errStr(name + "-service did not answer within " + requestTimeout.String()),
		}
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return sourceResult{
			Status: "HTTP_" + strconv.Itoa(resp.StatusCode),
			Error:  errStr(name + "-service returned " + resp.Status),
		}
	}

	var data map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		// Never swallow silently: callers must tell "no data" from "bad data".
		log.Printf("[rest-service] invalid payload from %s: %v", name, err)
		return sourceResult{Status: "BAD_PAYLOAD", Error: errStr(err.Error())}
	}

	return sourceResult{Data: data, Status: "OK"}
}

func num(m map[string]any, key string) any {
	if m == nil {
		return nil
	}
	// `nil`, not a zero value: missing data stays empty rather than guessed.
	if v, ok := m[key]; ok {
		return v
	}
	return nil
}

func handleMetrics(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()

	// Three calls in parallel. Each fails on its own.
	results := make([]sourceResult, len(sources))
	var wg sync.WaitGroup
	for i, src := range sources {
		wg.Add(1)
		go func(i int, name, url string) {
			defer wg.Done()
			results[i] = askService(ctx, name, url)
		}(i, src.name, envOr(src.envKey, src.fallback))
	}
	wg.Wait()

	cpu, memory, disk := results[0], results[1], results[2]

	sources := map[string]any{
		"cpu":    map[string]any{"status": cpu.Status, "error": cpu.Error, "degradedReason": num(cpu.Data, "degradedReason")},
		"memory": map[string]any{"status": memory.Status, "error": memory.Error, "degradedReason": num(memory.Data, "degradedReason")},
		"disk":   map[string]any{"status": disk.Status, "error": disk.Error, "degradedReason": num(disk.Data, "degradedReason")},
	}

	cpuNodes, _ := num(cpu.Data, "nodes").([]any)

	// cpu-service is the source of node identity. Without it there is no table to build, and
	// saying so beats building one from invented numbers.
	if len(cpuNodes) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{
			"gateway":   "rest-service",
			"timestamp": time.Now().UTC().Format(time.RFC3339),
			"degraded":  true,
			"error":     "Could not get the node list from cpu-service",
			"sources":   sources,
			"nodes":     []any{},
		})
		return
	}

	index := func(res sourceResult) map[string]map[string]any {
		out := map[string]map[string]any{}
		list, _ := num(res.Data, "nodes").([]any)
		for _, item := range list {
			if n, ok := item.(map[string]any); ok {
				if name, ok := n["name"].(string); ok {
					out[name] = n
				}
			}
		}
		return out
	}
	memByName, diskByName := index(memory), index(disk)

	nodes := make([]map[string]any, 0, len(cpuNodes))
	for _, item := range cpuNodes {
		c, ok := item.(map[string]any)
		if !ok {
			continue
		}
		name, _ := c["name"].(string)
		m, d := memByName[name], diskByName[name]

		nodes = append(nodes, map[string]any{
			"name":   name,
			"role":   c["role"],
			"status": c["status"],
			"cpu": map[string]any{
				"capacityMillicores": num(c, "capacityMillicores"),
				"usedMillicores":     num(c, "usedMillicores"),
				"usedPercent":        num(c, "usedPercent"),
			},
			"memory": map[string]any{
				"totalGiB":       num(m, "totalGiB"),
				"usedGiB":        num(m, "usedGiB"),
				"freeGiB":        num(m, "freeGiB"),
				"usedPercent":    num(m, "usedPercent"),
				"memoryPressure": num(m, "memoryPressure"),
			},
			"disk": map[string]any{
				"capacityGiB":  num(d, "capacityGiB"),
				"imagesGiB":    num(d, "imagesGiB"),
				"diskPressure": num(d, "diskPressure"),
				"usedPercent":  num(d, "usedPercent"),
			},
		})
	}

	toF := func(v any) (float64, bool) {
		f, ok := v.(float64)
		return f, ok
	}

	var cpuSum, cpuCount, memTotal, memUsed float64
	var memCount int
	for _, n := range nodes {
		cm := n["cpu"].(map[string]any)
		if p, ok := toF(cm["usedPercent"]); ok {
			cpuSum += p
			cpuCount++
		}
		mm := n["memory"].(map[string]any)
		if t, ok := toF(mm["totalGiB"]); ok {
			memTotal += t
		}
		if u, ok := toF(mm["usedGiB"]); ok {
			memUsed += u
			memCount++
		}
	}

	round := func(f float64) float64 {
		s := strconv.FormatFloat(f, 'f', 2, 64)
		v, _ := strconv.ParseFloat(s, 64)
		return v
	}

	summary := map[string]any{
		"totalNodes":       len(nodes),
		"totalMillicores":  num(mapOf(cpu.Data, "summary"), "totalMillicores"),
		"avgCpuPercent":    nil,
		"totalMemoryGiB":   nil,
		"usedMemoryGiB":    nil,
		"avgMemoryPercent": nil,
		"totalDiskGiB":     num(mapOf(disk.Data, "summary"), "totalCapacityGiB"),
		// see disk-service: metrics-server does not report it
	}
	if cpuCount > 0 {
		summary["avgCpuPercent"] = int(cpuSum/cpuCount + 0.5)
	}
	if memTotal > 0 {
		summary["totalMemoryGiB"] = round(memTotal)
	}
	if memCount > 0 {
		summary["usedMemoryGiB"] = round(memUsed)
		if memTotal > 0 {
			summary["avgMemoryPercent"] = int(memUsed/memTotal*100 + 0.5)
		}
	}

	degraded := cpu.Status != "OK" || memory.Status != "OK" || disk.Status != "OK"
	if avail, ok := num(cpu.Data, "metricsAvailable").(bool); ok && !avail {
		degraded = true
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"gateway":   "rest-service",
		"language":  "go",
		"protocol":  "HTTP",
		"timestamp": time.Now().UTC().Format(time.RFC3339),
		"degraded":  degraded,
		"sources":   sources,
		"summary":   summary,
		"nodes":     nodes,
	})
}

func mapOf(m map[string]any, key string) map[string]any {
	if m == nil {
		return nil
	}
	v, _ := m[key].(map[string]any)
	return v
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	ctx := context.Background()
	shutdownTracer := initTracer(ctx)

	port := os.Getenv("PORT")
	if port == "" {
		port = "4000"
	}
	mux := http.NewServeMux()

	// /health = the process is alive (liveness).
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "UP", "service": "rest-service"})
	})

	// /ready = actually able to serve (readiness).
	//
	// The NATS version had to answer NOT_READY until the broker connected. There is no broker
	// in the path now — each HTTP call handles its own failure — so there is no global state
	// left to be unready about. An underrated benefit of dropping the broker: one fewer thing
	// that can be half-alive.
	//
	//
	mux.HandleFunc("/ready", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]any{"status": "READY", "service": "rest-service"})
	})

	mux.HandleFunc("/api/k8s-metrics", handleMetrics)

	// otelhttp is Go's equivalent of Node auto-instrumentation, but it must be wrapped EXPLICITLY.
	// WithFilter keeps health probes out of traces: measured on this cluster they were ~99% of all
	// spans and dragged the service P50 down to ~50µs.
	handler := otelhttp.NewHandler(mux, "http.server",
		otelhttp.WithFilter(func(r *http.Request) bool {
			switch r.URL.Path {
			case "/health", "/ready", "/healthz", "/metrics":
				return false
			}
			return true
		}),
		otelhttp.WithSpanNameFormatter(func(_ string, r *http.Request) string {
			return r.Method + " " + r.URL.Path
		}),
	)

	srv := &http.Server{Addr: ":" + port, Handler: handler}

	go func() {
		log.Printf("[rest-service] HTTP :%s", port)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("[rest-service] HTTP server error: %v", err)
		}
	}()

	// Kubernetes sends SIGTERM, then SIGKILL after terminationGracePeriodSeconds. Without this a
	// rolling update cuts in-flight requests AND drops buffered spans — losing the trace of the
	// last request before the failure.
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	<-stop
	log.Println("[rest-service] shutting down")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = srv.Shutdown(shutdownCtx)
	_ = shutdownTracer(shutdownCtx)
}
