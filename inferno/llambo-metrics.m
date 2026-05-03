# Module definition for llambo-metrics
# Thread-safe metrics collection with Prometheus HTTP export.
# Uses a channel-based mutex (semaphore with one token) for safe concurrent access.

LlamboMetrics: module
{
	PATH: con "/dis/llambo-metrics.dis";

	# Number of latency histogram buckets
	N_BUCKETS: con 10;

	Metrics: adt {
		# Counters
		inference_total: int;
		tokens_total: int;
		errors_total: int;
		nodes_spawned: int;
		nodes_shutdown: int;

		# Labels for Prometheus output
		node_id: string;
		model_type: string;

		# Latency tracking
		latency_sum_ms: int;
		latency_count: int;
		latency_hist: array of int;   # count per bucket [0..N_BUCKETS-1]

		# Mutex: a buffered chan(1) of int initialised with one token
		lock: chan of int;

		new: fn(node_id: string, model_type: string): ref Metrics;
		record_inference: fn(m: self ref Metrics, latency_ms: int);
		record_error: fn(m: self ref Metrics);
		record_tokens: fn(m: self ref Metrics, n: int);
		record_spawn: fn(m: self ref Metrics);
		record_shutdown: fn(m: self ref Metrics);
		avg_latency: fn(m: self ref Metrics): int;
		to_prometheus: fn(m: self ref Metrics): string;
	};

	# Module initialisation
	init: fn(ctxt: ref Draw->Context, args: list of string);

	# Start HTTP server on given port exporting Prometheus metrics
	serve: fn(port: int, metrics: ref Metrics);
};
