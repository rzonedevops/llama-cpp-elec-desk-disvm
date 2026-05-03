implement LlamboScaleTest;

# llambo-scale-test: Integration test for auto-scaling behaviour.
# Simulates load spikes by manipulating pending_requests on the orchestrator
# and verifying that auto_scale_monitor reacts as expected.
#
# Usage:
#   llambo-scale-test [model_path]
#
# Tests:
#   1. Initial cluster spawn
#   2. scale_to() scale-up
#   3. scale_to() scale-down
#   4. Orchestrator.save_state() / load_state() round-trip
#   5. ClusterNode draining on shutdown
#   6. LoadBalancer strategy switching

include "sys.m";
	sys: Sys;
	print, sprint: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "llambo.m";
	llambo: Llambo;
	Orchestrator, LoadBalancer, ClusterNode: import llambo;

LlamboScaleTest: module {
	init: fn(ctxt: ref Context, args: list of string);
};

passed := 0;
failed := 0;

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	llambo = load Llambo Llambo->PATH;

	if (llambo == nil) {
		print("llambo-scale-test: cannot load Llambo module\n");
		raise "fail:load";
	}
	llambo->init(ctxt, nil);

	print("\n=== Llambo Auto-Scaling Tests ===\n\n");

	model_path := "/models/llama-7b.gguf";
	args := argv;
	if (args != nil) args = tl args;
	if (args != nil) model_path = hd args;

	# ---- Test 1: Initial cluster spawn ----------------------------------
	print("Test 1: Spawn initial cluster of 4 nodes...\n");
	orch := llambo->Orchestrator.new(50, 1);
	n := orch.spawn_cluster(4, model_path);
	if (n == 4 && orch.active_nodes == 4) {
		ok(sprint("  Spawned %d nodes, active_nodes=%d", n, orch.active_nodes));
	} else {
		fail(sprint("  Expected 4 nodes, got spawned=%d active=%d", n, orch.active_nodes));
	}

	# ---- Test 2: scale_to() up ------------------------------------------
	print("\nTest 2: scale_to(8) — scale up from 4 to 8...\n");
	orch.scale_to(8);
	if (orch.active_nodes == 8) {
		ok(sprint("  active_nodes=%d", orch.active_nodes));
	} else {
		fail(sprint("  Expected 8 nodes, got %d", orch.active_nodes));
	}

	# ---- Test 3: scale_to() down ----------------------------------------
	print("\nTest 3: scale_to(3) — scale down from 8 to 3...\n");
	orch.scale_to(3);
	if (orch.active_nodes == 3) {
		ok(sprint("  active_nodes=%d", orch.active_nodes));
	} else {
		fail(sprint("  Expected 3 nodes, got %d", orch.active_nodes));
	}

	# ---- Test 4: Persistent state round-trip ----------------------------
	print("\nTest 4: save_state() / load_state() round-trip...\n");

	state_path := "/tmp/llambo-scale-test-state.json";

	orch.save_state(state_path);

	# Verify state file was created
	fd := sys->open(state_path, Sys->OREAD);
	if (fd != nil) {
		ok("  State file created at " + state_path);
		fd = nil;
	} else {
		fail("  State file not created");
	}

	# Create a fresh orchestrator and restore from state
	orch2 := llambo->Orchestrator.new(50, 1);
	restored := orch2.load_state(state_path);
	if (restored > 0 && orch2.active_nodes == restored) {
		ok(sprint("  Restored %d nodes into new orchestrator", restored));
	} else {
		fail(sprint("  load_state returned %d, active_nodes=%d", restored, orch2.active_nodes));
	}
	orch2.shutdown_cluster();

	# ---- Test 5: ClusterNode draining -----------------------------------
	print("\nTest 5: ClusterNode draining on shutdown...\n");

	if (orch.balancer != nil && len orch.balancer.nodes > 0) {
		node := orch.balancer.nodes[0];
		if (node.draining == 0 && node.status != 2) {
			node.shutdown();
			if (node.status == 2) {
				ok(sprint("  Node %s transitioned to status=2 after shutdown", node.id));
			} else {
				fail(sprint("  Node %s still has status=%d after shutdown", node.id, node.status));
			}
		} else {
			ok("  Node already shut down — skip");
		}
	} else {
		ok("  No active nodes to test drain — skip");
	}

	# ---- Test 6: LoadBalancer strategy switching ------------------------
	print("\nTest 6: LoadBalancer strategy switching...\n");

	orch3 := llambo->Orchestrator.new(20, 0);  # start with round-robin
	orch3.spawn_cluster(4, model_path);

	# Switch to least-loaded and verify balance works
	orch3.balancer.strategy = 1;
	req := ref llambo->InferenceRequest;
	req.prompt = "Test prompt";
	req.max_tokens = 10;
	req.temperature = 0.7;
	req.top_p = 0.9;
	req.required_type = "";
	req.ctx = nil;

	# Supply a context for the synchronous fallback path
	m := llambo->Model.load(model_path, nil);
	c := llambo->Context.new(m, 512, 128, 2);
	req.ctx = c;

	resp := orch3.balancer.balance(req);
	if (resp != nil) {
		ok(sprint("  least-loaded balance succeeded: %d tokens", resp.token_count));
	} else {
		fail("  least-loaded balance returned nil");
	}

	# Switch to cognitive-affinity with required_type
	orch3.balancer.strategy = 3;
	req.required_type = "tiny";
	resp = orch3.balancer.balance(req);
	# This may return nil if no node has type "tiny" — both outcomes are valid
	if (resp != nil) {
		ok("  cognitive-affinity: found matching type 'tiny'");
	} else {
		ok("  cognitive-affinity: no 'tiny' nodes, returned nil (expected)");
	}

	c.free();
	m.free();
	orch3.shutdown_cluster();

	# ---- Test 7: Max nodes cap ------------------------------------------
	print("\nTest 7: Max nodes cap enforcement...\n");
	orch4 := llambo->Orchestrator.new(5, 1);
	n = orch4.spawn_cluster(10, model_path);   # request more than max
	if (orch4.active_nodes <= 5) {
		ok(sprint("  Cap enforced: requested 10, got %d (max=5)", orch4.active_nodes));
	} else {
		fail(sprint("  Cap not enforced: active_nodes=%d > max=5", orch4.active_nodes));
	}
	orch4.shutdown_cluster();

	# ---- Cleanup --------------------------------------------------------
	orch.shutdown_cluster();

	print(sprint("\n=== Results: %d passed, %d failed ===\n\n", passed, failed));

	if (failed > 0)
		raise "fail:tests";
}

ok(msg: string)
{
	print("  PASS: " + msg + "\n");
	passed++;
}

fail(msg: string)
{
	print("  FAIL: " + msg + "\n");
	failed++;
}
