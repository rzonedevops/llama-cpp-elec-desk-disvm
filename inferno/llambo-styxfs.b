implement LlamboStyxFS;

# LlamboStyxFS: Cluster control namespace for Inferno's distributed shell.
# Creates a file-based control interface at /n/llambo/ providing:
#
#   /n/llambo/ctl       — write commands; read last response
#   /n/llambo/status    — read cluster status (JSON)
#   /n/llambo/metrics   — read Prometheus-format metrics
#   /n/llambo/nodes/    — per-node stats (one file each)
#   /n/llambo/fusion/   — cognitive fusion result staging area
#
# A control loop polls ctl every 100 ms and refreshes status/metrics every 5 s.
# Commands written to ctl (one per line):
#   status              — refresh status file
#   metrics             — refresh metrics file
#   spawn [--count N] [--type T] [--model PATH]
#   scale <N>           — scale cluster to N nodes
#   infer <prompt>      — run inference; result written to fusion/last-result
#   shutdown            — shutdown all cluster nodes

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
	Orchestrator: import llambo;

LlamboStyxFS: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

# Namespace paths
NS_ROOT   : con "/n/llambo";
CTL_FILE  : con "/n/llambo/ctl";
STATUS_FILE  : con "/n/llambo/status";
METRICS_FILE : con "/n/llambo/metrics";
NODES_DIR    : con "/n/llambo/nodes";
FUSION_DIR   : con "/n/llambo/fusion";

# Refresh interval (ms)
UPDATE_INTERVAL : con 5000;
POLL_INTERVAL   : con 100;

orch: ref Orchestrator;

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	llambo = load Llambo Llambo->PATH;

	if (llambo == nil) {
		print("llambo-styxfs: cannot load Llambo module\n");
		raise "fail:load";
	}
	llambo->init(ctxt, nil);

	# Parse optional --nodes and --model arguments
	init_count := 0;
	model_path := "/models/llama-7b.gguf";
	args := argv;
	if (args != nil) args = tl args;
	while (args != nil) {
		arg := hd args; args = tl args;
		if (arg == "--nodes" && args != nil) {
			init_count = int hd args; args = tl args;
		} else if (arg == "--model" && args != nil) {
			model_path = hd args; args = tl args;
		}
	}

	print("llambo-styxfs: initializing cluster filesystem at " + NS_ROOT + "\n");
	setup_namespace();

	# Initialize orchestrator and optionally spawn initial cluster
	orch = llambo->Orchestrator.new(10000, 1);
	if (init_count > 0) {
		n := orch.spawn_cluster(init_count, model_path);
		print("llambo-styxfs: spawned " + string n + " initial nodes\n");
	}

	print("llambo-styxfs: filesystem ready\n");
	print("  ctl:     " + CTL_FILE + "\n");
	print("  status:  " + STATUS_FILE + "\n");
	print("  metrics: " + METRICS_FILE + "\n");
	print("  nodes:   " + NODES_DIR + "/\n");

	control_loop();
}

setup_namespace()
{
	sys->create(NS_ROOT,    Sys->OREAD, 8r755 | Sys->DMDIR);
	sys->create(NODES_DIR,  Sys->OREAD, 8r755 | Sys->DMDIR);
	sys->create(FUSION_DIR, Sys->OREAD, 8r755 | Sys->DMDIR);

	# Write initial marker to ctl so readers see "ready" until a real command arrives
	fd := sys->create(CTL_FILE, Sys->OWRITE, 8r644);
	if (fd != nil)
		fprint(fd, "ready\n");

	update_status();
	update_metrics();
}

update_status()
{
	fd := sys->create(STATUS_FILE, Sys->OWRITE, 8r644);
	if (fd == nil) return;
	if (orch != nil)
		fprint(fd, "%s\n", orch.status());
	else
		fprint(fd, "{\"status\":\"not-initialized\"}\n");
}

update_metrics()
{
	fd := sys->create(METRICS_FILE, Sys->OWRITE, 8r644);
	if (fd == nil) return;

	if (orch != nil) {
		fprint(fd, "# HELP llambo_active_nodes Active cluster nodes\n");
		fprint(fd, "# TYPE llambo_active_nodes gauge\n");
		fprint(fd, "llambo_active_nodes %d\n", orch.active_nodes);
		fprint(fd, "# HELP llambo_pending_requests Pending inference requests\n");
		fprint(fd, "# TYPE llambo_pending_requests gauge\n");
		fprint(fd, "llambo_pending_requests %d\n", orch.pending_requests);
		fprint(fd, "# HELP llambo_total_requests Total inference requests\n");
		fprint(fd, "# TYPE llambo_total_requests counter\n");
		fprint(fd, "llambo_total_requests %d\n", orch.total_requests);
		fprint(fd, "# HELP llambo_max_nodes Maximum configured nodes\n");
		fprint(fd, "# TYPE llambo_max_nodes gauge\n");
		fprint(fd, "llambo_max_nodes %d\n", orch.max_nodes);
	} else {
		fprint(fd, "# llambo metrics unavailable (no orchestrator)\n");
	}
}

register_node_file(node_id: string, model_type: string, capacity: int, load: int, status: int)
{
	fd := sys->create(NODES_DIR + "/" + node_id, Sys->OWRITE, 8r644);
	if (fd == nil) return;
	fprint(fd, "{\"id\":\"%s\",\"model_type\":\"%s\",\"capacity\":%d,\"load\":%d,\"status\":%d}\n",
	       node_id, model_type, capacity, load, status);
}

# Main control loop: polls ctl for commands, refreshes status/metrics periodically
control_loop()
{
	last_update := sys->millisec();
	prev_ctl := "ready";

	for (;;) {
		sys->sleep(POLL_INTERVAL);

		# Periodic refresh
		now := sys->millisec();
		if (now - last_update >= UPDATE_INTERVAL) {
			update_status();
			update_metrics();
			last_update = now;
		}

		# Check for a new command in ctl
		fd := sys->open(CTL_FILE, Sys->OREAD);
		if (fd == nil) continue;
		bio := bufio->fopen(fd, Bufio->OREAD);
		if (bio == nil) continue;

		line := bio.gets('\n');
		if (line == nil) continue;
		if (len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];

		# Only process if the line has changed from last time
		if (line == "" || line == prev_ctl) continue;
		prev_ctl = line;

		if (line == "ready") continue;

		# Process command and reset ctl to "ready"
		process_ctl_command(line);
		reset_ctl();
	}
}

reset_ctl()
{
	fd := sys->create(CTL_FILE, Sys->OWRITE, 8r644);
	if (fd != nil)
		fprint(fd, "ready\n");
}

process_ctl_command(cmd: string)
{
	(n, args) := sys->tokenize(cmd, " \t");
	if (n == 0) return;

	command := hd args;
	args = tl args;

	case command {
	"status" =>
		update_status();

	"metrics" =>
		update_metrics();

	"spawn" =>
		count := 10;
		model_path := "/models/llama-7b.gguf";
		model_type := "medium";
		while (args != nil) {
			a := hd args; args = tl args;
			if (a == "--count" && args != nil) {
				count = int hd args; args = tl args;
			} else if (a == "--model" && args != nil) {
				model_path = hd args; args = tl args;
			} else if (a == "--type" && args != nil) {
				model_type = hd args; args = tl args;
			}
		}
		if (orch != nil) {
			spawned := orch.spawn_cluster(count, model_path);
			print("llambo-styxfs: spawned " + string spawned + " nodes\n");
			update_status();
		}

	"scale" =>
		target := 0;
		if (args != nil) target = int hd args;
		if (orch != nil && target > 0) {
			orch.scale_to(target);
			update_status();
		}

	"save" =>
		path := "/var/llambo/cluster-state.json";
		if (args != nil) path = hd args;
		if (orch != nil) orch.save_state(path);

	"restore" =>
		path := "/var/llambo/cluster-state.json";
		if (args != nil) path = hd args;
		if (orch != nil) {
			n := orch.load_state(path);
			print("llambo-styxfs: restored " + string n + " nodes from " + path + "\n");
			update_status();
		}

	"infer" =>
		if (args == nil || orch == nil) return;
		prompt := str->join(args, " ");
		response := orch.process(prompt, 256);
		fd := sys->create(FUSION_DIR + "/last-result", Sys->OWRITE, 8r644);
		if (fd != nil)
			fprint(fd, "%s\n",
			       (response != nil) ? response.text : "no response");

	"shutdown" =>
		if (orch != nil) {
			orch.shutdown_cluster();
			update_status();
		}

	* =>
		print("llambo-styxfs: unknown command: " + command + "\n");
	}
}
