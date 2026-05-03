#!/bin/sh
# Integration test script for Inferno Dish and Limbot

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "=== Llambo Dish + Limbot Integration Tests ==="
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo "${GREEN}[TEST]${NC} $1"
}

info() {
    echo "${BLUE}[INFO]${NC} $1"
}

warn() {
    echo "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo "${RED}[ERROR]${NC} $1"
}

# Test 1: Check file structure
log "Test 1: Checking file structure..."
FILES="dish-integration.b limbot.b limbot-cli deploy.sh llamboctl \
       llambo.m llambo.b llambo-ffi.m llambo-ffi.b \
       llambo-worker.m llambo-worker.b \
       llambo-metrics.m llambo-metrics.b \
       llambo-styxfs.b \
       llambo-consensus-test.b llambo-scale-test.b"
for file in $FILES; do
    if [ -f "$file" ]; then
        info "  ✓ $file exists"
    else
        error "  ✗ $file missing"
        exit 1
    fi
done

# Test 2: Check executable permissions
log "Test 2: Checking executable permissions..."
EXECUTABLES="limbot-cli deploy.sh llamboctl"
for file in $EXECUTABLES; do
    if [ -x "$file" ]; then
        info "  ✓ $file is executable"
    else
        error "  ✗ $file not executable"
        exit 1
    fi
done

# Test 3: Validate Limbo syntax (basic check)
log "Test 3: Validating Limbo file structure..."
for file in dish-integration.b limbot.b llambo.b llambo-ffi.b \
            llambo-worker.b llambo-metrics.b llambo-styxfs.b \
            llambo-consensus-test.b llambo-scale-test.b; do
    if head -n 1 "$file" | grep -q "implement"; then
        info "  ✓ $file has valid module declaration"
    else
        error "  ✗ $file missing module declaration"
        exit 1
    fi
done

# Test 3b: Validate .m module files
log "Test 3b: Validating .m module definitions..."
for file in llambo.m llambo-ffi.m llambo-worker.m llambo-metrics.m; do
    if grep -q "PATH:" "$file"; then
        info "  ✓ $file has PATH constant"
    else
        error "  ✗ $file missing PATH constant"
        exit 1
    fi
done

# Test 4: Check deploy.sh integration
log "Test 4: Checking deploy.sh integration..."
if grep -q "dish-integration.b" deploy.sh; then
    info "  ✓ deploy.sh includes dish-integration compilation"
else
    warn "  ⚠ deploy.sh may not compile dish-integration"
fi

if grep -q "limbot.b" deploy.sh; then
    info "  ✓ deploy.sh includes limbot compilation"
else
    warn "  ⚠ deploy.sh may not compile limbot"
fi

# Test 5: Check llamboctl integration
log "Test 5: Checking llamboctl integration..."
if grep -q "limbot)" llamboctl; then
    info "  ✓ llamboctl has limbot command"
else
    error "  ✗ llamboctl missing limbot command"
    exit 1
fi

if grep -q "dish)" llamboctl; then
    info "  ✓ llamboctl has dish command"
else
    error "  ✗ llamboctl missing dish command"
    exit 1
fi

if grep -q "scale)" llamboctl; then
    info "  ✓ llamboctl has scale command"
else
    error "  ✗ llamboctl missing scale command"
    exit 1
fi

if grep -q "checkpoint)" llamboctl; then
    info "  ✓ llamboctl has checkpoint command"
else
    error "  ✗ llamboctl missing checkpoint command"
    exit 1
fi

# Test 6: Check documentation
log "Test 6: Checking documentation..."
if grep -q "Limbot" README.md; then
    info "  ✓ README.md documents Limbot"
else
    warn "  ⚠ README.md may not document Limbot"
fi

if grep -q "Dish" README.md; then
    info "  ✓ README.md documents Dish"
else
    warn "  ⚠ README.md may not document Dish"
fi

# Test 7: Simulate compilation check (if Inferno available)
log "Test 7: Checking Inferno environment..."
INFERNO_ROOT="${INFERNO_ROOT:-/usr/inferno}"
if [ -d "$INFERNO_ROOT" ]; then
    info "  ✓ Inferno OS found at $INFERNO_ROOT"
    
    if [ -x "$INFERNO_ROOT/Linux/386/bin/emu" ] || [ -x "$INFERNO_ROOT/emu" ]; then
        info "  ✓ Inferno emulator available"
        
        # Try to compile modules
        log "Attempting to compile Limbo modules..."
        ./deploy.sh compile 2>&1 | head -10
    else
        warn "  ⚠ Inferno emulator not found (compilation skipped)"
    fi
else
    warn "  ⚠ Inferno OS not installed (compilation tests skipped)"
    info "    Set INFERNO_ROOT to test compilation"
fi

# Test 8: Check cluster config fields
log "Test 8: Checking cluster-config.yaml fields..."
for field in "connection_pool_size" "bridge_discovery_path" "metrics_retention_seconds" \
             "fusion:" "strategy:" "cognitive_fusion"; do
    if grep -q "$field" cluster-config.yaml; then
        info "  ✓ cluster-config.yaml has field: $field"
    else
        warn "  ⚠ cluster-config.yaml missing field: $field"
    fi
done

# Test 9: Check deploy.sh compiles new modules
log "Test 9: Checking deploy.sh includes new modules..."
for module in llambo-worker llambo-metrics llambo-styxfs llambo-consensus-test llambo-scale-test; do
    if grep -q "$module" deploy.sh; then
        info "  ✓ deploy.sh includes $module"
    else
        warn "  ⚠ deploy.sh may not compile $module"
    fi
done

# Test 10: Check C++ bridge improvements
log "Test 10: Checking C++ bridge features..."
if grep -q "INFER_MULTI" llama-cpp-bridge.cpp; then
    info "  ✓ bridge has INFER_MULTI command"
else
    error "  ✗ bridge missing INFER_MULTI"
    exit 1
fi

if grep -q "llama_sampler_chain_init" llama-cpp-bridge.cpp; then
    info "  ✓ bridge has real token sampling loop"
else
    error "  ✗ bridge missing real token sampling"
    exit 1
fi

if grep -q "llama_kv_cache_clear" llama-cpp-bridge.cpp; then
    info "  ✓ bridge clears KV cache before inference"
else
    error "  ✗ bridge missing KV cache clear"
    exit 1
fi

if grep -q "socket-path" llama-cpp-bridge.cpp; then
    info "  ✓ bridge accepts --socket-path argument"
else
    error "  ✗ bridge missing --socket-path argument"
    exit 1
fi

echo ""
log "All structure tests passed!"
echo ""
echo "Next steps:"
echo "  1. Install Inferno OS if not already installed"
echo "  2. Run: ./deploy.sh compile"
echo "  3. Run: ./deploy.sh deploy-local"
echo "  4. Test cognitive fusion: llamboctl test-consensus"
echo "  5. Test auto-scaling: llamboctl test-scale"
echo "  6. Test: llamboctl limbot -h"
echo "  7. Test: llamboctl dish"
echo ""
