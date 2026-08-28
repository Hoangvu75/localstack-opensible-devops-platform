// OpenTelemetry bootstrap for rest-service.
//
// Go has no monkey-patching auto-instrumentation, so nothing patches net/http behind your
// back — and the "import in the wrong order and lose every span" trap does not exist. The
// price is that everything is explicit: wrap handlers with otelhttp, create spans by hand.
// A real trade-off between ecosystems, not a ranking. See README §9.7.
package main

import (
	"context"
	"log"
	"os"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// initTracer builds the TracerProvider and returns its shutdown function.
//
// Configuration comes from the STANDARD OpenTelemetry environment variables, so the Kubernetes
//
//	manifest never needs to know which language a service is written in.
//
func initTracer(ctx context.Context) func(context.Context) error {
	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "rest-service"
	}

	// otlptracehttp reads OTEL_EXPORTER_OTLP_ENDPOINT itself and appends /v1/traces.
	// WithInsecure because the in-cluster Collector speaks plain HTTP.
	exporter, err := otlptracehttp.New(ctx, otlptracehttp.WithInsecure())
	if err != nil {
		log.Printf("[rest-service] could not build the OTLP exporter: %v", err)
		return func(context.Context) error { return nil }
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
		),
	)
	if err != nil {
		log.Printf("[rest-service] could not build the resource: %v", err)
		res = resource.Default()
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter, sdktrace.WithBatchTimeout(5*time.Second)),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)

	// Setting the propagator is MANDATORY, and this is the sharpest difference from Node: the Node
	// SDK ships W3C TraceContext by default, Go ships NONE. Without this line Inject/Extract
	// silently do nothing and the trace breaks at every process boundary, with no error anywhere.
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return tp.Shutdown
}
