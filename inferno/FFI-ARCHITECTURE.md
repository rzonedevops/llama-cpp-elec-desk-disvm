# Llambo FFI Architecture Diagram

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Distributed Inferno Cluster                      │
│                                                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                  │
│  │ Worker Node  │  │ Worker Node  │  │ Worker Node  │  ... (1000+)     │
│  │              │  │              │  │              │                   │
│  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │                  │
│  │ │ Limbo VM │ │  │ │ Limbo VM │ │  │ │ Limbo VM │ │                  │
│  │ │(llambo.b)│ │  │ │(limbot.b)│ │  │ │(dish.b)  │ │                  │
│  │ └────┬─────┘ │  │ └────┬─────┘ │  │ └────┬─────┘ │                  │
│  │      │       │  │      │       │  │      │       │                   │
│  │      │ FFI   │  │      │ FFI   │  │      │ FFI   │                   │
│  │      ▼       │  │      ▼       │  │      ▼       │                   │
│  │ ┌──────────┐ │  │ ┌──────────┐ │  │ ┌──────────┐ │                  │
│  │ │llambo-ffi│ │  │ │llambo-ffi│ │  │ │llambo-ffi│ │                  │
│  │ │  Module  │ │  │ │  Module  │ │  │ │  Module  │ │                  │
│  │ └────┬─────┘ │  │ └────┬─────┘ │  │ └────┬─────┘ │                  │
│  └──────┼───────┘  └──────┼───────┘  └──────┼───────┘                  │
│         │                  │                  │                           │
└─────────┼──────────────────┼──────────────────┼───────────────────────────┘
          │                  │                  │
          │ Unix Socket      │ Unix Socket      │ Unix Socket
          │ (IPC)            │ (IPC)            │ (IPC)
          │                  │                  │
┌─────────▼──────────────────▼──────────────────▼───────────────────────────┐
│                      Host Operating System                                 │
│                                                                            │
│  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐                │
│  │llama-cpp-     │  │llama-cpp-     │  │llama-cpp-     │  ...           │
│  │bridge         │  │bridge         │  │bridge         │                │
│  │(Instance 1)   │  │(Instance 2)   │  │(Instance 3)   │                │
│  │               │  │               │  │               │                │
│  │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │                │
│  │ │Socket Srv │ │  │ │Socket Srv │ │  │ │Socket Srv │ │                │
│  │ │/tmp/*.sock│ │  │ │/tmp/*.sock│ │  │ │/tmp/*.sock│ │                │
│  │ └─────┬─────┘ │  │ └─────┬─────┘ │  │ └─────┬─────┘ │                │
│  │       │       │  │       │       │  │       │       │                │
│  │       ▼       │  │       ▼       │  │       ▼       │                │
│  │ ┌───────────┐ │  │ ┌───────────┐ │  │ ┌───────────┐ │                │
│  │ │llama.cpp  │ │  │ │llama.cpp  │ │  │ │llama.cpp  │ │                │
│  │ │API Calls  │ │  │ │API Calls  │ │  │ │API Calls  │ │                │
│  │ └─────┬─────┘ │  │ └─────┬─────┘ │  │ └─────┬─────┘ │                │
│  └───────┼───────┘  └───────┼───────┘  └───────┼───────┘                │
│          │                  │                  │                          │
│          ▼                  ▼                  ▼                          │
│  ┌────────────────────────────────────────────────────┐                  │
│  │              llama.cpp Shared Library               │                 │
│  │                  (libllama.a/so)                    │                 │
│  │                                                      │                 │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐         │                 │
│  │  │ Model 1  │  │ Model 2  │  │ Model 3  │         │                 │
│  │  │(llama-7b)│  │(llama-13b)│  │(llama-1b)│  ...    │                 │
│  │  └──────────┘  └──────────┘  └──────────┘         │                 │
│  └────────────────────────────────────────────────────┘                  │
└────────────────────────────────────────────────────────────────────────────┘
```

## Protocol Flow

```
Limbo Application              FFI Module              Bridge Service       llama.cpp
─────────────────              ──────────              ──────────────       ─────────
       │                            │                        │                   │
       │  1. Load FFI Module        │                        │                   │
       ├────────────────────────────▶                        │                   │
       │                            │                        │                   │
       │  2. Connect to Bridge      │                        │                   │
       ├────────────────────────────▶  3. Open Socket        │                   │
       │                            ├────────────────────────▶                   │
       │                            │                        │                   │
       │  4. Load Model             │                        │                   │
       ├────────────────────────────▶  5. Send "LOAD ..."   │                   │
       │                            ├────────────────────────▶  6. llama_load()  │
       │                            │                        ├───────────────────▶
       │                            │                        │                   │
       │                            │  7. JSON Response      │                   │
       │  8. Status Message         │◀────────────────────────                   │
       │◀────────────────────────────                        │                   │
       │                            │                        │                   │
       │  9. Perform Inference      │                        │                   │
       ├────────────────────────────▶ 10. Send "INFER ..."  │                   │
       │                            ├────────────────────────▶ 11. llama_infer() │
       │                            │                        ├───────────────────▶
       │                            │                        │                   │
       │                            │ 12. JSON Response      │                   │
       │ 13. Inference Result       │◀────────────────────────                   │
       │◀────────────────────────────                        │                   │
       │                            │                        │                   │
       │ 14. Cleanup                │                        │                   │
       ├────────────────────────────▶ 15. Send "FREE"       │                   │
       │                            ├────────────────────────▶ 16. llama_free()  │
       │                            │                        ├───────────────────▶
       │                            │                        │                   │
       │ 17. Disconnect             │ 18. Close Socket       │                   │
       ├────────────────────────────▶────────────────────────▶                   │
       │                            │                        │                   │
```

## Command Protocol

```
Client → Bridge:    COMMAND [arguments]
Bridge → Client:    {"status":"ok|error","message":"...","data":"..."}
```

### Available Commands

| Command | Arguments | Response | Description |
|---------|-----------|----------|-------------|
| PING | none | status: ok | Test connection |
| STATUS | none | status + message | Get bridge status |
| LOAD | model_path | status + message | Load llama.cpp model |
| INFER | prompt_text | status + message + data | Perform inference |
| FREE | none | status + message | Free model resources |
| QUIT | none | status + message | Shutdown bridge |

### Example Session

```
→ PING
← {"status":"ok","message":"pong"}

→ LOAD /models/llama-7b-q4.gguf
← {"status":"ok","message":"Model loaded successfully"}

→ STATUS
← {"status":"ok","message":"Model loaded: /models/llama-7b-q4.gguf"}

→ INFER What is artificial intelligence?
← {"status":"ok","message":"Inference completed","data":"Analyzed prompt with 7 tokens..."}

→ FREE
← {"status":"ok","message":"Resources freed"}
```

## Data Flow Layers

```
┌────────────────────────────────────────────────────────────────┐
│ Application Layer (Limbo)                                       │
│ - Business logic                                                │
│ - Cluster orchestration                                         │
│ - Load balancing                                                │
└────────────────────┬───────────────────────────────────────────┘
                     │ Limbo API Calls
┌────────────────────▼───────────────────────────────────────────┐
│ FFI Module Layer (Limbo)                                        │
│ - llambo-ffi.m/b                                                │
│ - Connection management                                         │
│ - Protocol handling                                             │
│ - JSON parsing                                                  │
└────────────────────┬───────────────────────────────────────────┘
                     │ Unix Socket (IPC)
┌────────────────────▼───────────────────────────────────────────┐
│ Bridge Service Layer (C++)                                      │
│ - llama-cpp-bridge                                              │
│ - Socket server                                                 │
│ - Command parser                                                │
│ - Model lifecycle                                               │
└────────────────────┬───────────────────────────────────────────┘
                     │ C++ API Calls
┌────────────────────▼───────────────────────────────────────────┐
│ Inference Engine Layer (C++)                                    │
│ - llama.cpp library                                             │
│ - Model loading                                                 │
│ - Tokenization                                                  │
│ - Inference execution                                           │
└─────────────────────────────────────────────────────────────────┘
```

## Scalability Model

### Single Node
```
┌─────────────────────┐
│  1 Limbo Worker     │
│       ↓             │
│  1 FFI Module       │
│       ↓             │
│  1 Bridge Instance  │
│       ↓             │
│  1 llama.cpp Model  │
└─────────────────────┘
Performance: ~10 tok/s
```

### Multi-Worker Node
```
┌─────────────────────┐
│  10 Limbo Workers   │
│       ↓↓↓           │
│  10 FFI Modules     │
│       ↓↓↓           │
│  1 Bridge (shared)  │
│       ↓             │
│  1 llama.cpp Model  │
└─────────────────────┘
Performance: ~10 tok/s (shared)
```

### Distributed Cluster
```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Node 1   │  │ Node 2   │  │ Node 3   │
│ 100 Work │  │ 100 Work │  │ 100 Work │
│    ↓     │  │    ↓     │  │    ↓     │
│ 1 Bridge │  │ 1 Bridge │  │ 1 Bridge │
│    ↓     │  │    ↓     │  │    ↓     │
│ 1 Model  │  │ 1 Model  │  │ 1 Model  │
└──────────┘  └──────────┘  └──────────┘
Performance: ~30 tok/s aggregate
Can scale to 1000+ nodes
```

## Benefits of Bridge Architecture

1. **No Kernel Rebuild** - Works with standard Inferno OS
2. **Process Isolation** - Bridge crashes don't affect Limbo processes
3. **Language Agnostic** - Any language can use the socket protocol
4. **Easy Debugging** - Monitor socket communication with standard tools
5. **Distributed Ready** - Bridge can run on different machines
6. **Resource Management** - Bridge handles model lifecycle independently
7. **Load Balancing** - Multiple bridges for horizontal scaling
8. **Security** - Unix socket with filesystem permissions

## Performance Characteristics

| Metric | Value | Notes |
|--------|-------|-------|
| Socket Latency | ~0.1-0.5ms | Per command |
| JSON Overhead | ~0.1ms | Parsing time |
| Total Overhead | ~0.2-0.6ms | Per inference |
| Model Loading | ~1-10s | One-time cost |
| Inference Speed | Model-dependent | No bridge impact |
| Memory Overhead | ~10MB | Bridge process |
| Scalability | Linear | Add more bridges |

## Deployment Scenarios

### Development (Local)
- Single bridge instance
- Local testing and debugging
- Command: `./deploy.sh start-bridge`

### Production (Single Node)
- Multiple bridge instances
- Load balancing across instances
- Each worker connects to nearest bridge

### Production (Cluster)
- Bridge per node
- Cluster-wide load balancing
- Auto-scaling based on demand
- Model distribution across nodes
