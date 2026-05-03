Llambo: module
{
	PATH: con "/dis/llambo.dis";

	# Model representation
	Model: adt {
		path: string;
		ctx_size: int;
		n_threads: int;
		params: ref ModelParams;

		load: fn(path: string, params: ref ModelParams): ref Model;
		free: fn(m: self ref Model);
	};

	# Model parameters configuration
	ModelParams: adt {
		use_mmap: int;
		use_mlock: int;
		n_gpu_layers: int;
		vocab_only: int;

		default: fn(): ref ModelParams;
	};

	# Inference context
	Context: adt {
		model: ref Model;
		n_ctx: int;
		n_batch: int;
		n_threads: int;

		new: fn(model: ref Model, n_ctx: int, n_batch: int, n_threads: int): ref Context;
		free: fn(ctx: self ref Context);
	};

	# Token representation
	Token: adt {
		id: int;
		text: string;
		logit: real;
	};

	# Inference request/response
	InferenceRequest: adt {
		prompt: string;
		max_tokens: int;
		temperature: real;
		top_p: real;
		ctx: ref Context;
		required_type: string;   # model-type affinity: "tiny"|"medium"|"large"|""
	};

	InferenceResponse: adt {
		text: string;
		tokens: array of ref Token;
		completion_time: int;
		token_count: int;
	};

	# Core inference functions
	init: fn(ctxt: ref Draw->Context, args: list of string);
	tokenize: fn(ctx: ref Context, text: string): array of ref Token;
	detokenize: fn(ctx: ref Context, tokens: array of ref Token): string;
	infer: fn(req: ref InferenceRequest): ref InferenceResponse;
	infer_fusion: fn(orch: ref Orchestrator, prompt: string, n_nodes: int, strategy: int): ref InferenceResponse;

	# Distributed cluster node
	ClusterNode: adt {
		id: string;
		addr: string;
		capacity: int;
		load: int;
		status: int;        # 0=idle, 1=busy, 2=error/shutdown
		model_type: string; # "tiny"|"medium"|"large"
		draining: int;      # 1 = graceful shutdown in progress
		last_heartbeat: int;
		error_count: int;
		req_chan: chan of ref InferenceRequest;
		resp_chan: chan of ref InferenceResponse;

		spawn: fn(addr: string, capacity: int, model_type: string): ref ClusterNode;
		shutdown: fn(node: self ref ClusterNode);
		submit: fn(node: self ref ClusterNode, req: ref InferenceRequest): ref InferenceResponse;
	};

	# Load balancer
	# strategy: 0=round-robin, 1=least-loaded, 2=random, 3=cognitive-affinity
	LoadBalancer: adt {
		nodes: array of ref ClusterNode;
		strategy: int;
		rr_index: int;    # round-robin cursor
		max_retries: int;

		new: fn(strategy: int): ref LoadBalancer;
		register: fn(lb: self ref LoadBalancer, node: ref ClusterNode);
		unregister: fn(lb: self ref LoadBalancer, nodeid: string);
		balance: fn(lb: self ref LoadBalancer, req: ref InferenceRequest): ref InferenceResponse;
		getstats: fn(lb: self ref LoadBalancer): string;
		health_check: fn(lb: self ref LoadBalancer);
	};

	# Cognitive fusion
	# strategy: 0=weighted-avg, 1=majority-vote, 2=confidence-weighted, 3=raft-consensus
	CognitiveFusion: adt {
		strategy: int;
		min_nodes: int;
		timeout_ms: int;

		new: fn(strategy: int, min_nodes: int, timeout_ms: int): ref CognitiveFusion;
		fuse: fn(cf: self ref CognitiveFusion, responses: array of ref InferenceResponse): ref InferenceResponse;
	};

	# Cluster orchestrator
	Orchestrator: adt {
		balancer: ref LoadBalancer;
		max_nodes: int;
		active_nodes: int;
		total_requests: int;
		pending_requests: int;
		scale_up_threshold: real;
		scale_down_threshold: real;
		min_nodes_scale: int;
		default_model_path: string;

		new: fn(max_nodes: int, strategy: int): ref Orchestrator;
		spawn_cluster: fn(orch: self ref Orchestrator, count: int, model_path: string): int;
		shutdown_cluster: fn(orch: self ref Orchestrator);
		process: fn(orch: self ref Orchestrator, prompt: string, max_tokens: int): ref InferenceResponse;
		status: fn(orch: self ref Orchestrator): string;
		scale_to: fn(orch: self ref Orchestrator, target: int);
		save_state: fn(orch: self ref Orchestrator, path: string);
		load_state: fn(orch: self ref Orchestrator, path: string): int;
	};
};
