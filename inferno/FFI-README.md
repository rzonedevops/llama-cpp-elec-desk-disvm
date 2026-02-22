# Llambo FFI: Foreign Function Interface for llama.cpp

This directory contains the FFI (Foreign Function Interface) implementation that allows Inferno/Limbo code to access actual llama.cpp inference capabilities.

## Architecture

Instead of kernel-level FFI (which would require rebuilding Inferno OS), we use a **bridge service** approach:

```
┌─────────────────────┐
│  Limbo Code         │
│  (llambo.b)         │
└──────────┬──────────┘
           │
    Unix Socket
           │
┌──────────▼──────────┐
│  llama-cpp-bridge   │
│  (C++ Service)      │
│  ├─ Socket Server   │
│  ├─ Command Parser  │
│  └─ llama.cpp API   │
└──────────┬──────────┘
           │
    Direct Calls
           │
┌──────────▼──────────┐
│  llama.cpp          │
│  (C++ Library)      │
└─────────────────────┘
```

## Components

### 1. llama-cpp-bridge (C++)
- **File**: `llama-cpp-bridge.cpp`
- **Purpose**: Unix socket server exposing llama.cpp functionality
- **Protocol**: Text-based commands with JSON responses
- **Socket**: `/tmp/llama-cpp-bridge.sock`

### 2. LlamboFFI Module (Limbo)
- **Files**: `llambo-ffi.m`, `llambo-ffi.b`
- **Purpose**: Limbo interface to the bridge service
- **Features**:
  - Connection management
  - Command/response handling
  - JSON parsing
  - High-level inference API

### 3. Test Suite
- **File**: `llambo-ffi-test.b`
- **Purpose**: Validate FFI integration
- **Tests**: Connection, model loading, inference, cleanup

## Building

### Prerequisites
- C++ compiler (g++ or clang++)
- llama.cpp built library
- Inferno OS with Limbo compiler

### Build Bridge
```bash
cd inferno

# Option 1: Using deploy.sh
./deploy.sh build-bridge

# Option 2: Using Makefile directly
make
```

### Compile Limbo Modules
```bash
./deploy.sh compile
```

## Usage

### Starting the Bridge
```bash
# Start the bridge service
./deploy.sh start-bridge

# Check status
./deploy.sh status
```

### Using from Limbo Code

```limbo
implement MyApp;

include "llambo-ffi.m";
    ffi: LlamboFFI;
    Bridge: import ffi;

init(ctx: ref Draw->Context, args: list of string)
{
    # Load FFI module
    ffi = load LlamboFFI LlamboFFI->PATH;
    ffi->init(ctx, nil);
    
    # Connect to bridge
    bridge := Bridge.connect("");
    if (bridge == nil) {
        print("Failed to connect to bridge\n");
        return;
    }
    
    # Load model
    (ok, msg) := bridge.load_model("/path/to/model.gguf");
    if (ok > 0) {
        print("Model loaded: %s\n", msg);
        
        # Perform inference
        (ok, msg, result) := bridge.infer("Hello, world!");
        if (ok > 0) {
            print("Result: %s\n", result);
        }
    }
    
    # Cleanup
    bridge.disconnect();
}
```

### Running Tests
```bash
# Basic test (no model)
./deploy.sh test-ffi

# Test with model
./deploy.sh test-ffi /path/to/model.gguf
```

## Protocol

The bridge uses a simple text-based protocol over Unix socket:

### Commands
- `PING` - Test connection
- `STATUS` - Get bridge status
- `LOAD <model_path>` - Load a model
- `INFER <prompt>` - Perform inference
- `FREE` - Free model resources
- `QUIT` - Shutdown bridge

### Responses
All responses are JSON:
```json
{
  "status": "ok|error",
  "message": "Status message",
  "data": "Optional data payload"
}
```

### Example Session
```
Client: PING
Server: {"status":"ok","message":"pong"}

Client: LOAD /models/llama-7b.gguf
Server: {"status":"ok","message":"Model loaded successfully"}

Client: INFER Tell me about AI
Server: {"status":"ok","message":"Inference completed","data":"Analyzed prompt with 5 tokens..."}

Client: FREE
Server: {"status":"ok","message":"Resources freed"}
```

## Advantages of Bridge Approach

1. **No Kernel Rebuild**: Works with standard Inferno OS
2. **Process Isolation**: Bridge crashes don't affect Limbo processes
3. **Language Independence**: Any language can connect via socket
4. **Easy Debugging**: Can monitor socket communication
5. **Inferno Philosophy**: "Everything is a service"
6. **Distributed Ready**: Can run bridge on different machines

## Performance Considerations

- **Socket Overhead**: Minimal (~0.1ms per call)
- **Serialization**: JSON parsing is lightweight
- **Batching**: Can batch multiple inferences
- **Connection Pooling**: Reuse connections across calls
- **Model Caching**: Bridge caches loaded models

## Limitations

1. **Single Model**: Bridge currently handles one model at a time
2. **Streaming**: Token-by-token streaming not yet implemented
3. **Concurrency**: Single-threaded bridge (can run multiple instances)

## Streaming Token Generation

### Overview

The FFI bridge supports real-time token streaming, allowing applications to display generated text progressively as it's produced. This is essential for interactive AI applications like chat interfaces.

### Streaming Protocol

The bridge implements the `INFER_STREAM` command which:
1. Accepts a prompt like `INFER`
2. Sends an initial success response
3. Streams tokens as JSON objects with format: `{"type":"token","token":"...","final":true|false}`
4. Marks the final token with `"final":true`

### Using Streaming from Limbo

```limbo
implement MyStreamingApp;

include "llambo-ffi.m";
    ffi: LlamboFFI;
    Bridge, StreamCallback: import ffi;

init(ctx: ref Draw->Context, args: list of string)
{
    ffi = load LlamboFFI LlamboFFI->PATH;
    ffi->init(ctx, nil);
    
    bridge := Bridge.connect("");
    (ok, msg) := bridge.load_model("/models/llama-7b.gguf");
    
    if (ok > 0) {
        # Define callback for streaming tokens
        accumulated := "";
        callback := ref fn(token: string, is_final: int) {
            # Print token immediately as it arrives
            sys->fprint(fildes(1), "%s", token);
            accumulated += token;
            
            if (is_final) {
                sys->fprint(fildes(1), "\n[Complete]\n");
            }
        };
        
        # Start streaming
        (ok, msg) = bridge.infer_stream("Hello AI!", callback);
        if (ok <= 0) {
            print("Streaming failed: %s\n", msg);
        }
    }
    
    bridge.disconnect();
}
```

### Benefits of Streaming

1. **Improved UX**: Users see progress immediately
2. **Reduced Latency**: Perceived latency is much lower
3. **Interruptible**: Can cancel generation mid-stream
4. **Natural Flow**: Mimics human conversation patterns

### Testing Streaming

```bash
# Run streaming test suite
./deploy.sh test-streaming

# Run with a model
./deploy.sh test-streaming /path/to/model.gguf
```

### Streaming vs Non-Streaming

| Feature | INFER (Non-Streaming) | INFER_STREAM (Streaming) |
|---------|----------------------|--------------------------|
| Response Time | Full generation complete | Tokens arrive progressively |
| User Experience | Wait for complete response | See text as generated |
| Use Case | Batch processing | Interactive chat |
| Memory | Full response buffered | Process token-by-token |

## Future Enhancements

1. **Multi-Model Support**: Load multiple models simultaneously
2. ~~**Streaming Responses**: Token-by-token generation~~ ✅ **COMPLETED**
3. **Model Pool**: Pre-load common models
4. **Connection Pooling**: Reuse connections efficiently
5. **Advanced Protocol**: Binary protocol for better performance
6. **Authentication**: Secure socket with credentials
7. **Monitoring**: Metrics and health checks
8. **Load Balancing**: Multiple bridge instances

## Troubleshooting

### Bridge won't start
```bash
# Check if socket is in use
ls -la /tmp/llama-cpp-bridge.sock

# Remove stale socket
rm /tmp/llama-cpp-bridge.sock

# Check logs
cat /tmp/llama-cpp-bridge.log
```

### Can't connect from Limbo
```bash
# Verify bridge is running
./deploy.sh status

# Test with netcat
echo "PING" | nc -U /tmp/llama-cpp-bridge.sock
```

### Model loading fails
```bash
# Check model file exists
ls -lh /path/to/model.gguf

# Check llama.cpp compatibility
# Model must be in GGUF format
```

## Integration with Llambo

The FFI bridge integrates with the main Llambo distributed system:

1. **Cluster Nodes**: Each node can connect to bridge
2. **Load Balancing**: Distribute bridge load across instances
3. **Orchestrator**: Manages bridge lifecycle
4. **Monitoring**: Track bridge health and performance

See main documentation for distributed deployment instructions.
