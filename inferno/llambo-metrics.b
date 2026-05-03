implement LlamboMetrics;

# LlamboMetrics: thread-safe Prometheus metrics for the llambo cluster.
# Each Metrics ADT owns a chan(1)-based mutex so multiple goroutines can
# safely increment counters concurrently without data races.
#
# HTTP server (serve/serve_client) exposes /metrics in Prometheus text format.

include "sys.m";
	sys: Sys;
	print, fprint, sprint: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "string.m";
	str: String;

include "llambo-metrics.m";

# Latency histogram bucket upper bounds (milliseconds)
# Must have exactly N_BUCKETS entries.
BUCKET_BOUNDS: array of int;

init(ctxt: ref Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	str = load String String->PATH;

	BUCKET_BOUNDS = array[] of {1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000};

	print("llambo-metrics: metrics module initialized\n");
}

# ---- Metrics ADT --------------------------------------------------------

Metrics.new(node_id: string, model_type: string): ref Metrics
{
	m := ref Metrics;
	m.node_id = node_id;
	m.model_type = model_type;
	m.inference_total = 0;
	m.tokens_total = 0;
	m.errors_total = 0;
	m.nodes_spawned = 0;
	m.nodes_shutdown = 0;
	m.latency_sum_ms = 0;
	m.latency_count = 0;
	m.latency_hist = array[N_BUCKETS] of {* => 0};

	# Initialise mutex: buffered channel of size 1, pre-loaded with one token
	m.lock = chan(1) of int;
	m.lock <-= 1;

	return m;
}

Metrics.record_inference(m: self ref Metrics, latency_ms: int)
{
	if (m == nil) return;
	<-m.lock;  # acquire

	m.inference_total++;
	m.latency_sum_ms += latency_ms;
	m.latency_count++;

	# Update histogram: add to the first bucket whose bound >= latency_ms
	if (BUCKET_BOUNDS != nil) {
		for (i := 0; i < N_BUCKETS; i++) {
			if (latency_ms <= BUCKET_BOUNDS[i]) {
				m.latency_hist[i]++;
				break;
			}
		}
	}

	m.lock <-= 1;  # release
}

Metrics.record_error(m: self ref Metrics)
{
	if (m == nil) return;
	<-m.lock;
	m.errors_total++;
	m.lock <-= 1;
}

Metrics.record_tokens(m: self ref Metrics, n: int)
{
	if (m == nil) return;
	<-m.lock;
	m.tokens_total += n;
	m.lock <-= 1;
}

Metrics.record_spawn(m: self ref Metrics)
{
	if (m == nil) return;
	<-m.lock;
	m.nodes_spawned++;
	m.lock <-= 1;
}

Metrics.record_shutdown(m: self ref Metrics)
{
	if (m == nil) return;
	<-m.lock;
	m.nodes_shutdown++;
	m.lock <-= 1;
}

Metrics.avg_latency(m: self ref Metrics): int
{
	if (m == nil || m.latency_count == 0) return 0;
	return m.latency_sum_ms / m.latency_count;
}

# Format all metrics in Prometheus exposition text format.
Metrics.to_prometheus(m: self ref Metrics): string
{
	if (m == nil) return "";

	<-m.lock;  # acquire (held for the entire serialisation to get a consistent snapshot)

	labels := sprint("{node=\"%s\",model_type=\"%s\"}", m.node_id, m.model_type);
	# Inner labels string (without surrounding braces) for histogram
	inner := m.node_id == "" ?
	         sprint("model_type=\"%s\"", m.model_type) :
	         sprint("node=\"%s\",model_type=\"%s\"", m.node_id, m.model_type);

	out := "";

	# ---- inference_total
	out += "# HELP llambo_inference_total Total inference requests\n";
	out += "# TYPE llambo_inference_total counter\n";
	out += sprint("llambo_inference_total%s %d\n", labels, m.inference_total);

	# ---- tokens_total
	out += "# HELP llambo_tokens_total Total tokens generated\n";
	out += "# TYPE llambo_tokens_total counter\n";
	out += sprint("llambo_tokens_total%s %d\n", labels, m.tokens_total);

	# ---- errors_total
	out += "# HELP llambo_errors_total Total inference errors\n";
	out += "# TYPE llambo_errors_total counter\n";
	out += sprint("llambo_errors_total%s %d\n", labels, m.errors_total);

	# ---- node lifecycle
	out += "# HELP llambo_nodes_spawned_total Nodes spawned\n";
	out += "# TYPE llambo_nodes_spawned_total counter\n";
	out += sprint("llambo_nodes_spawned_total%s %d\n", labels, m.nodes_spawned);

	out += "# HELP llambo_nodes_shutdown_total Nodes shut down\n";
	out += "# TYPE llambo_nodes_shutdown_total counter\n";
	out += sprint("llambo_nodes_shutdown_total%s %d\n", labels, m.nodes_shutdown);

	# ---- latency average
	avg := (m.latency_count > 0) ? m.latency_sum_ms / m.latency_count : 0;
	out += "# HELP llambo_latency_avg_ms Average inference latency ms\n";
	out += "# TYPE llambo_latency_avg_ms gauge\n";
	out += sprint("llambo_latency_avg_ms%s %d\n", labels, avg);

	# ---- latency histogram
	out += "# HELP llambo_latency_ms Inference latency histogram\n";
	out += "# TYPE llambo_latency_ms histogram\n";

	if (BUCKET_BOUNDS != nil) {
		cumulative := 0;
		for (i := 0; i < N_BUCKETS; i++) {
			cumulative += m.latency_hist[i];
			out += sprint("llambo_latency_ms_bucket{le=\"%d\",%s} %d\n",
			       BUCKET_BOUNDS[i], inner, cumulative);
		}
	}
	out += sprint("llambo_latency_ms_bucket{le=\"+Inf\",%s} %d\n", inner, m.latency_count);
	out += sprint("llambo_latency_ms_sum%s %d\n", labels, m.latency_sum_ms);
	out += sprint("llambo_latency_ms_count%s %d\n", labels, m.latency_count);

	m.lock <-= 1;  # release
	return out;
}

# ---- HTTP server --------------------------------------------------------
# Announces on port, accepts TCP connections, serves Prometheus /metrics.

serve(port: int, metrics: ref Metrics)
{
	if (metrics == nil) return;

	addr := sprint("tcp!*!%d", port);
	(ok, conn) := sys->announce(addr);
	if (ok < 0) {
		print(sprint("llambo-metrics: cannot announce on port %d\n", port));
		return;
	}

	print(sprint("llambo-metrics: serving /metrics on port %d\n", port));

	for (;;) {
		(ok2, lconn) := sys->listen(conn);
		if (ok2 < 0) continue;
		spawn serve_client(lconn.dfd, metrics);
	}
}

# Serve a single HTTP client
serve_client(fd: ref Sys->FD, metrics: ref Metrics)
{
	if (fd == nil || metrics == nil) return;

	# Read HTTP request (only first 4096 bytes needed to parse the path)
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf - 1);
	if (n <= 0) return;

	request := string buf[0:n];

	# Accept GET / and GET /metrics
	is_metrics := str->in("GET /metrics", request) >= 0 ||
	              str->in("GET / ", request) >= 0;

	body: string;
	status_line: string;
	content_type := "text/plain; version=0.0.4\r\n";

	if (is_metrics) {
		body = metrics.to_prometheus();
		status_line = "HTTP/1.1 200 OK\r\n";
	} else {
		body = "404 Not Found\nAvailable: GET /metrics\n";
		status_line = "HTTP/1.1 404 Not Found\r\n";
		content_type = "text/plain\r\n";
	}

	body_bytes := array of byte body;
	response := status_line;
	response += "Content-Type: " + content_type;
	response += sprint("Content-Length: %d\r\n", len body_bytes);
	response += "Connection: close\r\n";
	response += "\r\n";
	response += body;

	resp_bytes := array of byte response;
	sys->write(fd, resp_bytes, len resp_bytes);
}
