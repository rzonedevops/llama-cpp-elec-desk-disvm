'use strict';

// Unit tests for src/preload.js
//
// preload.js calls contextBridge.exposeInMainWorld('llamaAPI', {...}) on load.
// We verify:
//   - The correct world name is used.
//   - The exposed API has exactly the right methods.
//   - Each method delegates to the correct ipcRenderer.invoke channel.

const { contextBridge, ipcRenderer } = require('electron');

// ── Load preload once; capture the exposed API ────────────────────────────────

let exposedName;
let exposedApi;

beforeAll(() => {
  contextBridge.exposeInMainWorld.mockImplementation((name, api) => {
    exposedName = name;
    exposedApi = api;
  });
  ipcRenderer.invoke.mockResolvedValue('mock-result');

  // Require the module once; it executes contextBridge.exposeInMainWorld synchronously
  require('../../src/preload');
});

afterAll(() => {
  jest.resetAllMocks();
});

// ── contextBridge setup ───────────────────────────────────────────────────────

describe('preload.js — contextBridge setup', () => {
  test('exposes API under the name "llamaAPI"', () => {
    expect(exposedName).toBe('llamaAPI');
  });

  test('exposes exactly three methods: processPrompt, selectModel, getWorkerLog', () => {
    const keys = Object.keys(exposedApi).sort();
    expect(keys).toEqual(['getWorkerLog', 'processPrompt', 'selectModel']);
  });

  test('all exposed properties are functions', () => {
    Object.values(exposedApi).forEach((fn) => {
      expect(typeof fn).toBe('function');
    });
  });
});

// ── ipcRenderer delegation ────────────────────────────────────────────────────

describe('preload.js — ipcRenderer delegation', () => {
  beforeEach(() => {
    ipcRenderer.invoke.mockReset();
    ipcRenderer.invoke.mockResolvedValue('mock-result');
  });

  test('processPrompt invokes "process-prompt" channel with modelPath and prompt', async () => {
    const modelPath = '/path/to/model.gguf';
    const prompt = 'Hello world';

    await exposedApi.processPrompt(modelPath, prompt);

    expect(ipcRenderer.invoke).toHaveBeenCalledWith('process-prompt', modelPath, prompt);
  });

  test('processPrompt returns the value resolved by ipcRenderer.invoke', async () => {
    ipcRenderer.invoke.mockResolvedValue('generated text');

    const result = await exposedApi.processPrompt('/model.bin', 'test');

    expect(result).toBe('generated text');
  });

  test('selectModel invokes "select-model" channel with no extra arguments', async () => {
    await exposedApi.selectModel();

    expect(ipcRenderer.invoke).toHaveBeenCalledWith('select-model');
    expect(ipcRenderer.invoke).toHaveBeenCalledTimes(1);
  });

  test('selectModel returns the resolved file path', async () => {
    ipcRenderer.invoke.mockResolvedValue('/some/model.gguf');

    const result = await exposedApi.selectModel();

    expect(result).toBe('/some/model.gguf');
  });

  test('selectModel returns null when dialog is cancelled', async () => {
    ipcRenderer.invoke.mockResolvedValue(null);

    const result = await exposedApi.selectModel();

    expect(result).toBeNull();
  });

  test('getWorkerLog invokes "get-worker-log" channel with no extra arguments', async () => {
    await exposedApi.getWorkerLog();

    expect(ipcRenderer.invoke).toHaveBeenCalledWith('get-worker-log');
  });

  test('getWorkerLog returns the log string', async () => {
    ipcRenderer.invoke.mockResolvedValue('log line 1\nlog line 2\n');

    const result = await exposedApi.getWorkerLog();

    expect(result).toBe('log line 1\nlog line 2\n');
  });

  test('each API method propagates rejection from ipcRenderer.invoke', async () => {
    const error = new Error('IPC failure');
    ipcRenderer.invoke.mockRejectedValue(error);

    await expect(exposedApi.processPrompt('/m', 'p')).rejects.toThrow('IPC failure');
    ipcRenderer.invoke.mockRejectedValue(error);
    await expect(exposedApi.selectModel()).rejects.toThrow('IPC failure');
    ipcRenderer.invoke.mockRejectedValue(error);
    await expect(exposedApi.getWorkerLog()).rejects.toThrow('IPC failure');
  });
});
