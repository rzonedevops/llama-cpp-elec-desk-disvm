implement LlamboConsensusTest;

# llambo-consensus-test: Integration test for cognitive fusion.
# Sends the same prompt to multiple nodes and verifies that the CognitiveFusion
# ADT correctly selects or synthesises a response from the parallel results.
#
# Usage:
#   llambo-consensus-test [model_path]
#
# Tests:
#   1. Create orchestrator and spawn 5 nodes
#   2. Run infer_fusion with weighted-average strategy
#   3. Run infer_fusion with majority-vote strategy
#   4. Run infer_fusion with confidence-weighted strategy
#   5. Run infer_fusion with raft-consensus strategy
#   6. Verify CognitiveFusion.fuse() with manually constructed responses

include "sys.m";
	sys: Sys;
	print, sprint: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "llambo.m";
	llambo: Llambo;
	Orchestrator, InferenceRequest, InferenceResponse, CognitiveFusion: import llambo;

LlamboConsensusTest: module {
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
		print("llambo-consensus-test: cannot load Llambo module\n");
		raise "fail:load";
	}
	llambo->init(ctxt, nil);

	print("\n=== Llambo Cognitive Fusion Consensus Tests ===\n\n");

	model_path := "/models/llama-7b.gguf";
	args := argv;
	if (args != nil) args = tl args;
	if (args != nil) model_path = hd args;

	# ---- Test 1: Orchestrator and node spawning -------------------------
	print("Test 1: Spawning 5-node cluster...\n");
	orch := llambo->Orchestrator.new(100, 1);
	n := orch.spawn_cluster(5, model_path);
	if (n == 5) {
		ok("  Spawned 5 nodes");
	} else {
		fail(sprint("  Expected 5 nodes, got %d", n));
	}

	# ---- Test 2: infer_fusion with weighted-average (strategy 0) --------
	print("\nTest 2: infer_fusion — weighted-average strategy...\n");
	resp := llambo->infer_fusion(orch, "What is distributed computing?", 3, 0);
	if (resp != nil) {
		ok(sprint("  Got response: token_count=%d time=%dms", resp.token_count, resp.completion_time));
	} else {
		fail("  infer_fusion returned nil");
	}

	# ---- Test 3: infer_fusion with majority-vote (strategy 1) -----------
	print("\nTest 3: infer_fusion — majority-vote strategy...\n");
	resp = llambo->infer_fusion(orch, "Explain neural networks briefly.", 5, 1);
	if (resp != nil) {
		ok(sprint("  Got response: %s", resp.text[0:min(60, len resp.text)]));
	} else {
		fail("  infer_fusion (majority-vote) returned nil");
	}

	# ---- Test 4: infer_fusion with confidence-weighted (strategy 2) -----
	print("\nTest 4: infer_fusion — confidence-weighted strategy...\n");
	resp = llambo->infer_fusion(orch, "What is a Dis VM?", 3, 2);
	if (resp != nil) {
		ok(sprint("  Fastest response selected: %dms", resp.completion_time));
	} else {
		fail("  infer_fusion (confidence-weighted) returned nil");
	}

	# ---- Test 5: infer_fusion with raft-consensus (strategy 3) ----------
	print("\nTest 5: infer_fusion — raft-consensus strategy...\n");
	resp = llambo->infer_fusion(orch, "Define cognitive architecture.", 5, 3);
	if (resp != nil) {
		ok("  Consensus response obtained");
	} else {
		fail("  infer_fusion (raft) returned nil");
	}

	# ---- Test 6: CognitiveFusion.fuse() directly -------------------------
	print("\nTest 6: CognitiveFusion.fuse() unit tests...\n");

	# Build synthetic responses
	r0 := ref InferenceResponse;
	r0.text = "alpha"; r0.token_count = 2; r0.completion_time = 50;
	r1 := ref InferenceResponse;
	r1.text = "beta";  r1.token_count = 4; r1.completion_time = 30;
	r2 := ref InferenceResponse;
	r2.text = "alpha"; r2.token_count = 3; r2.completion_time = 80;
	r3 := ref InferenceResponse;
	r3.text = "alpha"; r3.token_count = 2; r3.completion_time = 20;

	responses := array[] of {r0, r1, r2, r3};

	# Majority-vote: "alpha" appears 3 times
	cf_vote := llambo->CognitiveFusion.new(1, 2, 5000);
	result := cf_vote.fuse(responses);
	if (result != nil && result.text == "alpha") {
		ok("  Majority-vote selected 'alpha' (3/4 votes)");
	} else {
		fail(sprint("  Majority-vote expected 'alpha', got: %s",
		     (result != nil) ? result.text : "nil"));
	}

	# Confidence-weighted: r3 has lowest completion_time (20ms)
	cf_conf := llambo->CognitiveFusion.new(2, 2, 5000);
	result = cf_conf.fuse(responses);
	if (result != nil && result.completion_time == 20) {
		ok("  Confidence-weighted selected fastest response (20ms)");
	} else {
		fail(sprint("  Expected 20ms response, got: %dms",
		     (result != nil) ? result.completion_time : -1));
	}

	# Raft-consensus: "alpha" has 3 agreements >= min_nodes=2
	cf_raft := llambo->CognitiveFusion.new(3, 2, 5000);
	result = cf_raft.fuse(responses);
	if (result != nil && result.text == "alpha") {
		ok("  Raft-consensus selected 'alpha' (quorum met)");
	} else {
		fail(sprint("  Raft expected 'alpha', got: %s",
		     (result != nil) ? result.text : "nil"));
	}

	# ---- Test 7: Edge cases ---------------------------------------------
	print("\nTest 7: Edge cases...\n");

	# Single valid response
	cf_any := llambo->CognitiveFusion.new(0, 1, 5000);
	singles := array[1] of {r0};
	result = cf_any.fuse(singles);
	if (result != nil && result.text == "alpha") {
		ok("  Single response passthrough OK");
	} else {
		fail("  Single response passthrough failed");
	}

	# All nil responses
	nils := array[3] of ref InferenceResponse;
	result = cf_any.fuse(nils);
	if (result == nil) {
		ok("  All-nil responses return nil OK");
	} else {
		fail("  All-nil responses should return nil");
	}

	# ---- Summary --------------------------------------------------------
	print(sprint("\n=== Results: %d passed, %d failed ===\n\n", passed, failed));

	orch.shutdown_cluster();

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

min(a: int, b: int): int
{
	if (a < b) return a;
	return b;
}
