'use strict';

// Unit tests for src/main.js
//
// main.js registers ipcMain handlers and uses:
//   - electron (app, BrowserWindow, ipcMain, dialog)  — via moduleNameMapper mock
//   - fs (existsSync)
//   - path
//   - the native llama addon (llama_addon.node)       — via moduleNameMapper mock
//
// We mock all external dependencies so the test suite runs without Electron or
// a compiled C++ addon.

// ── fs mock ──────────────────────────────────────────────────────────────────

jest.mock('fs');

// ── module imports ────────────────────────────────────────────────────────────

const path = require('path');
const fs = require('fs');
const { app, ipcMain, dialog } = require('electron');
// The addon mock is loaded via moduleNameMapper (llama_addon.node → __mocks__/llama_addon.js)
const addonMock = require('../../src/addon/build/Release/llama_addon.node');

// ── Load main.js ─────────────────────────────────────────────────────────────

// main.js runs top-level code (addon load, event registration) on require().
// We load it once after all mocks are in place.
let mockProcessPrompt;
let mockGetWorkerLog;

beforeAll(() => {
  // Provide a stubbed fs.existsSync so file checks work predictably.
  fs.existsSync = jest.fn(() => true);

  require('../../src/main');

  // Grab references to the mock functions from the mapped module
  mockProcessPrompt = addonMock.processPrompt;
  mockGetWorkerLog = addonMock.getWorkerLog;
});

afterEach(() => {
  jest.clearAllMocks();
  // Reset existsSync back to a permissive default
  fs.existsSync.mockReturnValue(true);
});

// ── Helper: invoke a registered ipcMain handler ──────────────────────────────

function invokeHandler(channel, ...args) {
  return ipcMain._invoke(channel, {}, ...args);
}

// ── process-prompt handler ───────────────────────────────────────────────────

describe('ipcMain handler: process-prompt', () => {
  test('resolves with the addon result for an absolute model path', async () => {
    const modelPath = '/absolute/path/to/model.gguf';
    const prompt = 'Hello';
    fs.existsSync.mockReturnValue(true);
    mockProcessPrompt.mockImplementation((_mp, _p, cb) => cb(null, 'generated text'));

    const result = await invokeHandler('process-prompt', modelPath, prompt);

    expect(result).toBe('generated text');
    expect(mockProcessPrompt).toHaveBeenCalledWith(modelPath, prompt, expect.any(Function));
  });

  test('converts a relative model path to an absolute path using app.getAppPath()', async () => {
    const relPath = 'my-model.gguf';
    const prompt = 'test prompt';
    fs.existsSync.mockReturnValue(true);
    mockProcessPrompt.mockImplementation((_mp, _p, cb) => cb(null, 'ok'));
    app.getAppPath.mockReturnValue('/app/root');

    await invokeHandler('process-prompt', relPath, prompt);

    // The absolute path is built as: path.join(app.getAppPath(), '..', 'models', relPath)
    const expectedAbsPath = path.join('/app/root', '..', 'models', relPath);
    expect(mockProcessPrompt).toHaveBeenCalledWith(expectedAbsPath, prompt, expect.any(Function));
  });

  test('throws when the model file does not exist', async () => {
    const modelPath = '/nonexistent/model.gguf';
    fs.existsSync.mockReturnValue(false);

    await expect(invokeHandler('process-prompt', modelPath, 'hi')).rejects.toThrow(
      /Model file not found/
    );
    expect(mockProcessPrompt).not.toHaveBeenCalled();
  });

  test('throws when the addon callback returns an error', async () => {
    const modelPath = '/valid/model.gguf';
    fs.existsSync.mockReturnValue(true);
    mockProcessPrompt.mockImplementation((_mp, _p, cb) => cb(new Error('addon error'), null));

    await expect(invokeHandler('process-prompt', modelPath, 'test')).rejects.toThrow('addon error');
  });

  test('propagates arbitrary errors thrown synchronously inside the handler', async () => {
    const modelPath = '/valid/model.gguf';
    fs.existsSync.mockReturnValue(true);
    mockProcessPrompt.mockImplementation(() => {
      throw new Error('sync throw');
    });

    await expect(invokeHandler('process-prompt', modelPath, 'test')).rejects.toThrow('sync throw');
  });

  test('truncates long prompts with "..." in the log message', async () => {
    const modelPath = '/absolute/path/to/model.gguf';
    const longPrompt = 'A'.repeat(60); // 60 characters — exceeds the 50-char threshold
    fs.existsSync.mockReturnValue(true);
    mockProcessPrompt.mockImplementation((_mp, _p, cb) => cb(null, 'result'));

    const consoleSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    await invokeHandler('process-prompt', modelPath, longPrompt);
    const loggedText = consoleSpy.mock.calls.find(([msg]) =>
      typeof msg === 'string' && msg.includes('...')
    );
    expect(loggedText).toBeDefined();
    consoleSpy.mockRestore();
  });
});

// ── get-worker-log handler ───────────────────────────────────────────────────

describe('ipcMain handler: get-worker-log', () => {
  test('returns the log string from the addon', async () => {
    mockGetWorkerLog.mockReturnValue('2024-01-01 - worker started\n');

    const result = await invokeHandler('get-worker-log');

    expect(result).toBe('2024-01-01 - worker started\n');
    expect(mockGetWorkerLog).toHaveBeenCalledTimes(1);
  });

  test('throws when the addon getWorkerLog throws', async () => {
    mockGetWorkerLog.mockImplementation(() => {
      throw new Error('log read failed');
    });

    await expect(invokeHandler('get-worker-log')).rejects.toThrow('log read failed');
  });

  test('returns an empty string when the addon returns empty log', async () => {
    mockGetWorkerLog.mockReturnValue('');

    const result = await invokeHandler('get-worker-log');

    expect(result).toBe('');
  });
});

// ── select-model handler ─────────────────────────────────────────────────────

describe('ipcMain handler: select-model', () => {
  test('returns the selected file path when user picks a file', async () => {
    dialog.showOpenDialog.mockResolvedValue({
      canceled: false,
      filePaths: ['/home/user/model.gguf'],
    });

    const result = await invokeHandler('select-model');

    expect(result).toBe('/home/user/model.gguf');
  });

  test('returns null when the dialog is cancelled', async () => {
    dialog.showOpenDialog.mockResolvedValue({ canceled: true, filePaths: [] });

    const result = await invokeHandler('select-model');

    expect(result).toBeNull();
  });

  test('returns null when filePaths is empty (dialog dismissed without selection)', async () => {
    dialog.showOpenDialog.mockResolvedValue({ canceled: false, filePaths: [] });

    const result = await invokeHandler('select-model');

    expect(result).toBeNull();
  });

  test('throws when dialog.showOpenDialog rejects', async () => {
    dialog.showOpenDialog.mockRejectedValue(new Error('dialog error'));

    await expect(invokeHandler('select-model')).rejects.toThrow('dialog error');
  });

  test('passes .bin and .gguf extensions to the dialog filter', async () => {
    dialog.showOpenDialog.mockResolvedValue({ canceled: true, filePaths: [] });

    await invokeHandler('select-model');

    const [, options] = dialog.showOpenDialog.mock.calls[0];
    const extensions = options.filters.flatMap((f) => f.extensions);
    expect(extensions).toContain('bin');
    expect(extensions).toContain('gguf');
  });

  test('opens a single-file selection dialog', async () => {
    dialog.showOpenDialog.mockResolvedValue({ canceled: true, filePaths: [] });

    await invokeHandler('select-model');

    const [, options] = dialog.showOpenDialog.mock.calls[0];
    expect(options.properties).toContain('openFile');
  });
});

// ── app lifecycle handlers ────────────────────────────────────────────────────

describe('app lifecycle: window-all-closed', () => {
  test('calls app.quit() on non-darwin platforms', () => {
    const originalPlatform = process.platform;
    Object.defineProperty(process, 'platform', { value: 'linux', configurable: true });

    app._emit('window-all-closed');

    expect(app.quit).toHaveBeenCalled();

    Object.defineProperty(process, 'platform', { value: originalPlatform, configurable: true });
  });

  test('does not call app.quit() on darwin (macOS)', () => {
    const originalPlatform = process.platform;
    Object.defineProperty(process, 'platform', { value: 'darwin', configurable: true });

    app._emit('window-all-closed');

    expect(app.quit).not.toHaveBeenCalled();

    Object.defineProperty(process, 'platform', { value: originalPlatform, configurable: true });
  });
});

describe('app lifecycle: activate', () => {
  test('creates a new window when no windows are open', async () => {
    // Wait for app.whenReady().then() to have registered the activate handler
    await Promise.resolve();

    const { BrowserWindow } = require('electron');
    BrowserWindow.getAllWindows.mockReturnValue([]);

    app._emit('activate');

    // createWindow() should have been called, instantiating BrowserWindow
    expect(BrowserWindow.getAllWindows).toHaveBeenCalled();
  });

  test('does not create a new window when windows are already open', async () => {
    await Promise.resolve();

    const { BrowserWindow } = require('electron');
    BrowserWindow._instances = [];
    // Return a non-empty list so createWindow() is skipped
    BrowserWindow.getAllWindows.mockReturnValue([{}]);

    app._emit('activate');

    // No new BrowserWindow should have been instantiated
    expect(BrowserWindow._instances).toHaveLength(0);
  });
});

// ── BrowserWindow window lifecycle ───────────────────────────────────────────

describe('BrowserWindow: did-finish-load callback', () => {
  test('logs a message when the window finishes loading', async () => {
    // Ensure the activate handler (and thus createWindow) has been registered
    await Promise.resolve();

    const { BrowserWindow } = require('electron');
    // Clear tracked instances so we get a clean reference to the next window
    BrowserWindow._instances = [];
    BrowserWindow.getAllWindows.mockReturnValue([]);

    // Trigger createWindow via the activate event
    app._emit('activate');

    const instance = BrowserWindow._instances[BrowserWindow._instances.length - 1];
    expect(instance).toBeDefined();

    // Retrieve the handler registered for 'did-finish-load'
    const didFinishLoadCall = instance.webContents.on.mock.calls.find(
      ([event]) => event === 'did-finish-load'
    );
    expect(didFinishLoadCall).toBeDefined();

    const consoleSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    didFinishLoadCall[1](); // invoke the callback
    expect(consoleSpy).toHaveBeenCalledWith('[Main Process] Window fully loaded');
    consoleSpy.mockRestore();
  });
});

// ── Development mode ──────────────────────────────────────────────────────────

describe('main.js — NODE_ENV=development', () => {
  test('opens DevTools when NODE_ENV is "development"', async () => {
    const originalNodeEnv = process.env.NODE_ENV;
    process.env.NODE_ENV = 'development';

    let capturedElectron;
    jest.isolateModules(() => {
      capturedElectron = require('electron');
      // fs is already mocked globally; existsSync is available
      require('../../src/main');
    });

    // Flush app.whenReady().then() → createWindow()
    await Promise.resolve();

    const instance = capturedElectron.BrowserWindow._instances[
      capturedElectron.BrowserWindow._instances.length - 1
    ];
    expect(instance).toBeDefined();
    expect(instance.webContents.openDevTools).toHaveBeenCalledTimes(1);

    process.env.NODE_ENV = originalNodeEnv;
  });
});

// ── Addon loading failure ─────────────────────────────────────────────────────

describe('main.js — addon loading failure', () => {
  test('calls process.exit(1) when the native addon cannot be loaded', () => {
    const exitSpy = jest.spyOn(process, 'exit').mockImplementation(() => {});
    const consoleErrorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    // Resolve the path that moduleNameMapper maps llama_addon.node to,
    // then register a factory that throws so main.js hits its catch branch.
    const addonMockPath = require.resolve(
      '../../src/addon/build/Release/llama_addon.node'
    );

    jest.isolateModules(() => {
      jest.doMock(addonMockPath, () => {
        throw new Error('native module failed to load');
      });
      require('../../src/main');
    });

    expect(exitSpy).toHaveBeenCalledWith(1);
    expect(consoleErrorSpy).toHaveBeenCalledWith(
      '[Main Process] Failed to load llama_addon:',
      expect.any(Error)
    );

    exitSpy.mockRestore();
    consoleErrorSpy.mockRestore();
  });
});

