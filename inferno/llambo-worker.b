implement LlamboWorker;

# LlamboWorker: isolated Dis VM worker process for distributed llama.cpp inference.
# Receives JSON commands from stdin; writes JSON responses to stdout.
# Forks its namespace on start for process isolation.
# Connects to the llama-cpp-bridge FFI bridge for real inference when available;
# falls back to the llambo module mock otherwise.
#
# Usage:
#   llambo-worker <node_id> <model_path> <model_type> [capacity] [socket_path]

include "sys.m";
	sys: Sys;
	print, fprint, sprint: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "llambo.m";
	llambo: Llambo;
	Model, Context as LlamboCtx, InferenceRequest, InferenceResponse: import llambo;

include "llambo-ffi.m";
	ffi: LlamboFFI;
	Bridge: import ffi;

include "llambo-worker.m";

# Worker status constants
WORKER_IDLE  : con 0;
WORKER_BUSY  : con 1;
WORKER_ERROR : con 2;

# Module-level worker state
worker_config: ref LlamboWorker->WorkerConfig;
bridge: ref Bridge;
model: ref Model;
ctx: ref LlamboCtx;
worker_status := WORKER_IDLE;
total_processed := 0;
total_errors := 0;

WorkerConfig.new(node_id: string, model_path: string, model_type: string, capacity: int): ref WorkerConfig
{
	wc := ref WorkerConfig;
	wc.node_id = node_id;
	wc.model_path = model_path;
	wc.model_type = model_type;
	wc.capacity = capacity;
	wc.socket_path = "/tmp/llama-cpp-bridge.sock";
	return wc;
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	llambo = load Llambo Llambo->PATH;
	ffi = load LlamboFFI LlamboFFI->PATH;

	if (llambo == nil) {
		print("llambo-worker: cannot load Llambo module\n");
		raise "fail:load";
	}
	llambo->init(ctxt, nil);

	# Parse arguments: node_id model_path model_type [capacity] [socket_path]
	node_id := "worker-default";
	model_path := "/models/llama-7b.gguf";
	model_type := "medium";
	capacity := 100;
	socket_path := "/tmp/llama-cpp-bridge.sock";

	args := argv;
	if (args != nil) args = tl args;   # skip module name
	if (args != nil) { node_id    = hd args; args = tl args; }
	if (args != nil) { model_path = hd args; args = tl args; }
	if (args != nil) { model_type = hd args; args = tl args; }
	if (args != nil) { capacity   = int hd args; args = tl args; }
	if (args != nil) { socket_path = hd args; }

	worker_config = WorkerConfig.new(node_id, model_path, model_type, capacity);
	worker_config.socket_path = socket_path;

	print("llambo-worker: " + node_id + " starting (" + model_type + ")\n");

	# Fork namespace for isolation
	sys->pctl(Sys->NEWPGRP | Sys->FORKNS, nil);

	# Bind model directory read-only into this namespace
	sys->bind("/models", "/n/models", Sys->MBEFORE);

	# Connect to FFI bridge if available
	if (ffi != nil) {
		ffi->init(ctxt, nil);
		bridge = Bridge.connect(socket_path);
		if (bridge != nil) {
			(ok, msg) := bridge.load_model(model_path);
			if (ok > 0) {
				print("llambo-worker: " + node_id + " model loaded via FFI bridge\n");
			} else {
				print("llambo-worker: " + node_id + " FFI model load failed: " + msg + "\n");
				bridge.disconnect();
				bridge = nil;
			}
		} else {
			print("llambo-worker: " + node_id + " FFI bridge unavailable\n");
		}
	}

	# Fallback: load model through llambo module
	if (bridge == nil) {
		model = llambo->Model.load(model_path, nil);
		if (model != nil) {
			ctx = llambo->Context.new(model, 2048, 512, 4);
			print("llambo-worker: " + node_id + " model loaded via llambo module\n");
		}
	}

	print("llambo-worker: " + node_id + " ready (capacity=" + string capacity + ")\n");

	# Enter command loop
	run_command_loop();

	# Cleanup
	if (bridge != nil) {
		bridge.free_model();
		bridge.disconnect();
	}
	if (ctx != nil) ctx.free();
	if (model != nil) model.free();
	print("llambo-worker: " + node_id + " shutdown\n");
}

# JSON command/response loop over stdin/stdout
run_command_loop()
{
	stdin := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if (stdin == nil) {
		print("llambo-worker: cannot open stdin\n");
		return;
	}
	stdout := sys->fildes(1);

	for (;;) {
		line := stdin.gets('\n');
		if (line == nil) break;
		if (len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		if (len line == 0) continue;

		# Extract "cmd" field
		cmd_key := "\"cmd\":\"";
		cmd_idx := str->in(cmd_key, line);
		if (cmd_idx < 0) {
			fprint(stdout, "{\"status\":\"error\",\"message\":\"missing cmd field\"}\n");
			continue;
		}
		s := cmd_idx + len cmd_key;
		e := s;
		while (e < len line && line[e] != '"') e++;
		if (e >= len line) {
			fprint(stdout, "{\"status\":\"error\",\"message\":\"malformed cmd\"}\n");
			continue;
		}
		cmd := line[s:e];

		case cmd {
		"infer" =>
			handle_infer(line, stdout);

		"status" =>
			fprint(stdout,
			       "{\"status\":\"ok\",\"worker_status\":%d,\"total_processed\":%d,\"total_errors\":%d}\n",
			       worker_status, total_processed, total_errors);

		"shutdown" =>
			fprint(stdout, "{\"status\":\"ok\",\"message\":\"shutting down\"}\n");
			return;

		* =>
			fprint(stdout, "{\"status\":\"error\",\"message\":\"unknown command: %s\"}\n", cmd);
		}
	}
}

# Extract a string value from a simple JSON object: "key":"value"
parse_json_string(json: string, key: string): string
{
	search := "\"" + key + "\":\"";
	idx := str->in(search, json);
	if (idx < 0) return "";
	s := idx + len search;
	e := s;
	while (e < len json) {
		if (json[e] == '"') {
			bs := 0;
			j := e - 1;
			while (j >= s && json[j] == '\\') { bs++; j--; }
			if (bs % 2 == 0) break;
		}
		e++;
	}
	if (e >= len json) return "";
	return json[s:e];
}

# Extract an integer value from a simple JSON object: "key":N
parse_json_int(json: string, key: string, default_val: int): int
{
	search := "\"" + key + "\":";
	idx := str->in(search, json);
	if (idx < 0) return default_val;
	s := idx + len search;
	e := s;
	while (e < len json && json[e] >= '0' && json[e] <= '9') e++;
	if (e == s) return default_val;
	return int json[s:e];
}

# Escape a string for embedding inside a JSON string value
escape_for_json(s: string): string
{
	result := "";
	for (i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'"'  => result += "\\\"";
		'\\' => result += "\\\\";
		'\n' => result += "\\n";
		'\r' => result += "\\r";
		'\t' => result += "\\t";
		*    => result += sprint("%c", c);
		}
	}
	return result;
}

# Handle a single "infer" request
handle_infer(json: string, stdout: ref Sys->FD)
{
	prompt := parse_json_string(json, "prompt");
	if (prompt == "") {
		fprint(stdout, "{\"status\":\"error\",\"message\":\"missing prompt\"}\n");
		return;
	}
	max_tokens := parse_json_int(json, "max_tokens", 256);

	worker_status = WORKER_BUSY;
	start_time := sys->millisec();

	result_text := "";
	token_count := 0;
	ok := 1;

	if (bridge != nil) {
		# Real inference via FFI bridge
		cmd := sprint("INFER max_tokens=%d %s", max_tokens, prompt);
		(rc, msg, data) := bridge.send_command(cmd);
		if (rc > 0) {
			result_text = data;
			token_count = len str->unquoted(result_text);
		} else {
			result_text = "Error: " + msg;
			ok = 0;
		}
	} else if (ctx != nil) {
		# Mock inference via llambo module
		req := ref InferenceRequest;
		req.prompt = prompt;
		req.max_tokens = max_tokens;
		req.temperature = 0.7;
		req.top_p = 0.9;
		req.ctx = ctx;
		req.required_type = "";

		response := llambo->infer(req);
		if (response != nil) {
			result_text = response.text;
			token_count = response.token_count;
		} else {
			result_text = "Error: inference failed";
			ok = 0;
		}
	} else {
		result_text = "Error: no inference engine available";
		ok = 0;
	}

	elapsed := sys->millisec() - start_time;
	worker_status = WORKER_IDLE;

	if (ok > 0) {
		total_processed++;
		fprint(stdout,
		       "{\"status\":\"ok\",\"text\":\"%s\",\"token_count\":%d,\"time_ms\":%d}\n",
		       escape_for_json(result_text), token_count, elapsed);
	} else {
		total_errors++;
		fprint(stdout, "{\"status\":\"error\",\"message\":\"%s\"}\n",
		       escape_for_json(result_text));
	}
}
