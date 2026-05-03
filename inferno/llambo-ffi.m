# Module definition for llama-cpp bridge FFI integration
# Provides access to actual llama.cpp inference via Unix socket bridge

LlamboFFI: module
{
	PATH: con "/dis/llambo-ffi.dis";
	
	# Initialize the FFI bridge connection
	init: fn(ctx: ref Draw->Context, args: list of string);
	
	# Bridge connection handle
	Bridge: adt {
		fd: ref Sys->FD;
		connected: int;
		socket_path: string;
		
		# Connect to the bridge service
		connect: fn(socket_path: string): ref Bridge;
		
		# Disconnect from bridge
		disconnect: fn(b: self ref Bridge);
		
		# Send command and receive response
		send_command: fn(b: self ref Bridge, cmd: string): (int, string, string);
		
		# High-level operations
		ping: fn(b: self ref Bridge): int;
		load_model: fn(b: self ref Bridge, model_path: string): (int, string);
		infer: fn(b: self ref Bridge, prompt: string): (int, string, string);
		infer_stream: fn(b: self ref Bridge, prompt: string, callback: StreamCallback): (int, string);
		get_status: fn(b: self ref Bridge): (int, string);
		free_model: fn(b: self ref Bridge): int;
	};
	
	# Callback for streaming tokens
	StreamCallback: type ref fn(token: string, is_final: int);
	
	# Response from bridge
	Response: adt {
		status: string;    # "ok" or "error"
		message: string;   # Status message
		data: string;      # Optional data payload
	};
	
	# Streaming token response
	StreamToken: adt {
		token: string;     # Token text
		is_final: int;     # 1 if this is the final token
	};
	
	# Parse JSON response from bridge
	parse_response: fn(json: string): ref Response;
	
	# Parse streaming token response
	parse_stream_token: fn(json: string): ref StreamToken;

	# BridgePool: a semaphore-based pool of Bridge connections
	# allowing multiple Limbo workers to share bridge instances efficiently.
	# socket_paths is an array of Unix socket paths, one per bridge instance.
	# Each acquire() blocks until a bridge is available; release() returns it.
	BridgePool: adt {
		bridges: array of ref Bridge;
		size: int;
		lock: chan of int;   # semaphore: contains available bridge indices

		new: fn(socket_paths: array of string): ref BridgePool;
		acquire: fn(bp: self ref BridgePool): ref Bridge;
		release: fn(bp: self ref BridgePool, b: ref Bridge);
		health_check: fn(bp: self ref BridgePool);
		discover: fn(base_path: string, max_n: int): array of string;
	};
};
