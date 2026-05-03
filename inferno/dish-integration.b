implement DishIntegration;

# Inferno Dish (Distributed Shell) Integration for Llambo
# Provides interactive shell access to distributed llama.cpp cluster
#
# Integrates with llambo-styxfs namespace at /n/llambo/ when running.
# Falls back to direct orchestrator calls when namespace is not mounted.

include "sys.m";
	sys: Sys;
	print, fprint, sprint, fildes: import sys;

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
	Orchestrator, InferenceRequest, InferenceResponse: import llambo;

DishIntegration: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

# Namespace paths — set by llambo-styxfs.b
DISH_NS    : con "/n/dish";
LLAMBO_NS  : con "/n/llambo";
CTL_FILE   : con "/n/llambo/ctl";
STATUS_FILE: con "/n/llambo/status";
METRICS_FILE: con "/n/llambo/metrics";
NODES_DIR  : con "/n/llambo/nodes";
FUSION_DIR : con "/n/llambo/fusion";
DATA_FILE  : con "/n/llambo/data";

# Global orchestrator (used when styxfs namespace is not mounted)
orch: ref Orchestrator;
max_nodes_global: int;
use_namespace := 0;  # 1 if /n/llambo is available

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	llambo = load Llambo Llambo->PATH;

	if (llambo == nil) {
		print("Failed to load Llambo module\n");
		raise "fail:load";
	}
	llambo->init(ctxt, nil);

	print("=== Llambo Dish Integration ===\n");
	print("Distributed Shell for Llama.cpp Cluster\n\n");

	# Check if the llambo-styxfs namespace is already mounted
	use_namespace = namespace_available();

	if (use_namespace) {
		print("Namespace " + LLAMBO_NS + " is mounted — using file-based IPC.\n\n");
	} else {
		print("Namespace " + LLAMBO_NS + " not found — starting local orchestrator.\n");
		setup_namespaces();

		max_nodes_global = 1000;
		orch = llambo->Orchestrator.new(max_nodes_global, 1);
		node_count := orch.spawn_cluster(100, "/models/llama-7b.gguf");
		print(sprint("Cluster ready: %d nodes active\n", node_count));

		# Write initial status/ctl files
		write_ctl("ready");
		write_status(orch.status());
	}

	interactive_shell();

	print("\nShutting down cluster...\n");
	if (orch != nil)
		orch.shutdown_cluster();
}

# Return 1 if /n/llambo/ctl exists and is readable
namespace_available(): int
{
	fd := sys->open(CTL_FILE, Sys->OREAD);
	if (fd != nil) {
		fd = nil;
		return 1;
	}
	return 0;
}

# Setup local namespace directories
setup_namespaces()
{
	print("Setting up distributed shell namespaces...\n");
	sys->create(DISH_NS,   Sys->OREAD, 8r755 | Sys->DMDIR);
	sys->create(LLAMBO_NS, Sys->OREAD, 8r755 | Sys->DMDIR);
	sys->create(NODES_DIR, Sys->OREAD, 8r755 | Sys->DMDIR);
	sys->create(FUSION_DIR, Sys->OREAD, 8r755 | Sys->DMDIR);
	print(sprint("  %s -> mounted\n", LLAMBO_NS));
}

# Write a command string to /n/llambo/ctl
write_ctl(cmd: string)
{
	fd := sys->create(CTL_FILE, Sys->OWRITE, 8r644);
	if (fd != nil)
		fprint(fd, "%s\n", cmd);
}

# Write status string to /n/llambo/status
write_status(s: string)
{
	fd := sys->create(STATUS_FILE, Sys->OWRITE, 8r644);
	if (fd != nil)
		fprint(fd, "%s\n", s);
}

# Read a file and return its contents as a string
read_file(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if (fd == nil) return "";
	bio := bufio->fopen(fd, Bufio->OREAD);
	if (bio == nil) return "";
	result := "";
	for (;;) {
		line := bio.gets('\n');
		if (line == nil) break;
		result += line;
	}
	return result;
}

# Interactive shell loop
interactive_shell()
{
	stdin := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if (stdin == nil) {
		print("Failed to open stdin\n");
		return;
	}

	print("\nDistributed Shell Ready. Type 'help' for commands.\n");
	print("llambo> ");

	for (;;) {
		line := stdin.gets('\n');
		if (line == nil) break;
		if (len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		if (len line == 0) { print("llambo> "); continue; }

		process_command(line);
		print("llambo> ");
	}
}

# Process shell commands
process_command(cmd: string)
{
	(n, args) := sys->tokenize(cmd, " \t");
	if (n == 0) return;

	command := hd args;
	args = tl args;

	case command {
	"help" or "?" =>
		show_help();

	"status" =>
		show_status();

	"nodes" =>
		show_nodes();

	"metrics" =>
		show_metrics();

	"infer" or "ask" =>
		if (args == nil) {
			print("Usage: infer <prompt>\n");
		} else {
			prompt := str->join(args, " ");
			do_inference(prompt);
		}

	"scale" =>
		if (args == nil) {
			print("Usage: scale <N>\n");
		} else {
			target := int hd args;
			do_scale(target);
		}

	"save" =>
		path := "/var/llambo/cluster-state.json";
		if (args != nil) path = hd args;
		do_save(path);

	"restore" =>
		path := "/var/llambo/cluster-state.json";
		if (args != nil) path = hd args;
		do_restore(path);

	"cluster" =>
		cluster_commands(args);

	"exit" or "quit" =>
		raise "break";

	* =>
		# Treat unknown input as an inference prompt
		prompt := str->join(command :: args, " ");
		do_inference(prompt);
	}
}

# Show help
show_help()
{
	print("\nLlambo Distributed Shell Commands:\n");
	print("  help, ?                Show this help\n");
	print("  status                 Show cluster status\n");
	print("  nodes                  List cluster nodes\n");
	print("  metrics                Show Prometheus metrics\n");
	print("  infer <prompt>         Run inference\n");
	print("  ask <prompt>           Alias for infer\n");
	print("  scale <N>              Scale cluster to N nodes\n");
	print("  save [path]            Save cluster state\n");
	print("  restore [path]         Restore cluster state\n");
	print("  cluster <cmd>          Cluster management\n");
	print("  exit, quit             Exit shell\n");
	print("\nOr just type your prompt directly!\n\n");
}

# Show cluster status — reads from namespace file when available
show_status()
{
	if (use_namespace) {
		s := read_file(STATUS_FILE);
		if (s != "")
			print("\n" + s + "\n");
		else
			print("Status file unavailable\n");
	} else if (orch != nil) {
		print("\n" + orch.status() + "\n");
	}
}

# Show cluster nodes — lists files in /n/llambo/nodes/
show_nodes()
{
	print("\nCluster nodes:\n");
	if (use_namespace) {
		# In a full implementation, we'd use sys->stat to list NODES_DIR.
		# For now, show a summary from the status file.
		print("  (use 'llamboctl nodes list' for full details)\n");
		print("  Namespace: " + NODES_DIR + "\n\n");
	} else if (orch != nil && orch.balancer != nil) {
		nodes := orch.balancer.nodes;
		for (i := 0; i < len nodes; i++) {
			node := nodes[i];
			status_s := "idle";
			case node.status {
			1 => status_s = "busy";
			2 => status_s = "shutdown";
			}
			print(sprint("  %-24s  %-6s  load=%-3d  type=%s\n",
			       node.id, status_s, node.load, node.model_type));
		}
		print("\n");
	}
}

# Show Prometheus metrics
show_metrics()
{
	if (use_namespace) {
		s := read_file(METRICS_FILE);
		if (s != "")
			print("\n" + s + "\n");
		else
			print("Metrics file unavailable\n");
	} else if (orch != nil) {
		print("\n# llambo inline metrics\n");
		print(sprint("llambo_active_nodes %d\n", orch.active_nodes));
		print(sprint("llambo_total_requests %d\n", orch.total_requests));
		print(sprint("llambo_pending_requests %d\n", orch.pending_requests));
		print("\n");
	}
}

# Run inference — via namespace ctl or direct orchestrator call
do_inference(prompt: string)
{
	if (orch == nil && !use_namespace) {
		print("Error: Cluster not initialized\n");
		return;
	}

	print("\n[Distributing inference across cluster...]\n");

	if (use_namespace) {
		# Write command to ctl and wait for result in fusion/last-result
		write_ctl("infer " + prompt);
		# Wait briefly for result
		sys->sleep(500);
		result := read_file(FUSION_DIR + "/last-result");
		if (result != "")
			print("\n" + result + "\n\n");
		else
			print("(No result yet — try 'status' to check cluster)\n\n");
	} else {
		response := orch.process(prompt, 128);
		if (response == nil) {
			print("Error: Inference failed\n");
			return;
		}
		print(sprint("\n%s\n\n", response.text));
		print(sprint("[Completed in %d ms, %d tokens]\n\n",
		       response.completion_time, response.token_count));
	}
}

# Scale cluster
do_scale(target: int)
{
	if (target <= 0) { print("Invalid node count\n"); return; }

	if (use_namespace) {
		write_ctl("scale " + string target);
		sys->sleep(200);
		print(sprint("Scale-to-%d command sent.\n", target));
	} else if (orch != nil) {
		orch.scale_to(target);
		print(sprint("Scaled to %d nodes.\n", target));
	}
}

# Save cluster state
do_save(path: string)
{
	if (use_namespace) {
		write_ctl("save " + path);
		sys->sleep(200);
		print("Save command sent.\n");
	} else if (orch != nil) {
		orch.save_state(path);
		print("State saved to " + path + "\n");
	}
}

# Restore cluster state
do_restore(path: string)
{
	if (use_namespace) {
		write_ctl("restore " + path);
		sys->sleep(200);
		print("Restore command sent.\n");
	} else if (orch != nil) {
		n := orch.load_state(path);
		print(sprint("Restored %d nodes from %s\n", n, path));
	}
}

# Cluster management commands
cluster_commands(args: list of string)
{
	if (args == nil) {
		print("Cluster commands: info, spawn, shutdown\n");
		return;
	}

	cmd := hd args;
	args = tl args;

	case cmd {
	"info" =>
		print("\nCluster Information:\n");
		if (orch != nil) {
			print(sprint("  Max Nodes:  %d\n", orch.max_nodes));
			print(sprint("  Active:     %d\n", orch.active_nodes));
			print(sprint("  Requests:   %d total, %d pending\n",
			       orch.total_requests, orch.pending_requests));
		}
		print("  Strategy: least-loaded\n\n");

	"spawn" =>
		count := 10;
		model := "/models/llama-7b.gguf";
		while (args != nil) {
			a := hd args; args = tl args;
			if (a == "--count" && args != nil) {
				count = int hd args; args = tl args;
			} else if (a == "--model" && args != nil) {
				model = hd args; args = tl args;
			}
		}
		if (use_namespace) {
			write_ctl(sprint("spawn --count %d --model %s", count, model));
			sys->sleep(200);
			print(sprint("Spawn-%d command sent.\n", count));
		} else if (orch != nil) {
			n := orch.spawn_cluster(count, model);
			print(sprint("Spawned %d nodes.\n", n));
		}

	"shutdown" =>
		print("Use 'exit' to shutdown cluster and exit shell\n");

	* =>
		print("Unknown cluster command: " + cmd + "\n");
	}
}
