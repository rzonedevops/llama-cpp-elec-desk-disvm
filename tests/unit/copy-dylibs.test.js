'use strict';

// Unit tests for scripts/copy-dylibs.js
//
// The script is not exported as a module — it executes immediately when
// require()d.  We therefore:
//   1. Mock `fs` and `child_process` before loading the script.
//   2. Reset mocks and re-require the script for each test group.

const path = require('path');

// ── helpers ──────────────────────────────────────────────────────────────────

/** Re-require the script with a clean module cache entry. */
function loadScript() {
  jest.isolateModules(() => {
    require('../../scripts/copy-dylibs');
  });
}

// ── mock setup ───────────────────────────────────────────────────────────────

jest.mock('fs');
jest.mock('child_process');

const fs = require('fs');
const { execSync } = require('child_process');

const SOURCE_DIR = path.resolve(__dirname, '../../llama.cpp/build/bin');
const TARGET_DIR = path.resolve(__dirname, '../../src/addon/build/Release');

// ── tests ────────────────────────────────────────────────────────────────────

beforeEach(() => {
  jest.resetAllMocks();
  // Default: target directory already exists
  fs.existsSync = jest.fn(() => false);
  fs.mkdirSync = jest.fn();
  fs.copyFileSync = jest.fn();
  execSync.mockImplementation(() => {});
});

describe('copy-dylibs.js — directory creation', () => {
  test('creates the target directory when it does not exist', () => {
    fs.existsSync.mockReturnValue(false);

    loadScript();

    expect(fs.mkdirSync).toHaveBeenCalledWith(TARGET_DIR, { recursive: true });
  });

  test('does not recreate target directory when it already exists', () => {
    // existsSync returns true for the directory check and false for all libraries
    let callCount = 0;
    fs.existsSync.mockImplementation((p) => {
      if (p === TARGET_DIR) return true;
      return false;
    });

    loadScript();

    expect(fs.mkdirSync).not.toHaveBeenCalled();
  });
});

describe('copy-dylibs.js — library copying', () => {
  const libs = ['libllama.dylib', 'libggml.dylib', 'libggml-metal.dylib'];

  test('copies each library that exists in the source directory', () => {
    fs.existsSync.mockImplementation((p) => {
      // Source libraries exist; target dir exists
      return true;
    });

    loadScript();

    libs.forEach((lib) => {
      const src = path.join(SOURCE_DIR, lib);
      const dst = path.join(TARGET_DIR, lib);
      expect(fs.copyFileSync).toHaveBeenCalledWith(src, dst);
    });
  });

  test('does not copy a library that is missing from the source directory', () => {
    // Only libggml.dylib exists
    fs.existsSync.mockImplementation((p) => {
      if (p === path.join(SOURCE_DIR, 'libggml.dylib')) return true;
      return false;
    });

    loadScript();

    expect(fs.copyFileSync).toHaveBeenCalledTimes(1);
    expect(fs.copyFileSync).toHaveBeenCalledWith(
      path.join(SOURCE_DIR, 'libggml.dylib'),
      path.join(TARGET_DIR, 'libggml.dylib')
    );
  });

  test('skips copy when no source libraries exist', () => {
    fs.existsSync.mockReturnValue(false);

    loadScript();

    expect(fs.copyFileSync).not.toHaveBeenCalled();
  });
});

describe('copy-dylibs.js — install_name_tool path fixups', () => {
  test('runs install_name_tool -id for each copied library', () => {
    fs.existsSync.mockReturnValue(true);

    loadScript();

    const libs = ['libllama.dylib', 'libggml.dylib', 'libggml-metal.dylib'];
    libs.forEach((lib) => {
      const dst = path.join(TARGET_DIR, lib);
      expect(execSync).toHaveBeenCalledWith(
        `install_name_tool -id @loader_path/${lib} ${dst}`
      );
    });
  });

  test('patches libllama.dylib rpath references to libggml and libggml-metal', () => {
    fs.existsSync.mockReturnValue(true);

    loadScript();

    const dst = path.join(TARGET_DIR, 'libllama.dylib');
    expect(execSync).toHaveBeenCalledWith(
      `install_name_tool -change @rpath/libggml.dylib @loader_path/libggml.dylib ${dst}`
    );
    expect(execSync).toHaveBeenCalledWith(
      `install_name_tool -change @rpath/libggml-metal.dylib @loader_path/libggml-metal.dylib ${dst}`
    );
  });

  test('does not patch rpath references for libggml.dylib', () => {
    fs.existsSync.mockReturnValue(true);

    loadScript();

    const dst = path.join(TARGET_DIR, 'libggml.dylib');
    // Only the -id call; no -change calls for libggml itself
    const changeCalls = execSync.mock.calls.filter(
      ([cmd]) => cmd.includes(dst) && cmd.includes('-change')
    );
    expect(changeCalls).toHaveLength(0);
  });

  test('does not patch rpath references for libggml-metal.dylib', () => {
    fs.existsSync.mockReturnValue(true);

    loadScript();

    const dst = path.join(TARGET_DIR, 'libggml-metal.dylib');
    const changeCalls = execSync.mock.calls.filter(
      ([cmd]) => cmd.includes(dst) && cmd.includes('-change')
    );
    expect(changeCalls).toHaveLength(0);
  });
});

describe('copy-dylibs.js — install_name_tool error handling', () => {
  test('continues processing remaining libraries when install_name_tool throws', () => {
    fs.existsSync.mockReturnValue(true);

    // Make the tool fail for libllama.dylib only
    execSync.mockImplementation((cmd) => {
      if (cmd.includes('libllama.dylib')) {
        throw new Error('install_name_tool failed');
      }
    });

    // Should not throw
    expect(() => loadScript()).not.toThrow();

    // libggml and libggml-metal should still be processed
    const idCalls = execSync.mock.calls.filter(([cmd]) => cmd.includes('-id'));
    expect(idCalls.length).toBeGreaterThanOrEqual(1);
  });
});
