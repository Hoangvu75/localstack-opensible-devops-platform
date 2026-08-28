package io.learnopensible.disk;

import com.google.gson.Gson;
import com.google.gson.GsonBuilder;
import com.google.gson.JsonArray;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import io.javalin.Javalin;
import org.apache.kafka.clients.producer.KafkaProducer;
import org.apache.kafka.clients.producer.ProducerConfig;
import org.apache.kafka.clients.producer.ProducerRecord;
import io.kubernetes.client.openapi.ApiClient;
import io.kubernetes.client.openapi.Configuration;
import io.kubernetes.client.openapi.apis.CoreV1Api;
import io.kubernetes.client.util.Config;

import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.cert.Certificate;
import java.security.cert.CertificateFactory;
import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManagerFactory;

/**
 * disk-service — node disk metrics, in Java.
 *
 * <p>Two decisions here are load-bearing; full reasoning in README §9.6 and §9.7.
 *
 * <p><b>Talks to kubelet directly, not through the API server proxy.</b> metrics-server does
 * not report used disk; that figure lives in kubelet {@code /stats/summary}. RBAC cannot
 * restrict paths inside the proxy, so {@code nodes/proxy} would also grant {@code /exec} and
 * {@code /run} — arbitrary commands in any container on any node. Kubelet authorises by path
 * instead: {@code /stats/*} maps to {@code nodes/stats}, which opens nothing else. The kubelet
 * serving cert is signed by the cluster CA every pod already mounts, so TLS is NOT skipped.
 *
 * <p><b>Reads raw JSON instead of {@code V1Node}.</b> The generated model calls
 * {@code validateJsonObject()} and throws on unknown fields. k3s v1.31.14 returns
 * {@code status.runtimeHandlers[].features.userNamespaces}, which client-java 21.0.1 does not
 * know, and the whole call dies. The TypeScript and Python clients hit the same endpoint on
 * the same cluster without trouble. Upgrading the client would only defer the next new field.
 */
public final class DiskService {

  private static final String SUBJECT = "metrics.disk";
  private static final int PORT =
      Integer.parseInt(System.getenv().getOrDefault("PORT", "4003"));

  private static final Gson GSON = new GsonBuilder().serializeNulls().create();

  // Kubelet port. Fixed Kubernetes default; it has never changed.
  private static final String KAFKA_BROKERS = System.getenv()
      .getOrDefault("KAFKA_BROKERS", "redpanda.redpanda.svc.cluster.local:9092");
  private static final String TOPIC = System.getenv().getOrDefault("METRICS_TOPIC", "node-metrics");

  private static final int KUBELET_PORT = 10250;
  private static final Path SA_TOKEN = Path.of("/var/run/secrets/kubernetes.io/serviceaccount/token");
  private static final Path SA_CA = Path.of("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt");
  // Deliberately short: rest-service gives up after 2500ms, so three kubelet calls must fit
  // well inside that. One hung node must not drag the whole answer down.
  private static final Duration KUBELET_TIMEOUT = Duration.ofMillis(800);

  private static final long GIB = 1024L * 1024L * 1024L;
  private static final Pattern QUANTITY = Pattern.compile("^(\\d+(?:\\.\\d+)?)([A-Za-z]*)$");
  private static final Map<String, Double> STORAGE_UNITS = Map.of(
      "Ki", 1024d, "Mi", Math.pow(1024, 2), "Gi", Math.pow(1024, 3), "Ti", Math.pow(1024, 4),
      "K", 1000d, "M", Math.pow(1000, 2), "G", Math.pow(1000, 3), "T", Math.pow(1000, 4));

  // No OpenTelemetry code in this file. The agent is injected by the OpenTelemetry Operator
  // (annotation inject-java) and instruments Javalin, the Kubernetes client and kafka-clients,
  // including traceparent propagation.
  //
  // Javalin matters: the agent does NOT instrument com.sun.net.httpserver, which this service
  // used first. Measured — /health produced 0 spans, and the trace would break here silently.
  //
  //
  //
  //
  //
  //

  private static Double storageQuantityToBytes(String q) {
    if (q == null || q.isEmpty()) {
      return null;
    }
    Matcher m = QUANTITY.matcher(q);
    if (!m.matches()) {
      return null;
    }
    String unit = m.group(2);
    double multiplier = unit.isEmpty() ? 1d : STORAGE_UNITS.getOrDefault(unit, 0d);
    if (multiplier == 0d) {
      return null;
    }
    return Double.parseDouble(m.group(1)) * multiplier;
  }

  private static Double toGiB(Double bytes) {
    return bytes == null ? null : Math.round(bytes / GIB * 100d) / 100d;
  }

  // Defensive JSON access: a missing field returns null rather than throwing —
  // the behaviour the Go, Python and TypeScript clients have by default.
  private static JsonObject obj(JsonObject parent, String key) {
    if (parent == null) {
      return null;
    }
    JsonElement e = parent.get(key);
    return e != null && e.isJsonObject() ? e.getAsJsonObject() : null;
  }

  private static JsonArray arr(JsonObject parent, String key) {
    if (parent == null) {
      return null;
    }
    JsonElement e = parent.get(key);
    return e != null && e.isJsonArray() ? e.getAsJsonArray() : null;
  }

  private static String str(JsonObject parent, String key) {
    if (parent == null) {
      return null;
    }
    JsonElement e = parent.get(key);
    return e != null && e.isJsonPrimitive() ? e.getAsString() : null;
  }

  private static Double numeric(JsonObject parent, String key) {
    if (parent == null) {
      return null;
    }
    JsonElement e = parent.get(key);
    return e != null && e.isJsonPrimitive() && e.getAsJsonPrimitive().isNumber()
        ? e.getAsDouble() : null;
  }

  private static String conditionStatus(JsonObject status, String type) {
    JsonArray conditions = arr(status, "conditions");
    if (conditions == null) {
      return null;
    }
    for (JsonElement e : conditions) {
      if (!e.isJsonObject()) {
        continue;
      }
      JsonObject c = e.getAsJsonObject();
      if (type.equals(str(c, "type"))) {
        return str(c, "status");
      }
    }
    return null;
  }

  /**
   * HttpClient trusting the cluster CA — the same CA that signed the kubelet serving cert.
   *
   * <p>Uses the JDK {@link HttpClient} rather than the OkHttp client-java pulls in: no extra
   * dependency, and no pinning a version this project does not control.
   *
   * <p>Returns null when it cannot be built: kubelet is skipped and {@code usedPercent} falls
   * back to null with a reason. It never throws.
   */
  private static HttpClient buildKubeletClient() {
    try {
      // The CA file may hold several certs during CA rotation, so use the plural form.
      CertificateFactory cf = CertificateFactory.getInstance("X.509");
      KeyStore trust = KeyStore.getInstance(KeyStore.getDefaultType());
      trust.load(null, null);
      int i = 0;
      try (InputStream in = Files.newInputStream(SA_CA)) {
        for (Certificate cert : cf.generateCertificates(in)) {
          trust.setCertificateEntry("k8s-ca-" + i++, cert);
        }
      }
      if (i == 0) {
        System.err.println("[disk-service] cluster CA is empty, skipping kubelet metrics");
        return null;
      }

      TrustManagerFactory tmf =
          TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm());
      tmf.init(trust);
      SSLContext ctx = SSLContext.getInstance("TLS");
      ctx.init(null, tmf.getTrustManagers(), null);

      return HttpClient.newBuilder()
          .sslContext(ctx)
          .connectTimeout(KUBELET_TIMEOUT)
          .version(HttpClient.Version.HTTP_1_1)
          .build();
    } catch (Exception e) {
      System.err.println("[disk-service] could not build the kubelet client: " + e);
      return null;
    }
  }

  private static String internalIp(JsonObject status) {
    JsonArray addresses = arr(status, "addresses");
    if (addresses == null) {
      return null;
    }
    for (JsonElement e : addresses) {
      if (e.isJsonObject() && "InternalIP".equals(str(e.getAsJsonObject(), "type"))) {
        return str(e.getAsJsonObject(), "address");
      }
    }
    return null;
  }

  /**
   * Asks each kubelet for the {@code node.fs} section of /stats/summary.
   *
   * <p>One unreachable node must not break the whole answer: it is absent from the map and its
   * own {@code usedPercent} becomes null.
   *
   * <p>The token is re-read every call, never cached: service-account tokens expire and kubelet
   * rewrites the file on refresh. Caching earns a 401 after about an hour.
   */
  private static Map<String, JsonObject> fetchKubeletStats(HttpClient http, JsonArray nodes) {
    Map<String, JsonObject> byNode = new LinkedHashMap<>();
    if (http == null) {
      return byNode;
    }
    String token;
    try {
      token = Files.readString(SA_TOKEN).trim();
    } catch (Exception e) {
      System.err.println("[disk-service] could not read the service account token: " + e);
      return byNode;
    }

    for (JsonElement item : nodes) {
      if (!item.isJsonObject()) {
        continue;
      }
      JsonObject node = item.getAsJsonObject();
      String name = str(obj(node, "metadata"), "name");
      String ip = internalIp(obj(node, "status"));
      if (name == null || ip == null) {
        continue;
      }
      try {
        HttpRequest req = HttpRequest.newBuilder()
            .uri(URI.create("https://" + ip + ":" + KUBELET_PORT + "/stats/summary"))
            .header("Authorization", "Bearer " + token)
            .header("Accept", "application/json")
            .timeout(KUBELET_TIMEOUT)
            .GET()
            .build();
        HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
        if (res.statusCode() != 200) {
          // A 403 here is almost always a ClusterRole missing nodes/stats.
          System.err.println("[disk-service] kubelet " + name + " returned " + res.statusCode());
          continue;
        }
        JsonObject root = com.google.gson.JsonParser.parseString(res.body()).getAsJsonObject();
        JsonObject fsInfo = obj(obj(root, "node"), "fs");
        if (fsInfo != null) {
          byNode.put(name, fsInfo);
        }
      } catch (Exception e) {
        System.err.println("[disk-service] could not query kubelet " + name + ": " + e);
      }
    }
    return byNode;
  }

  /**
   * Fetches the node list as raw JSON.
   *
   * <p>{@code buildCall} builds exactly the request {@code listNode().execute()} would send —
   * same base path, same bearer-token interceptor, same TLS — but asks {@code ApiClient} for a
   * {@link JsonObject}, skipping the field validation that broke this call.
   *
   * <p>{@code var} is deliberate: naming {@code okhttp3.Call} would make okhttp a direct
   * dependency; this way client-java keeps deciding its version.
   */
  private static JsonArray listNodesRaw(ApiClient client, CoreV1Api coreApi) throws Exception {
    var call = coreApi.listNode().buildCall(null);
    JsonObject root = client.<JsonObject>execute(call, JsonObject.class).getData();
    JsonArray items = arr(root, "items");
    return items == null ? new JsonArray() : items;
  }

  private static Map<String, Object> collect(ApiClient client, HttpClient kubelet, CoreV1Api coreApi)
      throws Exception {
    JsonArray items = listNodesRaw(client, coreApi);
    return summarize(items, fetchKubeletStats(kubelet, items));
  }

  /**
   * Turns the raw node list into the payload.
   *
   * <p>Pure function, touches no network, so it can be verified against a saved
   * {@code kubectl get nodes -o json}. Package-private for exactly that reason.
   *
   */
  static Map<String, Object> summarize(JsonArray items, Map<String, JsonObject> kubeletFsByNode) {

    List<Map<String, Object>> nodes = new ArrayList<>();
    double totalCapacityGiB = 0d;
    double totalImagesGiB = 0d;
    double totalUsedGiB = 0d;
    int underPressure = 0;
    int nodesWithUsage = 0;

    for (JsonElement item : items) {
      if (!item.isJsonObject()) {
        continue;
      }
      JsonObject node = item.getAsJsonObject();
      JsonObject metadata = obj(node, "metadata");
      JsonObject status = obj(node, "status");

      String name = str(metadata, "name");
      if (name == null) {
        name = "unknown";
      }
      JsonObject labels = obj(metadata, "labels");
      boolean isControlPlane = labels != null
          && (labels.has("node-role.kubernetes.io/control-plane")
              || labels.has("node-role.kubernetes.io/master"));

      // The quantity already carries its suffix ("20959212Ki"), exactly what
      // storageQuantityToBytes expects.
      Double capacity = storageQuantityToBytes(str(obj(status, "capacity"), "ephemeral-storage"));
      Double allocatable = storageQuantityToBytes(str(obj(status, "allocatable"), "ephemeral-storage"));

      double imagesBytes = 0d;
      int imageCount = 0;
      JsonArray images = arr(status, "images");
      if (images != null) {
        imageCount = images.size();
        for (JsonElement img : images) {
          if (!img.isJsonObject()) {
            continue;
          }
          JsonElement size = img.getAsJsonObject().get("sizeBytes");
          if (size != null && size.isJsonPrimitive()) {
            imagesBytes += size.getAsLong();
          }
        }
      }

      boolean diskPressure = "True".equals(conditionStatus(status, "DiskPressure"));
      if (diskPressure) {
        underPressure++;
      }

      Double capacityGiB = toGiB(capacity);
      Double imagesGiB = imageCount > 0 ? toGiB(imagesBytes) : null;
      if (capacityGiB != null) {
        totalCapacityGiB += capacityGiB;
      }
      if (imagesGiB != null) {
        totalImagesGiB += imagesGiB;
      }

      Map<String, Object> n = new LinkedHashMap<>();
      n.put("name", name);
      n.put("role", isControlPlane ? "control-plane" : "worker");
      n.put("status", "True".equals(conditionStatus(status, "Ready")) ? "Ready" : "NotReady");
      n.put("capacityGiB", capacityGiB);
      n.put("allocatableGiB", toGiB(allocatable));
      n.put("imagesGiB", imagesGiB);
      n.put("imageCount", imageCount);
      n.put("diskPressure", diskPressure);

      // ── "Used", from kubelet ─────────────────────────────────────────────
      // node.fs is the kubelet root filesystem (nodefs), which is what ephemeral-storage counts.
      // NOT imageFs: on many setups both point at the same disk, so adding them double-counts.
      //
      // Absent from the map means that node did not answer — leave it null.
      JsonObject kfs = kubeletFsByNode.get(name);
      Double usedGiB = null;
      Double availableGiB = null;
      Integer usedPercent = null;
      if (kfs != null) {
        Double usedBytes = numeric(kfs, "usedBytes");
        Double capBytes = numeric(kfs, "capacityBytes");
        usedGiB = toGiB(usedBytes);
        availableGiB = toGiB(numeric(kfs, "availableBytes"));
        if (usedBytes != null && capBytes != null && capBytes > 0d) {
          usedPercent = (int) Math.round(usedBytes / capBytes * 100d);
          totalUsedGiB += usedBytes / GIB;
          nodesWithUsage++;
        }
      }
      n.put("usedGiB", usedGiB);
      n.put("availableGiB", availableGiB);
      n.put("usedPercent", usedPercent);
      nodes.add(n);
    }

    Map<String, Object> summary = new LinkedHashMap<>();
    summary.put("totalNodes", nodes.size());
    summary.put("totalCapacityGiB", totalCapacityGiB > 0 ? Math.round(totalCapacityGiB * 100d) / 100d : null);
    summary.put("totalImagesGiB", totalImagesGiB > 0 ? Math.round(totalImagesGiB * 100d) / 100d : null);
    summary.put("totalUsedGiB", nodesWithUsage > 0 ? Math.round(totalUsedGiB * 100d) / 100d : null);
    summary.put("nodesUnderDiskPressure", underPressure);
    summary.put("averageUsagePercent",
        nodesWithUsage > 0 && totalCapacityGiB > 0
            ? (int) Math.round(totalUsedGiB / totalCapacityGiB * 100d)
            : null);

    Map<String, Object> payload = new LinkedHashMap<>();
    payload.put("service", "disk-service");
    payload.put("language", "java");
    payload.put("timestamp", Instant.now().toString());
    // Say it at the payload level so the frontend does not have to guess.
    boolean haveUsage = nodesWithUsage > 0;
    payload.put("metricsAvailable", haveUsage);
    payload.put("usageSource", haveUsage ? "kubelet:/stats/summary" : "unavailable");
    payload.put("degradedReason", haveUsage
        ? null
        : "Could not read /stats/summary from any kubelet. Usually a ClusterRole missing "
            + "nodes/stats, or the pod cannot reach port 10250. Capacity and image counts "
            + "below are still real; only the \"used\" figure is missing.");
    payload.put("summary", summary);
    payload.put("nodes", nodes);
    return payload;
  }

  /**
   * Kafka producer. Returns null when it cannot be built — publishing is skipped and
   * /api/metrics still answers. A dead broker must not kill the service.
   *
   * <p>No OpenTelemetry code here: the javaagent recognises kafka-clients, creates the PRODUCER
   * span and injects traceparent into the record headers.
   */
  private static KafkaProducer<String, String> buildProducer() {
    try {
      Properties props = new Properties();
      props.put(ProducerConfig.BOOTSTRAP_SERVERS_CONFIG, KAFKA_BROKERS);
      props.put(ProducerConfig.KEY_SERIALIZER_CLASS_CONFIG,
          "org.apache.kafka.common.serialization.StringSerializer");
      props.put(ProducerConfig.VALUE_SERIALIZER_CLASS_CONFIG,
          "org.apache.kafka.common.serialization.StringSerializer");
      // Deliberately short: the HTTP caller must not wait on the broker. On timeout the message is
      // dropped rather than blocking the response.
      props.put(ProducerConfig.MAX_BLOCK_MS_CONFIG, 2000);
      props.put(ProducerConfig.DELIVERY_TIMEOUT_MS_CONFIG, 5000);
      props.put(ProducerConfig.REQUEST_TIMEOUT_MS_CONFIG, 3000);
      props.put(ProducerConfig.CLIENT_ID_CONFIG, "disk-service");
      return new KafkaProducer<>(props);
    } catch (Exception e) {
      System.err.println("[disk-service] could not build the Kafka producer: " + e);
      return null;
    }
  }

  public static void main(String[] args) throws Exception {
    // Do NOT let a config error kill the process at startup: that means CrashLoopBackOff and the
    // loss of /health along with any way to report why. Degrade instead.
    CoreV1Api coreApi = null;
    ApiClient rawClient = null;
    try {
      rawClient = Config.defaultClient();
      Configuration.setDefaultApiClient(rawClient);
      coreApi = new CoreV1Api(rawClient);
    } catch (Exception e) {
      System.err.println("[disk-service] could not load the Kubernetes config: " + e);
    }
    final CoreV1Api api = coreApi;
    // ApiClient is kept: collect() needs it to decode responses, see listNodesRaw().
    final ApiClient apiClient = rawClient;

    // Built once at startup: reading the CA and initialising SSLContext is expensive. null here is
    // not fatal — capacity still works, only the "used" figure is missing.
    final HttpClient kubeletClient = buildKubeletClient();
    final KafkaProducer<String, String> producer = buildProducer();

    // ── HTTP ────────────────────────────────────────────────────────────────
    // Three routes, no OpenTelemetry code: the server span, the client span for the Kubernetes API
    // call and traceparent propagation are all the agent.
    //
    // GSON.toJson rather than ctx.json(): ctx.json() wants a JsonMapper (Jackson by default), and
    // this repo already uses Gson. No second JSON library.
    Javalin app = Javalin.create().start("0.0.0.0", PORT);

    app.get("/health", ctx ->
        ctx.contentType("application/json")
           .result(GSON.toJson(Map.of("status", "UP", "service", "disk-service"))));

    // No broker to be "not connected" to. If the process is up, it can serve.
    app.get("/ready", ctx ->
        ctx.contentType("application/json")
           .result(GSON.toJson(Map.of("status", "READY", "service", "disk-service"))));

    // The real endpoint.
    app.get("/api/metrics", ctx -> {
      try {
        if (api == null || apiClient == null) {
          throw new IllegalStateException("Kubernetes client not ready");
        }
        Map<String, Object> data = collect(apiClient, kubeletClient, api);

        // Fire-and-forget on purpose: send() is async. The PRODUCER span is still created inside the
        // request context, so it lands in the right place in the tree.
        if (producer != null) {
          producer.send(new ProducerRecord<>(TOPIC, "disk", GSON.toJson(data)), (md, err) -> {
            if (err != null) {
              System.err.println("[disk-service] publish failed: " + err);
            }
          });
        }

        ctx.contentType("application/json").result(GSON.toJson(data));
      } catch (Exception e) {
        // Report the failure explicitly: callers must tell "no data" from "nobody answered".
        System.err.println("[disk-service] /metrics failed: " + e);
        Map<String, Object> err = new LinkedHashMap<>();
        err.put("service", "disk-service");
        err.put("error", String.valueOf(e));
        ctx.status(503).contentType("application/json").result(GSON.toJson(err));
      }
    });

    System.out.println("[disk-service] HTTP :" + PORT);

    // Kubernetes sends SIGTERM, then SIGKILL after terminationGracePeriodSeconds. Without this a
    // rolling update cuts in-flight requests AND drops buffered spans — losing the trace of the
    // last request before the failure.
    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
      System.out.println("[disk-service] shutting down");
      app.stop();
      // Flush before close: buffered records are lost otherwise.
      if (producer != null) {
        producer.close(java.time.Duration.ofSeconds(5));
      }
    }));

    Thread.currentThread().join();
  }

    private DiskService() { }
}
