# Module definition for llambo-worker
# An isolated Dis VM worker process for distributed inference.
# Loaded into a separate process namespace via ClusterNode.spawn().
# Communicates with a parent over stdin/stdout using a simple JSON protocol.
#
# Input  (one JSON object per line):
#   {"cmd":"infer","prompt":"...","max_tokens":N,"temperature":T,"top_p":P}
#   {"cmd":"status"}
#   {"cmd":"shutdown"}
#
# Output (one JSON object per line):
#   {"status":"ok","text":"...","token_count":N,"time_ms":N}
#   {"status":"ok","worker_status":N,"total_processed":N,"total_errors":N}
#   {"status":"error","message":"..."}

LlamboWorker: module
{
	PATH: con "/dis/llambo-worker.dis";

	# Worker configuration
	WorkerConfig: adt {
		node_id: string;
		model_path: string;
		model_type: string;
		capacity: int;
		socket_path: string;   # FFI bridge socket for this worker

		new: fn(node_id: string, model_path: string, model_type: string, capacity: int): ref WorkerConfig;
	};

	# Module entry point
	init: fn(ctxt: ref Draw->Context, args: list of string);
};
