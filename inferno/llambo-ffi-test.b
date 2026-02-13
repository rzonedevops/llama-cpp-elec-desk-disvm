implement LlamboFFITest;

include "sys.m";
	sys: Sys;
	print: import sys;

include "draw.m";
	draw: Draw;

include "llambo-ffi.m";
	ffi: LlamboFFI;
	Bridge: import ffi;

LlamboFFITest: module
{
	init: fn(ctx: ref Draw->Context, args: list of string);
};

init(ctx: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	ffi = load LlamboFFI LlamboFFI->PATH;
	
	if (ffi == nil) {
		print("Failed to load LlamboFFI module\n");
		return;
	}
	
	ffi->init(ctx, nil);
	
	print("\n=== Llambo FFI Bridge Test ===\n\n");
	
	# Test 1: Connect to bridge
	print("Test 1: Connecting to bridge...\n");
	bridge := Bridge.connect("");
	if (bridge == nil) {
		print("  FAILED: Could not connect to bridge\n");
		print("  Make sure llama-cpp-bridge is running:\n");
		print("    ./llama-cpp-bridge &\n");
		return;
	}
	print("  PASSED: Connected to bridge\n\n");
	
	# Test 2: Ping
	print("Test 2: Sending PING...\n");
	if (bridge.ping()) {
		print("  PASSED: Bridge responded to ping\n\n");
	} else {
		print("  FAILED: No ping response\n\n");
	}
	
	# Test 3: Check status (no model loaded)
	print("Test 3: Checking status (no model)...\n");
	(ok, status) := bridge.get_status();
	if (ok > 0) {
		print("  PASSED: Status: %s\n\n", status);
	} else {
		print("  FAILED: Could not get status\n\n");
	}
	
	# Test 4: Try to infer without model (should fail gracefully)
	print("Test 4: Attempting inference without model...\n");
	(ok, msg, data) := bridge.infer("Test prompt");
	if (ok <= 0) {
		print("  PASSED: Correctly rejected (no model): %s\n\n", msg);
	} else {
		print("  WARNING: Inference succeeded without model?\n\n");
	}
	
	# Test 5: Load model (if model path provided)
	model_path := "";
	if (args != nil && tl args != nil) {
		model_path = hd tl args;
	}
	
	if (model_path != "") {
		print("Test 5: Loading model: %s...\n", model_path);
		(ok, msg) = bridge.load_model(model_path);
		if (ok > 0) {
			print("  PASSED: %s\n\n", msg);
			
			# Test 6: Check status (model loaded)
			print("Test 6: Checking status (model loaded)...\n");
			(ok, status) = bridge.get_status();
			if (ok > 0) {
				print("  PASSED: Status: %s\n\n", status);
			}
			
			# Test 7: Perform inference
			print("Test 7: Performing inference...\n");
			(ok, msg, data) = bridge.infer("Hello, how are you?");
			if (ok > 0) {
				print("  PASSED: Inference completed\n");
				print("  Result: %s\n\n", data);
			} else {
				print("  FAILED: %s\n\n", msg);
			}
			
			# Test 8: Free model
			print("Test 8: Freeing model resources...\n");
			if (bridge.free_model() > 0) {
				print("  PASSED: Resources freed\n\n");
			} else {
				print("  FAILED: Could not free resources\n\n");
			}
		} else {
			print("  FAILED: %s\n", msg);
			print("  (This is expected if model file doesn't exist)\n\n");
		}
	} else {
		print("Test 5-8: SKIPPED (no model path provided)\n");
		print("  To test with a model, run:\n");
		print("    llambo-ffi-test /path/to/model.gguf\n\n");
	}
	
	# Cleanup
	print("Cleaning up...\n");
	bridge.disconnect();
	print("  Disconnected from bridge\n\n");
	
	print("=== FFI Bridge Test Complete ===\n");
}
