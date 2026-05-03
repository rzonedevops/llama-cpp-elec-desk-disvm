implement Llambo;

include "sys.m";
	sys: Sys;
	print, fprint, sprint: import sys;

include "draw.m";
	draw: Draw;

include "string.m";
	str: String;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "rand.m";
	rand: Rand;

include "llambo.m";

# ---- Global state -------------------------------------------------------

initialized := 0;
model_cache: list of ref Model;

# Heartbeat timeout before marking a node unhealthy (30 s)
HEARTBEAT_TIMEOUT: con 30000;
# Health-check goroutine interval (5 s)
HEALTH_CHECK_INTERVAL: con 5000;
# Auto-scale goroutine interval (10 s)
AUTOSCALE_INTERVAL: con 10000;

# ---- init ---------------------------------------------------------------

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	str = load String String->PATH;
	bufio = load Bufio Bufio->PATH;
	rand = load Rand Rand->PATH;

	if (rand != nil)
		rand->init(sys->millisec());

	initialized = 1;
	model_cache = nil;

	print("llambo: distributed llama.cpp inference module initialized\n");
}

# ---- ModelParams --------------------------------------------------------

ModelParams.default(): ref ModelParams
{
	params := ref ModelParams;
	params.use_mmap = 1;
	params.use_mlock = 1;
	params.n_gpu_layers = 0;
	params.vocab_only = 0;
	return params;
}

# ---- Model --------------------------------------------------------------

Model.load(path: string, params: ref ModelParams): ref Model
{
	if (params == nil)
		params = ModelParams.default();

	model := ref Model;
	model.path = path;
	model.ctx_size = 2048;
	model.n_threads = 4;
	model.params = params;

	model_cache = model :: model_cache;
	print("llambo: loaded model from " + path + "\n");
	return model;
}

Model.free(m: self ref Model)
{
	if (m == nil)
		return;

	newcache: list of ref Model;
	for (ml := model_cache; ml != nil; ml = tl ml) {
		if (hd ml != m)
			newcache = hd ml :: newcache;
	}
	model_cache = newcache;
	print("llambo: freed model " + m.path + "\n");
}

# ---- Context ------------------------------------------------------------

Context.new(model: ref Model, n_ctx: int, n_batch: int, n_threads: int): ref Context
{
	if (model == nil)
		return nil;

	ctx := ref Context;
	ctx.model = model;
	ctx.n_ctx = n_ctx;
	ctx.n_batch = n_batch;
	ctx.n_threads = n_threads;
	return ctx;
}

Context.free(ctx: self ref Context)
{
	if (ctx == nil)
		return;
	ctx.model = nil;
}

# ---- Tokenization -------------------------------------------------------

tokenize(ctx: ref Context, text: string): array of ref Token
{
	if (ctx == nil || text == nil)
		return array[0] of ref Token;

	words := str->unquoted(text);
	tokens := array[len words] of ref Token;
	for (i := 0; i < len words; i++) {
		token := ref Token;
		token.id = i;
		token.text = words[i];
		token.logit = 0.0;
		tokens[i] = token;
	}
	return tokens;
}

detokenize(ctx: ref Context, tokens: array of ref Token): string
{
	if (ctx == nil || tokens == nil || len tokens == 0)
		return "";

	result := "";
	for (i := 0; i < len tokens; i++) {
		if (i > 0)
			result += " ";
		result += tokens[i].text;
	}
	return result;
}

# ---- Core inference (mock; real inference via llambo-ffi) ---------------

infer(req: ref InferenceRequest): ref InferenceResponse
{
	if (req == nil || req.ctx == nil)
		return nil;

	start_time := sys->millisec();
	tokens := tokenize(req.ctx, req.prompt);

	response := ref InferenceResponse;
	response.text = "[llambo: " + req.prompt +
	                " | echo - connect FFI bridge for real inference]";
	response.tokens = tokens;
	response.token_count = len tokens;
	response.completion_time = sys->millisec() - start_time;
	return response;
}

# ---- Worker goroutine (one per ClusterNode) -----------------------------
# Receives InferenceRequests via req_chan, replies via resp_chan.
# A nil request is the shutdown signal.

node_worker(node: ref ClusterNode)
{
	# Fork a new namespace so this worker is isolated
	sys->pctl(Sys->NEWPGRP | Sys->FORKNS, nil);

	# Pre-load model for this worker (addr stores model path in channel workers)
	model := Model.load(node.addr, nil);
	ctx: ref Context;
	if (model != nil)
		ctx = Context.new(model, 2048, 512, 4);

	node.last_heartbeat = sys->millisec();

	for (;;) {
		req := <-node.req_chan;
		if (req == nil)
			break;  # shutdown signal

		if (node.draining) {
			node.resp_chan <-= nil;
			continue;
		}

		node.status = 1;   # busy
		node.load++;

		if (req.ctx == nil && ctx != nil)
			req.ctx = ctx;

		response := infer(req);

		node.load--;
		if (node.load < 0)
			node.load = 0;
		node.status = 0;   # idle
		node.last_heartbeat = sys->millisec();

		node.resp_chan <-= response;
	}

	if (ctx != nil) ctx.free();
	if (model != nil) model.free();
	node.status = 2;  # terminated
}

# ---- ClusterNode --------------------------------------------------------

ClusterNode.spawn(addr: string, capacity: int, model_type: string): ref ClusterNode
{
	node := ref ClusterNode;
	node.id = model_type + "-" + string sys->millisec() + "-" + string capacity;
	node.addr = addr;
	node.capacity = capacity;
	node.load = 0;
	node.status = 0;
	node.model_type = model_type;
	node.draining = 0;
	node.last_heartbeat = sys->millisec();
	node.error_count = 0;

	node.req_chan = chan of ref InferenceRequest;
	node.resp_chan = chan of ref InferenceResponse;

	spawn node_worker(node);

	print("llambo: spawned " + model_type + " node " + node.id + "\n");
	return node;
}

ClusterNode.shutdown(node: self ref ClusterNode)
{
	if (node == nil)
		return;

	node.draining = 1;

	# Wait up to 5 s for in-flight requests to drain
	deadline := sys->millisec() + 5000;
	while (node.load > 0 && sys->millisec() < deadline)
		sys->sleep(100);

	# Send shutdown signal to worker
	if (node.req_chan != nil)
		node.req_chan <-= nil;

	node.status = 2;
	print("llambo: shutdown node " + node.id + "\n");
}

ClusterNode.submit(node: self ref ClusterNode, req: ref InferenceRequest): ref InferenceResponse
{
	if (node == nil || req == nil)
		return nil;
	if (node.status == 2 || node.draining)
		return nil;

	if (node.req_chan != nil && node.resp_chan != nil) {
		node.req_chan <-= req;
		resp := <-node.resp_chan;
		if (resp == nil)
			node.error_count++;
		return resp;
	}

	# Fallback: synchronous in-process inference
	oldstatus := node.status;
	node.status = 1;
	node.load++;
	response := infer(req);
	node.load--;
	node.status = oldstatus;
	node.last_heartbeat = sys->millisec();
	return response;
}

# ---- LoadBalancer -------------------------------------------------------

LoadBalancer.new(strategy: int): ref LoadBalancer
{
	lb := ref LoadBalancer;
	lb.nodes = array[0] of ref ClusterNode;
	lb.strategy = strategy;
	lb.rr_index = 0;
	lb.max_retries = 3;
	print("llambo: load balancer strategy=" + string strategy + "\n");
	return lb;
}

LoadBalancer.register(lb: self ref LoadBalancer, node: ref ClusterNode)
{
	if (lb == nil || node == nil)
		return;
	newnodes := array[len lb.nodes + 1] of ref ClusterNode;
	newnodes[0:] = lb.nodes;
	newnodes[len lb.nodes] = node;
	lb.nodes = newnodes;
}

LoadBalancer.unregister(lb: self ref LoadBalancer, nodeid: string)
{
	if (lb == nil)
		return;
	count := 0;
	for (i := 0; i < len lb.nodes; i++)
		if (lb.nodes[i].id != nodeid)
			count++;
	newnodes := array[count] of ref ClusterNode;
	j := 0;
	for (i := 0; i < len lb.nodes; i++)
		if (lb.nodes[i].id != nodeid)
			newnodes[j++] = lb.nodes[i];
	lb.nodes = newnodes;
}

# Helper: select best node matching a required model type (cognitive-affinity)
select_by_affinity(lb: ref LoadBalancer, req: ref InferenceRequest): ref ClusterNode
{
	if (lb == nil || req == nil || req.required_type == "")
		return nil;
	best: ref ClusterNode;
	minload := 1000000;
	for (i := 0; i < len lb.nodes; i++) {
		n := lb.nodes[i];
		if (n.status == 2 || n.draining) continue;
		if (n.model_type != req.required_type) continue;
		if (n.load < minload) {
			minload = n.load;
			best = n;
		}
	}
	return best;
}

LoadBalancer.balance(lb: self ref LoadBalancer, req: ref InferenceRequest): ref InferenceResponse
{
	if (lb == nil || req == nil || len lb.nodes == 0)
		return nil;

	for (attempt := 0; attempt < lb.max_retries; attempt++) {
		node: ref ClusterNode;

		case lb.strategy {
		0 =>  # round-robin — fixed cursor, skip unhealthy nodes
			for (tries := 0; tries < len lb.nodes; tries++) {
				idx := lb.rr_index % len lb.nodes;
				lb.rr_index++;
				c := lb.nodes[idx];
				if (c.status != 2 && !c.draining) {
					node = c;
					break;
				}
			}

		1 =>  # least-loaded — prefer idle, fallback to minimum load/capacity ratio
			minload := 1000000;
			best_ratio := 1000000;
			for (i := 0; i < len lb.nodes; i++) {
				n := lb.nodes[i];
				if (n.status == 2 || n.draining) continue;
				if (n.status == 0 && n.load < minload) {
					minload = n.load;
					node = n;
				}
			}
			if (node == nil) {
				for (i := 0; i < len lb.nodes; i++) {
					n := lb.nodes[i];
					if (n.status == 2 || n.draining || n.capacity <= 0) continue;
					ratio := (n.load * 1000) / n.capacity;
					if (ratio < best_ratio) {
						best_ratio = ratio;
						node = n;
					}
				}
			}

		2 =>  # random — among healthy nodes
			healthy := array[len lb.nodes] of ref ClusterNode;
			nh := 0;
			for (i := 0; i < len lb.nodes; i++)
				if (lb.nodes[i].status != 2 && !lb.nodes[i].draining)
					healthy[nh++] = lb.nodes[i];
			if (nh > 0) {
				idx := 0;
				if (rand != nil)
					idx = rand->rand(nh);
				else
					idx = sys->millisec() % nh;
				node = healthy[idx];
			}

		3 =>  # cognitive-affinity — route by model type, then least-loaded
			node = select_by_affinity(lb, req);
			if (node == nil) {
				minload := 1000000;
				for (i := 0; i < len lb.nodes; i++) {
					n := lb.nodes[i];
					if (n.status == 2 || n.draining) continue;
					if (n.load < minload) {
						minload = n.load;
						node = n;
					}
				}
			}
		}

		if (node == nil)
			return nil;

		response := node.submit(req);
		if (response != nil)
			return response;

		# Node failed — increment error count and retry
		node.error_count++;
	}
	return nil;
}

LoadBalancer.getstats(lb: self ref LoadBalancer): string
{
	if (lb == nil)
		return "no balancer";

	stats := "LoadBalancer Stats:\n";
	stats += "  Nodes: " + string len lb.nodes + "\n";
	stats += "  Strategy: ";
	case lb.strategy {
	0 => stats += "round-robin\n";
	1 => stats += "least-loaded\n";
	2 => stats += "random\n";
	3 => stats += "cognitive-affinity\n";
	* => stats += "unknown\n";
	}

	idle := 0; busy := 0; errors := 0;
	for (i := 0; i < len lb.nodes; i++) {
		case lb.nodes[i].status {
		0 => idle++;
		1 => busy++;
		2 => errors++;
		}
	}
	stats += "  Idle: " + string idle + "\n";
	stats += "  Busy: " + string busy + "\n";
	stats += "  Error/Shutdown: " + string errors + "\n";
	return stats;
}

LoadBalancer.health_check(lb: self ref LoadBalancer)
{
	if (lb == nil)
		return;
	now := sys->millisec();
	for (i := 0; i < len lb.nodes; i++) {
		node := lb.nodes[i];
		if (node == nil || node.status == 2) continue;
		# Mark as unhealthy if stuck busy beyond heartbeat timeout
		if (node.status == 1 && now - node.last_heartbeat > HEARTBEAT_TIMEOUT) {
			node.status = 2;
			node.error_count++;
			print("llambo: health_check: node " + node.id + " timed out\n");
		}
	}
}

# ---- Background goroutines ----------------------------------------------

health_monitor(orch: ref Orchestrator)
{
	for (;;) {
		sys->sleep(HEALTH_CHECK_INTERVAL);
		if (orch != nil && orch.balancer != nil)
			orch.balancer.health_check();
	}
}

auto_scale_monitor(orch: ref Orchestrator)
{
	for (;;) {
		sys->sleep(AUTOSCALE_INTERVAL);
		if (orch == nil || orch.active_nodes <= 0)
			continue;

		utilization := real orch.pending_requests / real orch.active_nodes;

		if (utilization > orch.scale_up_threshold && orch.active_nodes < orch.max_nodes) {
			new_count := int (real orch.active_nodes * 1.5);
			if (new_count > orch.max_nodes)
				new_count = orch.max_nodes;
			delta := new_count - orch.active_nodes;
			if (delta > 0 && orch.default_model_path != "") {
				print("llambo: auto-scale up +" + string delta + " nodes\n");
				orch.spawn_cluster(delta, orch.default_model_path);
			}
		} else if (utilization < orch.scale_down_threshold && orch.active_nodes > orch.min_nodes_scale) {
			new_count := int (real orch.active_nodes * 0.8);
			if (new_count < orch.min_nodes_scale)
				new_count = orch.min_nodes_scale;
			if (new_count < orch.active_nodes) {
				print("llambo: auto-scale down to " + string new_count + " nodes\n");
				orch.scale_to(new_count);
			}
		}
	}
}

# ---- Orchestrator -------------------------------------------------------

Orchestrator.new(max_nodes: int, strategy: int): ref Orchestrator
{
	orch := ref Orchestrator;
	orch.balancer = LoadBalancer.new(strategy);
	orch.max_nodes = max_nodes;
	orch.active_nodes = 0;
	orch.total_requests = 0;
	orch.pending_requests = 0;
	orch.scale_up_threshold = 0.8;
	orch.scale_down_threshold = 0.2;
	orch.min_nodes_scale = 1;
	orch.default_model_path = "";

	spawn health_monitor(orch);
	spawn auto_scale_monitor(orch);

	print("llambo: orchestrator created max_nodes=" + string max_nodes + "\n");
	return orch;
}

Orchestrator.spawn_cluster(orch: self ref Orchestrator, count: int, model_path: string): int
{
	if (orch == nil || count <= 0)
		return 0;

	available := orch.max_nodes - orch.active_nodes;
	if (count > available)
		count = available;
	if (count <= 0)
		return 0;

	if (model_path != "")
		orch.default_model_path = model_path;

	spawned := 0;
	for (i := 0; i < count; i++) {
		# Infer node type from requested count
		model_type := "medium";
		if (count >= 100)
			model_type = "tiny";
		else if (count <= 10)
			model_type = "large";

		addr := "tcp!localhost!" + string (9000 + orch.active_nodes + i);
		node := ClusterNode.spawn(addr, 100, model_type);
		if (node != nil) {
			orch.balancer.register(node);
			orch.active_nodes++;
			spawned++;
		}
	}
	print("llambo: spawned " + string spawned + " nodes (total=" + string orch.active_nodes + ")\n");
	return spawned;
}

Orchestrator.scale_to(orch: self ref Orchestrator, target: int)
{
	if (orch == nil)
		return;

	current := orch.active_nodes;
	if (target > current) {
		delta := target - current;
		if (orch.default_model_path != "")
			orch.spawn_cluster(delta, orch.default_model_path);
	} else if (target < current && orch.balancer != nil) {
		to_remove := current - target;
		removed := 0;
		for (i := len orch.balancer.nodes - 1; i >= 0 && removed < to_remove; i--) {
			node := orch.balancer.nodes[i];
			if (node == nil || node.status == 2) continue;
			# Wait for node to become idle (up to 10 s)
			deadline := sys->millisec() + 10000;
			while (node.load > 0 && sys->millisec() < deadline)
				sys->sleep(100);
			node.shutdown();
			orch.active_nodes--;
			removed++;
		}
		print("llambo: scale_to removed " + string removed + " nodes\n");
	}
}

Orchestrator.shutdown_cluster(orch: self ref Orchestrator)
{
	if (orch == nil || orch.balancer == nil)
		return;

	for (i := 0; i < len orch.balancer.nodes; i++) {
		if (orch.balancer.nodes[i] != nil)
			orch.balancer.nodes[i].shutdown();
	}

	orch.active_nodes = 0;
	orch.balancer.nodes = array[0] of ref ClusterNode;
	print("llambo: cluster shutdown complete\n");
}

Orchestrator.process(orch: self ref Orchestrator, prompt: string, max_tokens: int): ref InferenceResponse
{
	if (orch == nil || orch.balancer == nil)
		return nil;

	orch.total_requests++;
	orch.pending_requests++;

	req := ref InferenceRequest;
	req.prompt = prompt;
	req.max_tokens = max_tokens;
	req.temperature = 0.7;
	req.top_p = 0.9;
	req.required_type = "";
	req.ctx = nil;

	# For nodes without channel workers, supply a context
	if (len orch.balancer.nodes > 0) {
		node := orch.balancer.nodes[0];
		if (node != nil && node.req_chan == nil) {
			model := Model.load(orch.default_model_path, nil);
			ctx := Context.new(model, 2048, 512, 4);
			req.ctx = ctx;
		}
	}

	response := orch.balancer.balance(req);

	orch.pending_requests--;
	if (orch.pending_requests < 0)
		orch.pending_requests = 0;

	if (req.ctx != nil)
		req.ctx.free();

	return response;
}

Orchestrator.status(orch: self ref Orchestrator): string
{
	if (orch == nil)
		return "no orchestrator";

	utilization := 0.0;
	if (orch.active_nodes > 0)
		utilization = real orch.pending_requests / real orch.active_nodes;

	status := "Orchestrator Status:\n";
	status += "  Max nodes:        " + string orch.max_nodes + "\n";
	status += "  Active nodes:     " + string orch.active_nodes + "\n";
	status += "  Total requests:   " + string orch.total_requests + "\n";
	status += "  Pending requests: " + string orch.pending_requests + "\n";
	status += "  Utilization:      " + sprint("%.2f", utilization) + "\n";
	status += "  Scale up @:       " + sprint("%.1f", orch.scale_up_threshold) + "\n";
	status += "  Scale down @:     " + sprint("%.1f", orch.scale_down_threshold) + "\n";
	status += "  Default model:    " + orch.default_model_path + "\n";

	if (orch.balancer != nil)
		status += "\n" + orch.balancer.getstats();

	return status;
}

# ---- Persistent state ---------------------------------------------------

Orchestrator.save_state(orch: self ref Orchestrator, path: string)
{
	if (orch == nil || path == "")
		return;

	fd := sys->create(path, Sys->OWRITE, 8r644);
	if (fd == nil) {
		print("llambo: save_state: cannot create " + path + "\n");
		return;
	}

	fprint(fd, "{\n");
	fprint(fd, "  \"version\": 1,\n");
	fprint(fd, "  \"timestamp\": %d,\n", sys->millisec());
	fprint(fd, "  \"active_nodes\": %d,\n", orch.active_nodes);
	fprint(fd, "  \"max_nodes\": %d,\n", orch.max_nodes);
	fprint(fd, "  \"total_requests\": %d,\n", orch.total_requests);
	fprint(fd, "  \"default_model_path\": \"%s\",\n", orch.default_model_path);
	fprint(fd, "  \"nodes\": [\n");

	if (orch.balancer != nil) {
		first := 1;
		for (i := 0; i < len orch.balancer.nodes; i++) {
			node := orch.balancer.nodes[i];
			if (node == nil || node.status == 2) continue;
			if (!first)
				fprint(fd, ",\n");
			first = 0;
			fprint(fd, "    {\"id\":\"%s\",\"addr\":\"%s\",\"model_type\":\"%s\",\"capacity\":%d,\"load\":%d,\"status\":%d}",
				node.id, node.addr, node.model_type, node.capacity, node.load, node.status);
		}
		if (!first)
			fprint(fd, "\n");
	}

	fprint(fd, "  ]\n");
	fprint(fd, "}\n");
	print("llambo: state saved to " + path + "\n");
}

Orchestrator.load_state(orch: self ref Orchestrator, path: string): int
{
	if (orch == nil || path == "")
		return 0;

	fd := sys->open(path, Sys->OREAD);
	if (fd == nil) {
		print("llambo: load_state: cannot open " + path + "\n");
		return 0;
	}

	bio := bufio->fopen(fd, Bufio->OREAD);
	if (bio == nil)
		return 0;

	restored := 0;

	for (;;) {
		line := bio.gets('\n');
		if (line == nil) break;
		if (len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];

		# Parse node entries: look for "addr":"..."
		addr_key := "\"addr\":\"";
		addr_idx := str->in(addr_key, line);
		if (addr_idx < 0) continue;

		start := addr_idx + len addr_key;
		end := start;
		while (end < len line && line[end] != '"')
			end++;
		if (end >= len line) continue;
		addr := line[start:end];

		# Extract model_type
		type_key := "\"model_type\":\"";
		type_idx := str->in(type_key, line);
		model_type := "medium";
		if (type_idx >= 0) {
			start = type_idx + len type_key;
			end = start;
			while (end < len line && line[end] != '"')
				end++;
			if (end < len line)
				model_type = line[start:end];
		}

		# Extract capacity
		cap_key := "\"capacity\":";
		cap_idx := str->in(cap_key, line);
		capacity := 100;
		if (cap_idx >= 0) {
			start = cap_idx + len cap_key;
			end = start;
			while (end < len line && line[end] >= '0' && line[end] <= '9')
				end++;
			if (end > start)
				capacity = int line[start:end];
		}

		if (addr != "") {
			node := ClusterNode.spawn(addr, capacity, model_type);
			if (node != nil) {
				orch.balancer.register(node);
				orch.active_nodes++;
				restored++;
			}
		}
	}

	# Restore default_model_path
	fd2 := sys->open(path, Sys->OREAD);
	if (fd2 != nil) {
		bio2 := bufio->fopen(fd2, Bufio->OREAD);
		if (bio2 != nil) {
			for (;;) {
				line := bio2.gets('\n');
				if (line == nil) break;
				mkey := "\"default_model_path\":\"";
				midx := str->in(mkey, line);
				if (midx >= 0) {
					s := midx + len mkey;
					e := s;
					while (e < len line && line[e] != '"')
						e++;
					if (e < len line)
						orch.default_model_path = line[s:e];
					break;
				}
			}
		}
	}

	if (restored > 0)
		print("llambo: restored " + string restored + " nodes from " + path + "\n");
	return restored;
}

# ---- Cognitive Fusion ---------------------------------------------------

CognitiveFusion.new(strategy: int, min_nodes: int, timeout_ms: int): ref CognitiveFusion
{
	cf := ref CognitiveFusion;
	cf.strategy = strategy;
	cf.min_nodes = min_nodes;
	cf.timeout_ms = timeout_ms;
	return cf;
}

# Find the most common string in texts[] (majority vote helper)
majority_text(texts: array of string): string
{
	if (texts == nil || len texts == 0)
		return "";
	best := texts[0];
	best_count := 0;
	for (i := 0; i < len texts; i++) {
		if (texts[i] == nil) continue;
		count := 0;
		for (j := 0; j < len texts; j++)
			if (texts[j] == texts[i])
				count++;
		if (count > best_count) {
			best_count = count;
			best = texts[i];
		}
	}
	return best;
}

# Average token count across valid responses
avg_token_count(responses: array of ref InferenceResponse): int
{
	total := 0; cnt := 0;
	for (i := 0; i < len responses; i++)
		if (responses[i] != nil) { total += responses[i].token_count; cnt++; }
	if (cnt == 0) return 0;
	return total / cnt;
}

CognitiveFusion.fuse(cf: self ref CognitiveFusion, responses: array of ref InferenceResponse): ref InferenceResponse
{
	if (cf == nil || responses == nil || len responses == 0)
		return nil;

	# Count valid responses
	valid := 0;
	for (i := 0; i < len responses; i++)
		if (responses[i] != nil) valid++;
	if (valid == 0) return nil;
	if (valid == 1) {
		for (i := 0; i < len responses; i++)
			if (responses[i] != nil) return responses[i];
	}

	case cf.strategy {
	0 =>  # weighted-average: response closest to average token count
		avg := avg_token_count(responses);
		best: ref InferenceResponse;
		best_diff := 1000000;
		for (i := 0; i < len responses; i++) {
			if (responses[i] == nil) continue;
			diff := responses[i].token_count - avg;
			if (diff < 0) diff = -diff;
			if (diff < best_diff) { best_diff = diff; best = responses[i]; }
		}
		return best;

	1 =>  # majority-vote: most common response text
		texts := array[len responses] of string;
		for (i := 0; i < len responses; i++)
			texts[i] = (responses[i] != nil) ? responses[i].text : "";
		chosen := majority_text(texts);
		for (i := 0; i < len responses; i++)
			if (responses[i] != nil && responses[i].text == chosen)
				return responses[i];

	2 =>  # confidence-weighted: fastest response (lower latency = higher confidence)
		best: ref InferenceResponse;
		best_time := 1000000;
		for (i := 0; i < len responses; i++) {
			if (responses[i] == nil) continue;
			if (responses[i].completion_time < best_time) {
				best_time = responses[i].completion_time;
				best = responses[i];
			}
		}
		return best;

	3 =>  # raft-consensus: require cf.min_nodes to agree
		for (i := 0; i < len responses; i++) {
			if (responses[i] == nil) continue;
			agree := 0;
			for (j := 0; j < len responses; j++)
				if (responses[j] != nil && responses[j].text == responses[i].text)
					agree++;
			if (agree >= cf.min_nodes)
				return responses[i];
		}
		# No quorum: return most-agreed response
		best: ref InferenceResponse;
		best_count := 0;
		for (i := 0; i < len responses; i++) {
			if (responses[i] == nil) continue;
			count := 0;
			for (j := 0; j < len responses; j++)
				if (responses[j] != nil && responses[j].text == responses[i].text)
					count++;
			if (count > best_count) { best_count = count; best = responses[i]; }
		}
		return best;
	}

	# Default: first valid response
	for (i := 0; i < len responses; i++)
		if (responses[i] != nil) return responses[i];
	return nil;
}

# Helper goroutine for parallel fan-out in infer_fusion
dispatch_to_node(node: ref ClusterNode, req: ref InferenceRequest, out: chan of ref InferenceResponse)
{
	resp := node.submit(req);
	out <-= resp;
}

# infer_fusion: dispatch to n_nodes in parallel, fuse results
infer_fusion(orch: ref Orchestrator, prompt: string, n_nodes: int, strategy: int): ref InferenceResponse
{
	if (orch == nil || orch.balancer == nil || len orch.balancer.nodes == 0)
		return nil;

	n := n_nodes;
	if (n > len orch.balancer.nodes)
		n = len orch.balancer.nodes;
	if (n <= 0)
		return nil;

	req := ref InferenceRequest;
	req.prompt = prompt;
	req.max_tokens = 128;
	req.temperature = 0.7;
	req.top_p = 0.9;
	req.required_type = "";
	req.ctx = nil;

	result_chans := array[n] of chan of ref InferenceResponse;
	for (i := 0; i < n; i++) {
		result_chans[i] = chan of ref InferenceResponse;
		node_idx := i % len orch.balancer.nodes;
		spawn dispatch_to_node(orch.balancer.nodes[node_idx], req, result_chans[i]);
	}

	responses := array[n] of ref InferenceResponse;
	for (i := 0; i < n; i++)
		responses[i] = <-result_chans[i];

	min_consensus := (n + 1) / 2;
	cf := CognitiveFusion.new(strategy, min_consensus, 30000);
	return cf.fuse(responses);
}
