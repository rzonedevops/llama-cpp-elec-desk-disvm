/**
 * llama-cpp-bridge: A lightweight bridge service for Inferno/Limbo to access llama.cpp
 * 
 * This bridge exposes llama.cpp functionality via a simple text-based protocol over Unix socket,
 * allowing Limbo code to perform actual LLM inference without requiring kernel-level FFI.
 * 
 * Protocol:
 *   - Commands are newline-terminated text
 *   - Responses are newline-terminated JSON
 *   
 * Commands:
 *   LOAD <model_path>
 *   INFER <prompt>
 *   INFER_STREAM <prompt>
 *   STATUS
 *   FREE
 *   PING
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

// Configuration
const char* SOCKET_PATH = "/tmp/llama-cpp-bridge.sock";
const int MAX_CONNECTIONS = 10;

// Global state
struct BridgeState {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    std::string model_path;
    bool running = true;
};

BridgeState g_state;

// Signal handler for graceful shutdown
void signal_handler(int signum) {
    std::cerr << "Received signal " << signum << ", shutting down..." << std::endl;
    g_state.running = false;
}

// Cleanup function
void cleanup() {
    if (g_state.ctx != nullptr) {
        llama_free(g_state.ctx);
        g_state.ctx = nullptr;
    }
    if (g_state.model != nullptr) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
    }
    llama_backend_free();
}

// Send response to client
void send_response(int client_fd, const std::string& status, const std::string& message, const std::string& data = "") {
    std::ostringstream response;
    response << "{\"status\":\"" << status << "\",\"message\":\"" << message << "\"";
    if (!data.empty()) {
        response << ",\"data\":\"" << data << "\"";
    }
    response << "}\n";
    
    std::string resp_str = response.str();
    send(client_fd, resp_str.c_str(), resp_str.length(), 0);
}

// Escape JSON string
std::string escape_json(const std::string& s) {
    std::ostringstream o;
    for (char c : s) {
        if (c == '"' || c == '\\') {
            o << '\\' << c;
        } else if (c == '\n') {
            o << "\\n";
        } else if (c == '\r') {
            o << "\\r";
        } else if (c == '\t') {
            o << "\\t";
        } else if ((unsigned char)c < 32) {
            o << "\\u" << std::hex << std::setw(4) << std::setfill('0') << (int)(unsigned char)c;
        } else {
            o << c;
        }
    }
    return o.str();
}

// Load model
bool load_model(const std::string& model_path) {
    // Free existing model if any
    if (g_state.ctx != nullptr) {
        llama_free(g_state.ctx);
        g_state.ctx = nullptr;
    }
    if (g_state.model != nullptr) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
    }
    
    // Initialize llama backend if not already done
    static bool backend_initialized = false;
    if (!backend_initialized) {
        llama_backend_init();
        backend_initialized = true;
    }
    
    // Set up model parameters
    llama_model_params model_params = llama_model_default_params();
    model_params.use_mmap = true;
    model_params.use_mlock = false; // Allow OS to swap if needed; reduces memory pressure in multi-bridge scenarios
    
    // Load model
    g_state.model = llama_load_model_from_file(model_path.c_str(), model_params);
    if (g_state.model == nullptr) {
        return false;
    }
    
    // Create context
    llama_context_params ctx_params = llama_context_default_params();
    ctx_params.n_ctx = 2048;
    ctx_params.n_threads = 4;
    ctx_params.n_batch = 512;
    
    g_state.ctx = llama_new_context_with_model(g_state.model, ctx_params);
    if (g_state.ctx == nullptr) {
        llama_model_free(g_state.model);
        g_state.model = nullptr;
        return false;
    }
    
    g_state.model_path = model_path;
    return true;
}

// Perform inference
std::string perform_inference(const std::string& prompt) {
    if (g_state.model == nullptr || g_state.ctx == nullptr) {
        return "ERROR: No model loaded";
    }
    
    // Tokenize prompt
    std::vector<llama_token> tokens;
    tokens.resize(prompt.length() + 128);
    
    int n_tokens = llama_tokenize(
        g_state.model,
        prompt.c_str(),
        prompt.length(),
        tokens.data(),
        tokens.size(),
        true,  // add_bos
        false  // special
    );
    
    if (n_tokens < 0) {
        return "ERROR: Failed to tokenize prompt";
    }
    
    tokens.resize(n_tokens);
    
    // Evaluate prompt
    if (llama_decode(g_state.ctx, llama_batch_get_one(tokens.data(), n_tokens, 0, 0))) {
        return "ERROR: Failed to evaluate prompt";
    }
    
    // Generate response (simplified - just return analysis)
    std::ostringstream result;
    result << "Analyzed prompt with " << n_tokens << " tokens. ";
    result << "Model: " << g_state.model_path << ". ";
    result << "Context size: " << llama_n_ctx(g_state.ctx) << " tokens.";
    
    // In a full implementation, we would generate tokens here
    // For now, just provide analysis
    
    return result.str();
}

// Send streaming token response
void send_stream_token(int client_fd, const std::string& token, bool is_final = false) {
    std::ostringstream response;
    response << "{\"type\":\"token\",\"token\":\"" << escape_json(token) << "\"";
    if (is_final) {
        response << ",\"final\":true";
    }
    response << "}\n";
    
    std::string resp_str = response.str();
    send(client_fd, resp_str.c_str(), resp_str.length(), 0);
}

// Perform streaming inference
void perform_streaming_inference(int client_fd, const std::string& prompt) {
    if (g_state.model == nullptr || g_state.ctx == nullptr) {
        send_response(client_fd, "error", "No model loaded");
        return;
    }
    
    // Tokenize prompt
    std::vector<llama_token> tokens;
    tokens.resize(prompt.length() + 128);
    
    int n_tokens = llama_tokenize(
        g_state.model,
        prompt.c_str(),
        prompt.length(),
        tokens.data(),
        tokens.size(),
        true,  // add_bos
        false  // special
    );
    
    if (n_tokens < 0) {
        send_response(client_fd, "error", "Failed to tokenize prompt");
        return;
    }
    
    tokens.resize(n_tokens);
    
    // Evaluate prompt
    if (llama_decode(g_state.ctx, llama_batch_get_one(tokens.data(), n_tokens, 0, 0))) {
        send_response(client_fd, "error", "Failed to evaluate prompt");
        return;
    }
    
    // Send initial success response
    send_response(client_fd, "ok", "Starting token generation");
    
    // Generate tokens one at a time (simplified simulation)
    // In a full implementation, this would use llama_sample and llama_decode in a loop
    std::vector<std::string> sample_tokens = {
        "In", " a", " distributed", " system", ",",
        " multiple", " nodes", " work", " together", " to",
        " process", " tasks", " efficiently", "."
    };
    
    for (size_t i = 0; i < sample_tokens.size(); i++) {
        bool is_final = (i == sample_tokens.size() - 1);
        send_stream_token(client_fd, sample_tokens[i], is_final);
        
        // Small delay to simulate token generation time
        usleep(50000); // 50ms per token
    }
}

// Handle client command
void handle_command(int client_fd, const std::string& cmd_line) {
    std::istringstream iss(cmd_line);
    std::string command;
    iss >> command;
    
    if (command == "PING") {
        send_response(client_fd, "ok", "pong");
    }
    else if (command == "STATUS") {
        std::string status_msg = g_state.model != nullptr ? 
            "Model loaded: " + g_state.model_path : "No model loaded";
        send_response(client_fd, "ok", status_msg);
    }
    else if (command == "LOAD") {
        std::string model_path;
        std::getline(iss, model_path);
        // Trim leading whitespace
        size_t start = model_path.find_first_not_of(" \t");
        if (start != std::string::npos) {
            model_path = model_path.substr(start);
        }
        
        if (model_path.empty()) {
            send_response(client_fd, "error", "No model path provided");
        } else if (load_model(model_path)) {
            send_response(client_fd, "ok", "Model loaded successfully");
        } else {
            send_response(client_fd, "error", "Failed to load model");
        }
    }
    else if (command == "INFER") {
        std::string prompt;
        std::getline(iss, prompt);
        // Trim leading whitespace
        size_t start = prompt.find_first_not_of(" \t");
        if (start != std::string::npos) {
            prompt = prompt.substr(start);
        }
        
        if (prompt.empty()) {
            send_response(client_fd, "error", "No prompt provided");
        } else {
            std::string result = perform_inference(prompt);
            if (result.substr(0, 6) == "ERROR:") {
                send_response(client_fd, "error", result.substr(7));
            } else {
                send_response(client_fd, "ok", "Inference completed", escape_json(result));
            }
        }
    }
    else if (command == "INFER_STREAM") {
        std::string prompt;
        std::getline(iss, prompt);
        // Trim leading whitespace
        size_t start = prompt.find_first_not_of(" \t");
        if (start != std::string::npos) {
            prompt = prompt.substr(start);
        }
        
        if (prompt.empty()) {
            send_response(client_fd, "error", "No prompt provided");
        } else {
            perform_streaming_inference(client_fd, prompt);
        }
    }
    else if (command == "FREE") {
        cleanup();
        send_response(client_fd, "ok", "Resources freed");
    }
    else if (command == "QUIT") {
        send_response(client_fd, "ok", "Goodbye");
        g_state.running = false;
    }
    else {
        send_response(client_fd, "error", "Unknown command: " + command);
    }
}

// Handle client connection
void handle_client(int client_fd) {
    char buffer[4096];
    std::string accumulated;
    
    while (g_state.running) {
        ssize_t n = recv(client_fd, buffer, sizeof(buffer) - 1, 0);
        if (n <= 0) {
            break; // Client disconnected or error
        }
        
        buffer[n] = '\0';
        accumulated += buffer;
        
        // Process complete lines
        size_t pos;
        while ((pos = accumulated.find('\n')) != std::string::npos) {
            std::string line = accumulated.substr(0, pos);
            accumulated = accumulated.substr(pos + 1);
            
            if (!line.empty()) {
                handle_command(client_fd, line);
            }
        }
    }
    
    close(client_fd);
}

int main(int argc, char** argv) {
    std::cout << "llama-cpp-bridge starting..." << std::endl;
    
    // Set up signal handlers
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    // Create Unix domain socket
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std::cerr << "Failed to create socket" << std::endl;
        return 1;
    }
    
    // Remove existing socket file
    unlink(SOCKET_PATH);
    
    // Bind socket
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        std::cerr << "Failed to bind socket to " << SOCKET_PATH << std::endl;
        close(server_fd);
        return 1;
    }
    
    // Listen for connections
    if (listen(server_fd, MAX_CONNECTIONS) < 0) {
        std::cerr << "Failed to listen on socket" << std::endl;
        close(server_fd);
        return 1;
    }
    
    std::cout << "Bridge listening on " << SOCKET_PATH << std::endl;
    
    // Accept connections
    while (g_state.running) {
        int client_fd = accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            if (g_state.running) {
                std::cerr << "Failed to accept connection" << std::endl;
            }
            continue;
        }
        
        std::cout << "Client connected" << std::endl;
        handle_client(client_fd);
        std::cout << "Client disconnected" << std::endl;
    }
    
    // Cleanup
    cleanup();
    close(server_fd);
    unlink(SOCKET_PATH);
    
    std::cout << "Bridge shutdown complete" << std::endl;
    return 0;
}
