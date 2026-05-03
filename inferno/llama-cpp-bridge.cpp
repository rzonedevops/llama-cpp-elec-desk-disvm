/**
 * llama-cpp-bridge: A lightweight bridge service for Inferno/Limbo to access llama.cpp
 *
 * This bridge exposes llama.cpp functionality via a simple text-based protocol over Unix
 * socket, allowing Limbo code to perform actual LLM inference without kernel-level FFI.
 *
 * Protocol:
 *   - Commands are newline-terminated text
 *   - Responses are newline-terminated JSON
 *
 * Commands:
 *   PING
 *   STATUS
 *   LOAD <model_path>
 *   INFER [max_tokens=N] [temperature=T] [top_p=P] <prompt>
 *   INFER_STREAM [max_tokens=N] [temperature=T] [top_p=P] <prompt>
 *   INFER_MULTI [max_tokens=N] [temperature=T] [top_p=P] <prompt1>||<prompt2>||...
 *   FREE
 *   QUIT
 */

#include <iostream>
#include <string>
#include <sstream>
#include <iomanip>
#include <memory>
#include <cstring>
#include <cstdlib>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <signal.h>
#include <vector>

// Include llama.cpp headers
#include "../llama.cpp/llama.h"

// Default socket path (overridable via --socket-path)
static const char* DEFAULT_SOCKET_PATH = "/tmp/llama-cpp-bridge.sock";
static const int   MAX_CONNECTIONS     = 10;

// Per-inference configurable parameters with defaults
struct InferParams {
    int   max_tokens  = 256;
    float temperature = 0.8f;
    float top_p       = 0.9f;
};

// Bridge global state
struct BridgeState {
    llama_model*  model       = nullptr;
    llama_context* ctx        = nullptr;
    std::string   model_path;
    bool          running     = true;
    const char*   socket_path = DEFAULT_SOCKET_PATH;
};

static BridgeState g_state;

// ---------------------------------------------------------------------------
// Signal handling
// ---------------------------------------------------------------------------
static void signal_handler(int signum) {
    std::cerr << "Received signal " << signum << ", shutting down..." << std::endl;
    g_state.running = false;
}

// ---------------------------------------------------------------------------
// Resource cleanup
// ---------------------------------------------------------------------------
static void cleanup_model() {
    if (g_state.ctx != nullptr) {
        llama_free(g_state.ctx);
        g_state.ctx = nullptr;
    }
    if (g_state.model != nullptr) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
    }
    g_state.model_path.clear();
}

static void cleanup() {
    cleanup_model();
    llama_backend_free();
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------
static std::string escape_json(const std::string& s) {
    std::ostringstream o;
    for (unsigned char c : s) {
        if      (c == '"')  { o << "\\\""; }
        else if (c == '\\') { o << "\\\\"; }
        else if (c == '\n') { o << "\\n";  }
        else if (c == '\r') { o << "\\r";  }
        else if (c == '\t') { o << "\\t";  }
        else if (c < 32)    { o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << (int)c; }
        else                { o << (char)c; }
    }
    return o.str();
}

static void send_all(int fd, const std::string& data) {
    ssize_t sent = 0;
    while (sent < (ssize_t)data.size()) {
        ssize_t n = send(fd, data.c_str() + sent, data.size() - sent, 0);
        if (n <= 0) break;
        sent += n;
    }
}

static void send_response(int fd, const std::string& status,
                           const std::string& message, const std::string& data = "") {
    std::ostringstream r;
    r << "{\"status\":\"" << status
      << "\",\"message\":\"" << escape_json(message) << "\"";
    if (!data.empty())
        r << ",\"data\":\"" << escape_json(data) << "\"";
    r << "}\n";
    send_all(fd, r.str());
}

static void send_stream_token(int fd, const std::string& token, bool is_final = false) {
    std::ostringstream r;
    r << "{\"type\":\"token\",\"token\":\"" << escape_json(token) << "\"";
    if (is_final) r << ",\"final\":true";
    r << "}\n";
    send_all(fd, r.str());
}

// ---------------------------------------------------------------------------
// Inference parameter parsing
// Syntax (all optional before the prompt):
//   [max_tokens=N] [temperature=T] [top_p=P] <prompt text>
// ---------------------------------------------------------------------------
static std::pair<InferParams, std::string> parse_infer_args(const std::string& args) {
    InferParams params;
    std::string rem = args;

    // Trim leading whitespace
    auto ltrim = [](std::string& s) {
        size_t p = s.find_first_not_of(" \t");
        if (p != std::string::npos) s = s.substr(p);
        else s.clear();
    };
    ltrim(rem);

    // Consume keyword=value tokens
    while (!rem.empty()) {
        size_t eq = rem.find('=');
        size_t sp = rem.find(' ');
        // If '=' doesn't exist or comes after a space, we're at the prompt
        if (eq == std::string::npos || (sp != std::string::npos && sp < eq)) break;

        std::string key = rem.substr(0, eq);
        rem = rem.substr(eq + 1);

        sp = rem.find(' ');
        std::string val = (sp != std::string::npos) ? rem.substr(0, sp) : rem;

        if      (key == "max_tokens")  { try { params.max_tokens  = std::stoi(val); } catch (...) {} }
        else if (key == "temperature") { try { params.temperature = std::stof(val); } catch (...) {} }
        else if (key == "top_p")       { try { params.top_p       = std::stof(val); } catch (...) {} }
        else { break; } // unknown key — start of prompt

        if (sp == std::string::npos) rem.clear();
        else { rem = rem.substr(sp + 1); ltrim(rem); }
    }

    return {params, rem};
}

// ---------------------------------------------------------------------------
// Model loading
// ---------------------------------------------------------------------------
static bool load_model(const std::string& model_path) {
    cleanup_model();

    static bool backend_initialized = false;
    if (!backend_initialized) {
        llama_backend_init();
        backend_initialized = true;
    }

    llama_model_params mp = llama_model_default_params();
    mp.use_mmap  = true;
    mp.use_mlock = false; // allow OS to swap; reduces pressure in multi-bridge setups

    g_state.model = llama_load_model_from_file(model_path.c_str(), mp);
    if (!g_state.model) return false;

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx     = 2048;
    cp.n_threads = 4;
    cp.n_batch   = 512;

    g_state.ctx = llama_new_context_with_model(g_state.model, cp);
    if (!g_state.ctx) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
        return false;
    }

    g_state.model_path = model_path;
    return true;
}

// ---------------------------------------------------------------------------
// Build the sampler chain (top-p → temperature → distribution)
// Caller is responsible for llama_sampler_free(smpl) after use.
// ---------------------------------------------------------------------------
static struct llama_sampler* build_sampler(const InferParams& p) {
    llama_sampler_chain_params sp = llama_sampler_chain_default_params();
    struct llama_sampler* smpl = llama_sampler_chain_init(sp);
    llama_sampler_chain_add(smpl, llama_sampler_init_top_p(p.top_p, 1));
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(p.temperature));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    return smpl;
}

// ---------------------------------------------------------------------------
// Core inference with real token sampling loop
// ---------------------------------------------------------------------------
static std::string perform_inference(const std::string& prompt, const InferParams& p) {
    if (!g_state.model || !g_state.ctx)
        return "ERROR: No model loaded";

    // Clear KV cache for stateless per-request operation
    llama_kv_cache_clear(g_state.ctx);

    // Tokenize prompt
    std::vector<llama_token> toks(prompt.size() + 128);
    int n_prompt = llama_tokenize(g_state.model,
                                  prompt.c_str(), (int)prompt.size(),
                                  toks.data(), (int)toks.size(),
                                  /*add_bos=*/true, /*special=*/false);
    if (n_prompt < 0) return "ERROR: Failed to tokenize prompt";
    toks.resize(n_prompt);

    // Evaluate prompt
    if (llama_decode(g_state.ctx, llama_batch_get_one(toks.data(), n_prompt, 0, 0)))
        return "ERROR: Failed to evaluate prompt";

    // Build sampler chain: top-p → temperature → distribution
    struct llama_sampler* smpl = build_sampler(p);

    std::string result;
    int n_gen = 0;

    while (n_gen < p.max_tokens) {
        llama_token tok = llama_sampler_sample(smpl, g_state.ctx, -1);

        if (llama_token_is_eog(g_state.model, tok)) break;

        // Decode token to text piece
        char piece[256];
        int  np = llama_token_to_piece(g_state.model, tok, piece, sizeof(piece), 0, false);
        if (np < 0) break;
        result += std::string(piece, np);

        llama_sampler_accept(smpl, tok);

        // Feed generated token back for next prediction
        if (llama_decode(g_state.ctx,
                         llama_batch_get_one(&tok, 1, n_prompt + n_gen, 0)))
            break;
        ++n_gen;
    }

    llama_sampler_free(smpl);
    return result;
}

// ---------------------------------------------------------------------------
// Streaming inference: sends each token to client as it is generated
// ---------------------------------------------------------------------------
static void perform_streaming_inference(int fd, const std::string& prompt,
                                        const InferParams& p) {
    if (!g_state.model || !g_state.ctx) {
        send_response(fd, "error", "No model loaded");
        return;
    }

    llama_kv_cache_clear(g_state.ctx);

    std::vector<llama_token> toks(prompt.size() + 128);
    int n_prompt = llama_tokenize(g_state.model,
                                  prompt.c_str(), (int)prompt.size(),
                                  toks.data(), (int)toks.size(),
                                  true, false);
    if (n_prompt < 0) { send_response(fd, "error", "Failed to tokenize prompt"); return; }
    toks.resize(n_prompt);

    if (llama_decode(g_state.ctx, llama_batch_get_one(toks.data(), n_prompt, 0, 0))) {
        send_response(fd, "error", "Failed to evaluate prompt");
        return;
    }

    // Acknowledge streaming start
    send_response(fd, "ok", "Starting token generation");

    struct llama_sampler* smpl = build_sampler(p);

    bool done = false;
    int  n_gen = 0;

    while (n_gen < p.max_tokens && !done) {
        llama_token tok = llama_sampler_sample(smpl, g_state.ctx, -1);

        if (llama_token_is_eog(g_state.model, tok)) {
            send_stream_token(fd, "", true); // final marker
            done = true;
            break;
        }

        char piece[256];
        int  np = llama_token_to_piece(g_state.model, tok, piece, sizeof(piece), 0, false);
        if (np < 0) break;

        bool is_last = (n_gen == p.max_tokens - 1);
        send_stream_token(fd, std::string(piece, np), is_last);

        llama_sampler_accept(smpl, tok);
        if (llama_decode(g_state.ctx,
                         llama_batch_get_one(&tok, 1, n_prompt + n_gen, 0)))
            break;
        ++n_gen;
    }

    if (!done)
        send_stream_token(fd, "", true); // ensure client always gets a final marker

    llama_sampler_free(smpl);
}

// ---------------------------------------------------------------------------
// Command dispatcher
// ---------------------------------------------------------------------------
static void handle_command(int fd, const std::string& cmd_line) {
    std::istringstream iss(cmd_line);
    std::string cmd;
    iss >> cmd;

    if (cmd == "PING") {
        // Return "pong" in both message and data fields (Limbo client checks data)
        send_all(fd, "{\"status\":\"ok\",\"message\":\"pong\",\"data\":\"pong\"}\n");
    }
    else if (cmd == "STATUS") {
        std::string msg = g_state.model
            ? "Model loaded: " + g_state.model_path
            : "No model loaded";
        send_response(fd, "ok", msg);
    }
    else if (cmd == "LOAD") {
        std::string path;
        std::getline(iss, path);
        size_t s = path.find_first_not_of(" \t");
        if (s != std::string::npos) path = path.substr(s);

        if (path.empty())          send_response(fd, "error", "No model path provided");
        else if (load_model(path)) send_response(fd, "ok",    "Model loaded successfully");
        else                       send_response(fd, "error", "Failed to load model: " + path);
    }
    else if (cmd == "INFER") {
        std::string rest;
        std::getline(iss, rest);
        size_t s = rest.find_first_not_of(" \t");
        if (s != std::string::npos) rest = rest.substr(s);

        if (rest.empty()) { send_response(fd, "error", "No prompt provided"); return; }

        auto [params, prompt] = parse_infer_args(rest);
        if (prompt.empty()) { send_response(fd, "error", "No prompt after parameters"); return; }

        std::string result = perform_inference(prompt, params);
        if (result.substr(0, 6) == "ERROR:")
            send_response(fd, "error", result.substr(7));
        else
            send_response(fd, "ok", "Inference completed", result);
    }
    else if (cmd == "INFER_STREAM") {
        std::string rest;
        std::getline(iss, rest);
        size_t s = rest.find_first_not_of(" \t");
        if (s != std::string::npos) rest = rest.substr(s);

        if (rest.empty()) { send_response(fd, "error", "No prompt provided"); return; }

        auto [params, prompt] = parse_infer_args(rest);
        if (prompt.empty()) { send_response(fd, "error", "No prompt after parameters"); return; }

        perform_streaming_inference(fd, prompt, params);
    }
    else if (cmd == "INFER_MULTI") {
        // Syntax: INFER_MULTI [params] <prompt1>||<prompt2>||...
        std::string rest;
        std::getline(iss, rest);
        size_t s = rest.find_first_not_of(" \t");
        if (s != std::string::npos) rest = rest.substr(s);

        if (rest.empty()) { send_response(fd, "error", "No prompts provided"); return; }

        auto [params, prompts_str] = parse_infer_args(rest);
        if (prompts_str.empty()) { send_response(fd, "error", "No prompts after parameters"); return; }

        // Split prompts by "||", skip empty segments
        std::vector<std::string> prompts;
        size_t pos = 0;
        while (pos < prompts_str.size()) {
            size_t sep = prompts_str.find("||", pos);
            if (sep == std::string::npos) {
                std::string seg = prompts_str.substr(pos);
                if (!seg.empty()) prompts.push_back(seg);
                break;
            }
            std::string seg = prompts_str.substr(pos, sep - pos);
            if (!seg.empty()) prompts.push_back(seg);
            pos = sep + 2;
        }

        std::string json_arr = "[";
        for (size_t i = 0; i < prompts.size(); i++) {
            if (i) json_arr += ",";
            std::string r = perform_inference(prompts[i], params);
            json_arr += "\"" + escape_json(r) + "\"";
        }
        json_arr += "]";

        send_response(fd, "ok", "Multi-inference completed", json_arr);
    }
    else if (cmd == "FREE") {
        cleanup_model();
        send_response(fd, "ok", "Resources freed");
    }
    else if (cmd == "QUIT") {
        send_response(fd, "ok", "Goodbye");
        g_state.running = false;
    }
    else {
        send_response(fd, "error", "Unknown command: " + cmd);
    }
}

// ---------------------------------------------------------------------------
// Per-client connection handler
// ---------------------------------------------------------------------------
static void handle_client(int fd) {
    char        buf[8192];
    std::string accumulated;

    while (g_state.running) {
        ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
        if (n <= 0) break;

        buf[n] = '\0';
        accumulated += buf;

        size_t pos;
        while ((pos = accumulated.find('\n')) != std::string::npos) {
            std::string line = accumulated.substr(0, pos);
            accumulated      = accumulated.substr(pos + 1);
            // Strip carriage return
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) handle_command(fd, line);
        }
    }

    close(fd);
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int main(int argc, char** argv) {
    // Parse command-line options
    for (int i = 1; i < argc; i++) {
        std::string arg(argv[i]);
        if ((arg == "--socket-path" || arg == "-s") && i + 1 < argc) {
            g_state.socket_path = argv[++i];
        } else if (arg == "--help" || arg == "-h") {
            std::cout << "Usage: llama-cpp-bridge [--socket-path <path>]\n"
                      << "  --socket-path  Unix socket path "
                      << "(default: " << DEFAULT_SOCKET_PATH << ")\n";
            return 0;
        }
    }

    std::cout << "llama-cpp-bridge starting...\n"
              << "Socket: " << g_state.socket_path << std::endl;

    signal(SIGINT,  signal_handler);
    signal(SIGTERM, signal_handler);

    int srv_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (srv_fd < 0) { std::cerr << "Failed to create socket\n"; return 1; }

    unlink(g_state.socket_path);

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, g_state.socket_path, sizeof(addr.sun_path) - 1);

    if (bind(srv_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        std::cerr << "Failed to bind socket to " << g_state.socket_path << "\n";
        close(srv_fd);
        return 1;
    }
    if (listen(srv_fd, MAX_CONNECTIONS) < 0) {
        std::cerr << "Failed to listen on socket\n";
        close(srv_fd);
        return 1;
    }

    std::cout << "Bridge listening on " << g_state.socket_path << std::endl;

    while (g_state.running) {
        int cli_fd = accept(srv_fd, nullptr, nullptr);
        if (cli_fd < 0) {
            if (g_state.running) std::cerr << "Failed to accept connection\n";
            continue;
        }
        std::cout << "Client connected" << std::endl;
        handle_client(cli_fd);
        std::cout << "Client disconnected" << std::endl;
    }

    cleanup();
    close(srv_fd);
    unlink(g_state.socket_path);

    std::cout << "Bridge shutdown complete" << std::endl;
    return 0;
}
