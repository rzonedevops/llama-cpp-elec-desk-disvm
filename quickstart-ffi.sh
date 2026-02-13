#!/bin/bash
# Quick start script for Llambo FFI Bridge
# This script helps users get started with the FFI bridge integration

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}Llambo FFI Bridge Quick Start${NC}"
echo -e "${GREEN}====================================${NC}"
echo ""

# Check prerequisites
echo -e "${YELLOW}Checking prerequisites...${NC}"

# Check for C++ compiler
if ! command -v g++ &> /dev/null && ! command -v clang++ &> /dev/null; then
    echo -e "${RED}Error: C++ compiler (g++ or clang++) not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ C++ compiler found${NC}"

# Check for make
if ! command -v make &> /dev/null; then
    echo -e "${RED}Error: make not found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ make found${NC}"

# Check for llama.cpp
if [ ! -d "llama.cpp" ]; then
    echo -e "${YELLOW}llama.cpp not found. Cloning...${NC}"
    git clone https://github.com/ggerganov/llama.cpp.git
fi
echo -e "${GREEN}✓ llama.cpp directory exists${NC}"

# Build llama.cpp if needed
if [ ! -f "llama.cpp/build/libllama.a" ]; then
    echo -e "${YELLOW}Building llama.cpp...${NC}"
    cd llama.cpp
    mkdir -p build
    cd build
    cmake ..
    cmake --build . --config Release
    cd ../..
    echo -e "${GREEN}✓ llama.cpp built successfully${NC}"
else
    echo -e "${GREEN}✓ llama.cpp already built${NC}"
fi

# Build the bridge
echo ""
echo -e "${YELLOW}Building FFI bridge...${NC}"
cd inferno
make clean || true
make
cd ..
echo -e "${GREEN}✓ FFI bridge built successfully${NC}"

# Check if we should start the bridge
echo ""
echo -e "${YELLOW}Would you like to start the bridge now? (y/n)${NC}"
read -r response

if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo -e "${YELLOW}Starting bridge...${NC}"
    cd inferno
    ./deploy.sh start-bridge
    cd ..
    echo ""
    echo -e "${GREEN}✓ Bridge started successfully!${NC}"
    echo ""
    echo -e "${GREEN}Next steps:${NC}"
    echo "1. Test the bridge:"
    echo "   cd inferno && ./deploy.sh test-ffi"
    echo ""
    echo "2. Test with a model:"
    echo "   cd inferno && ./deploy.sh test-ffi /path/to/your/model.gguf"
    echo ""
    echo "3. Check bridge status:"
    echo "   cd inferno && ./deploy.sh status"
    echo ""
    echo "4. Stop the bridge:"
    echo "   cd inferno && ./deploy.sh stop-bridge"
    echo ""
else
    echo ""
    echo -e "${GREEN}Bridge built but not started.${NC}"
    echo ""
    echo -e "${GREEN}To start the bridge manually:${NC}"
    echo "   cd inferno && ./deploy.sh start-bridge"
    echo ""
fi

echo -e "${GREEN}====================================${NC}"
echo -e "${GREEN}Setup Complete!${NC}"
echo -e "${GREEN}====================================${NC}"
echo ""
echo "For more information, see:"
echo "  - inferno/FFI-README.md - Complete FFI documentation"
echo "  - README.md - Project overview"
echo "  - IMPLEMENTATION-SUMMARY.md - Implementation details"
echo ""
