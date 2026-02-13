# Makefile for llama-cpp-bridge
# Builds the C++ bridge service for Inferno/Limbo integration

CXX ?= g++
CXXFLAGS = -std=c++17 -O3 -Wall -Wextra -pthread
LDFLAGS = -pthread

# llama.cpp paths
LLAMA_DIR = ../llama.cpp
LLAMA_BUILD_DIR = $(LLAMA_DIR)/build
LLAMA_INCLUDE = $(LLAMA_DIR)
LLAMA_LIB = $(LLAMA_BUILD_DIR)/libllama.a

# Target
TARGET = llama-cpp-bridge

# Sources
SOURCES = llama-cpp-bridge.cpp

# Default target
all: $(TARGET)

# Build the bridge
$(TARGET): $(SOURCES)
	@echo "Building llama-cpp-bridge..."
	@if [ ! -f "$(LLAMA_LIB)" ]; then \
		echo "Error: llama.cpp library not found at $(LLAMA_LIB)"; \
		echo "Please build llama.cpp first:"; \
		echo "  cd ../llama.cpp && mkdir -p build && cd build && cmake .. && make"; \
		exit 1; \
	fi
	$(CXX) $(CXXFLAGS) -I$(LLAMA_INCLUDE) -o $(TARGET) $(SOURCES) $(LLAMA_LIB) $(LDFLAGS)
	@echo "Build complete: $(TARGET)"

# Clean build artifacts
clean:
	rm -f $(TARGET)

# Install (copy to system location or keep local)
install: $(TARGET)
	@echo "Installing $(TARGET)..."
	@mkdir -p ./bin
	cp $(TARGET) ./bin/
	@echo "Installed to ./bin/$(TARGET)"

# Test the bridge
test: $(TARGET)
	@echo "Testing llama-cpp-bridge..."
	@./$(TARGET) &
	@BRIDGE_PID=$$!; \
	sleep 2; \
	echo "PING" | nc -U /tmp/llama-cpp-bridge.sock || true; \
	kill $$BRIDGE_PID 2>/dev/null || true

.PHONY: all clean install test
