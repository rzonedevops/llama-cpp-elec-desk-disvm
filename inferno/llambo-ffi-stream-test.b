implement LlamboFFIStreamTest;

# Test suite for streaming FFI functionality
# Tests the token streaming capabilities of the llama-cpp-bridge

include "sys.m";
	sys: Sys;
	print, sprint: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "llambo-ffi.m";
	ffi: LlamboFFI;
	Bridge, StreamCallback: import ffi;

LlamboFFIStreamTest: module {
	init: fn(ctxt: ref Context, argv: list of string);
};

# Global state for streaming tests
token_count: int;
tokens_received: array of string;
final_received: int;

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	
	# Load FFI module
	ffi = load LlamboFFI LlamboFFI->PATH;
	if (ffi == nil) {
		print("FAIL: Could not load FFI module\n");
		raise "fail:load";
	}
	
	ffi->init(ctxt, nil);
	
	print("\n");
	print("╔════════════════════════════════════════════════════════╗\n");
	print("║   Llambo FFI Streaming Test Suite                     ║\n");
	print("╚════════════════════════════════════════════════════════╝\n\n");
	
	# Get model path from args if provided
	model_path := "";
	if (argv != nil && tl argv != nil)
		model_path = hd tl argv;
	
	# Run test suite
	run_tests(model_path);
	
	print("\n");
	print("╔════════════════════════════════════════════════════════╗\n");
	print("║   All Streaming Tests Completed                       ║\n");
	print("╚════════════════════════════════════════════════════════╝\n");
}

run_tests(model_path: string)
{
	print("Test 1: Connect to FFI bridge\n");
	bridge := test_connection();
	if (bridge == nil) {
		print("FAIL: Cannot proceed without bridge connection\n");
		return;
	}
	
	print("\nTest 2: Test PING command\n");
	test_ping(bridge);
	
	print("\nTest 3: Check status (no model)\n");
	test_status_no_model(bridge);
	
	if (model_path != "") {
		print("\nTest 4: Load model\n");
		if (!test_load_model(bridge, model_path)) {
			print("WARNING: Cannot test streaming without model\n");
		} else {
			print("\nTest 5: Streaming inference\n");
			test_streaming_inference(bridge);
			
			print("\nTest 6: Multiple streaming requests\n");
			test_multiple_streams(bridge);
		}
	} else {
		print("\nTest 4-6: SKIPPED (no model path provided)\n");
		print("  To test with a model: ./llambo-ffi-stream-test.dis /path/to/model.gguf\n");
		
		print("\nTest 7: Streaming without model (error handling)\n");
		test_streaming_no_model(bridge);
	}
	
	print("\nTest 8: Disconnect from bridge\n");
	test_disconnect(bridge);
}

# Test 1: Connect to bridge
test_connection(): ref Bridge
{
	bridge := Bridge.connect("");
	
	if (bridge == nil) {
		print("  FAIL: Could not connect to bridge\n");
		print("  Is the bridge running? Start it with: ./deploy.sh start-bridge\n");
		return nil;
	}
	
	print("  PASS: Connected to bridge at %s\n", bridge.socket_path);
	return bridge;
}

# Test 2: PING command
test_ping(bridge: ref Bridge)
{
	result := bridge.ping();
	
	if (result > 0) {
		print("  PASS: PING successful\n");
	} else {
		print("  FAIL: PING failed\n");
	}
}

# Test 3: Status check without model
test_status_no_model(bridge: ref Bridge)
{
	(ok, status) := bridge.get_status();
	
	if (ok > 0) {
		print("  PASS: Status check successful\n");
		print("  Status: %s\n", status);
	} else {
		print("  FAIL: Status check failed\n");
	}
}

# Test 4: Load model
test_load_model(bridge: ref Bridge, model_path: string): int
{
	(ok, msg) := bridge.load_model(model_path);
	
	if (ok > 0) {
		print("  PASS: Model loaded successfully\n");
		print("  Message: %s\n", msg);
		return 1;
	} else {
		print("  FAIL: Failed to load model\n");
		print("  Error: %s\n", msg);
		return 0;
	}
}

# Test 5: Streaming inference
test_streaming_inference(bridge: ref Bridge)
{
	token_count = 0;
	tokens_received = array[100] of string;
	final_received = 0;
	
	print("  Sending streaming inference request...\n");
	print("  Tokens: ");
	
	# Define callback
	callback := ref fn(token: string, is_final: int) {
		print("%s", token);
		if (token_count < len tokens_received) {
			tokens_received[token_count] = token;
		}
		token_count++;
		
		if (is_final) {
			final_received = 1;
		}
	};
	
	prompt := "What is distributed computing?";
	(ok, msg) := bridge.infer_stream(prompt, callback);
	
	print("\n");
	
	if (ok > 0) {
		print("  PASS: Streaming inference completed\n");
		print("  Tokens received: %d\n", token_count);
		print("  Final token flag: %d\n", final_received);
		
		if (token_count > 0 && final_received) {
			print("  SUCCESS: Received streaming tokens with final marker\n");
		} else if (token_count > 0) {
			print("  WARNING: Received tokens but no final marker\n");
		} else {
			print("  WARNING: No tokens received\n");
		}
	} else {
		print("  FAIL: Streaming inference failed\n");
		print("  Error: %s\n", msg);
	}
}

# Test 6: Multiple streaming requests
test_multiple_streams(bridge: ref Bridge)
{
	prompts := array[] of {
		"Hello",
		"Explain AI",
		"What is machine learning?"
	};
	
	for (i := 0; i < len prompts; i++) {
		print("  Request %d: %s\n", i + 1, prompts[i]);
		
		request_tokens := 0;
		callback := ref fn(token: string, is_final: int) {
			request_tokens++;
		};
		
		(ok, msg) := bridge.infer_stream(prompts[i], callback);
		
		if (ok > 0) {
			print("    PASS: Received %d tokens\n", request_tokens);
		} else {
			print("    FAIL: %s\n", msg);
		}
	}
}

# Test 7: Streaming without model (error handling)
test_streaming_no_model(bridge: ref Bridge)
{
	callback := ref fn(token: string, is_final: int) {
		print("Unexpected token: %s\n", token);
	};
	
	(ok, msg) := bridge.infer_stream("Test prompt", callback);
	
	if (ok <= 0) {
		print("  PASS: Correctly rejected streaming without model\n");
		print("  Error message: %s\n", msg);
	} else {
		print("  FAIL: Should have rejected streaming without model\n");
	}
}

# Test 8: Disconnect
test_disconnect(bridge: ref Bridge)
{
	bridge.disconnect();
	print("  PASS: Disconnected from bridge\n");
}
