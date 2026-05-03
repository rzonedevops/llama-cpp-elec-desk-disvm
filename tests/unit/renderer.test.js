/**
 * @jest-environment jsdom
 */

'use strict';

// Unit tests for src/renderer.js
//
// renderer.js is designed to run inside a browser (Electron renderer process).
// It references DOM elements by ID and calls window.llamaAPI.
//
// We simulate a minimal DOM using Jest's jsdom environment and then require the
// module.  Pure helper functions (updateStatus, handleError, setProcessing,
// startLogPolling, stopLogPolling) are indirectly exercised through the DOM
// state they produce.

// ── DOM setup ────────────────────────────────────────────────────────────────

function buildDOM() {
  document.body.innerHTML = `
    <input  id="model-path" />
    <button id="select-model-btn">Select Model</button>
    <textarea id="prompt-input"></textarea>
    <button id="process-btn" disabled>Process</button>
    <div    id="result-text">Initial</div>
    <div    id="loading-indicator" class="hidden"></div>
    <div    id="status">Ready</div>
    <div    id="model-info"></div>
    <div    class="result-section"></div>
  `;
}

// ── llamaAPI mock ────────────────────────────────────────────────────────────

const mockSelectModel = jest.fn();
const mockProcessPrompt = jest.fn();
const mockGetWorkerLog = jest.fn();

// Expose the mock API on window before renderer.js is loaded
Object.defineProperty(window, 'llamaAPI', {
  value: {
    selectModel: mockSelectModel,
    processPrompt: mockProcessPrompt,
    getWorkerLog: mockGetWorkerLog,
  },
  writable: true,
});

// ── Load renderer ────────────────────────────────────────────────────────────

beforeEach(() => {
  buildDOM();
  jest.resetAllMocks();
  // Re-require renderer for each test so event listeners are fresh
  jest.isolateModules(() => {
    require('../../src/renderer');
  });
});

afterEach(() => {
  jest.useRealTimers();
});

// ── helpers ──────────────────────────────────────────────────────────────────

function getEl(id) {
  return document.getElementById(id);
}

function click(id) {
  getEl(id).dispatchEvent(new Event('click', { bubbles: true }));
}

function typeInto(id, value) {
  const el = getEl(id);
  el.value = value;
  el.dispatchEvent(new Event('input', { bubbles: true }));
}

// ── Initial state ─────────────────────────────────────────────────────────────

describe('renderer.js — initial state', () => {
  test('loading indicator starts hidden', () => {
    expect(getEl('loading-indicator').classList.contains('hidden')).toBe(true);
  });

  test('status shows ready message', () => {
    expect(getEl('status').textContent).toBe('Ready - Please select a model file');
  });

  test('process button starts disabled', () => {
    expect(getEl('process-btn').disabled).toBe(true);
  });
});

// ── select-model button ───────────────────────────────────────────────────────

describe('renderer.js — select model button', () => {
  test('updates model-path input and model-info on successful selection', async () => {
    mockSelectModel.mockResolvedValue('/models/llama-7b.gguf');

    click('select-model-btn');
    await Promise.resolve(); // flush microtasks

    expect(getEl('model-path').value).toBe('/models/llama-7b.gguf');
    expect(getEl('model-info').textContent).toBe('Selected model: llama-7b.gguf');
  });

  test('does not update model-path when selection is cancelled (null returned)', async () => {
    mockSelectModel.mockResolvedValue(null);

    click('select-model-btn');
    await Promise.resolve();

    expect(getEl('model-path').value).toBe('');
    expect(getEl('status').textContent).toBe('Model selection cancelled');
  });

  test('displays error status when selectModel rejects', async () => {
    mockSelectModel.mockRejectedValue(new Error('dialog failed'));

    click('select-model-btn');
    await Promise.resolve();
    await Promise.resolve();

    expect(getEl('status').textContent).toMatch(/dialog failed/);
  });

  test('enables process button after model is selected and prompt is non-empty', async () => {
    mockSelectModel.mockResolvedValue('/models/m.gguf');
    typeInto('prompt-input', 'hello');

    click('select-model-btn');
    await Promise.resolve();

    expect(getEl('process-btn').disabled).toBe(false);
  });

  test('keeps process button disabled when model selected but prompt is empty', async () => {
    mockSelectModel.mockResolvedValue('/models/m.gguf');
    // prompt-input is empty by default

    click('select-model-btn');
    await Promise.resolve();

    expect(getEl('process-btn').disabled).toBe(true);
  });
});

// ── prompt input event ────────────────────────────────────────────────────────

describe('renderer.js — prompt input listener', () => {
  test('disables process button when prompt is cleared', async () => {
    // Set up a model path directly so button might otherwise be enabled
    getEl('model-path').value = '/models/m.gguf';

    // Type something then clear it
    typeInto('prompt-input', 'hello');
    typeInto('prompt-input', '');

    expect(getEl('process-btn').disabled).toBe(true);
  });

  test('enables process button when both model path and prompt are set', () => {
    getEl('model-path').value = '/models/m.gguf';
    typeInto('prompt-input', 'some question');

    expect(getEl('process-btn').disabled).toBe(false);
  });

  test('keeps process button disabled when model path is missing', () => {
    // model-path is empty, only prompt is filled
    typeInto('prompt-input', 'question');

    expect(getEl('process-btn').disabled).toBe(true);
  });
});

// ── process button ────────────────────────────────────────────────────────────

describe('renderer.js — process button click', () => {
  async function setupAndClick(modelPath, prompt, resolvedResult) {
    getEl('model-path').value = modelPath;
    typeInto('prompt-input', prompt);
    mockGetWorkerLog.mockResolvedValue('');

    if (resolvedResult instanceof Error) {
      mockProcessPrompt.mockRejectedValue(resolvedResult);
    } else {
      mockProcessPrompt.mockResolvedValue(resolvedResult);
    }

    click('process-btn');
    // Flush all pending microtasks multiple times to let async handlers settle
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
  }

  test('shows loading indicator while processing', async () => {
    let resolvePrompt;
    mockProcessPrompt.mockReturnValue(new Promise((r) => { resolvePrompt = r; }));
    mockGetWorkerLog.mockResolvedValue('');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'hello');

    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();

    expect(getEl('loading-indicator').classList.contains('hidden')).toBe(false);

    resolvePrompt('done');
  });

  test('displays result text on success', async () => {
    await setupAndClick('/m.gguf', 'question', 'The answer is 42');

    expect(getEl('result-text').textContent).toBe('The answer is 42');
  });

  test('displays error message on failure', async () => {
    await setupAndClick('/m.gguf', 'question', new Error('inference failed'));

    expect(getEl('result-text').textContent).toMatch(/inference failed/);
  });

  test('updates status to success message after processing', async () => {
    await setupAndClick('/m.gguf', 'question', 'some result');

    expect(getEl('status').textContent).toBe('Prompt processed successfully');
  });

  test('calls processPrompt with model path and prompt', async () => {
    mockProcessPrompt.mockResolvedValue('ok');
    mockGetWorkerLog.mockResolvedValue('');
    getEl('model-path').value = '/my/model.gguf';
    typeInto('prompt-input', 'test prompt');

    click('process-btn');
    await new Promise((r) => setTimeout(r, 0));

    expect(mockProcessPrompt).toHaveBeenCalledWith('/my/model.gguf', 'test prompt');
  });

  test('hides loading indicator after processing completes', async () => {
    await setupAndClick('/m.gguf', 'question', 'result');

    expect(getEl('loading-indicator').classList.contains('hidden')).toBe(true);
  });

  test('hides loading indicator even when processing fails', async () => {
    await setupAndClick('/m.gguf', 'question', new Error('fail'));

    expect(getEl('loading-indicator').classList.contains('hidden')).toBe(true);
  });

  test('does nothing when model path is empty', async () => {
    getEl('model-path').value = '';
    typeInto('prompt-input', 'some prompt');

    click('process-btn');
    await Promise.resolve();

    expect(mockProcessPrompt).not.toHaveBeenCalled();
    expect(getEl('status').textContent).toBe('Please select a model and enter a prompt');
  });

  test('does nothing when prompt is empty', async () => {
    getEl('model-path').value = '/m.gguf';
    // prompt-input is empty

    // Force button to be enabled to test guard in handler
    getEl('process-btn').disabled = false;
    click('process-btn');
    await Promise.resolve();

    expect(mockProcessPrompt).not.toHaveBeenCalled();
  });

  test('displays "Unknown error" when error has no message property', async () => {
    const errorWithoutMessage = {}; // plain object — no .message
    mockProcessPrompt.mockRejectedValue(errorWithoutMessage);
    mockGetWorkerLog.mockResolvedValue('');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'question');

    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(getEl('result-text').textContent).toBe('Error: Unknown error');
    expect(getEl('status').textContent).toBe('Failed to process prompt: Unknown error');
  });
});

// ── handleError with null/undefined error ──────────────────────────────────────

describe('renderer.js — handleError with missing error object', () => {
  test('shows "Unknown error" in status when selectModel rejects with null', async () => {
    mockSelectModel.mockRejectedValue(null);

    click('select-model-btn');
    await Promise.resolve();
    await Promise.resolve();

    expect(getEl('status').textContent).toBe('Error selecting model: Unknown error');
  });
});

// ── log polling ───────────────────────────────────────────────────────────────

describe('renderer.js — worker log polling', () => {
  beforeEach(() => {
    jest.useFakeTimers();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('starts polling when process button is clicked', async () => {
    mockProcessPrompt.mockResolvedValue('done');
    mockGetWorkerLog.mockResolvedValue('log entry\n');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'p');

    click('process-btn');
    // Flush the initial updateWorkerLog call (microtask)
    await Promise.resolve();
    await Promise.resolve();

    // Advance fake timers past first 1-second tick
    jest.advanceTimersByTime(1100);
    await Promise.resolve();

    expect(mockGetWorkerLog).toHaveBeenCalled();
  });

  test('creates worker-log container in DOM on first poll start', async () => {
    mockProcessPrompt.mockResolvedValue('done');
    mockGetWorkerLog.mockResolvedValue('');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'p');

    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();

    expect(document.getElementById('worker-log')).not.toBeNull();
  });

  test('does not create duplicate log containers on re-process', async () => {
    mockProcessPrompt.mockResolvedValue('done');
    mockGetWorkerLog.mockResolvedValue('');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'p');

    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();

    // Re-enable button and click again
    getEl('process-btn').disabled = false;
    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();

    const logContainers = document.querySelectorAll('#worker-log');
    expect(logContainers.length).toBe(1);
  });

  test('handles error thrown by getWorkerLog without crashing', async () => {
    mockProcessPrompt.mockResolvedValue('done');
    // Make getWorkerLog throw after the log container exists
    mockGetWorkerLog.mockRejectedValue(new Error('log unavailable'));
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'p');

    // Should not throw even when getWorkerLog rejects
    await expect(async () => {
      click('process-btn');
      await Promise.resolve();
      await Promise.resolve();
      await Promise.resolve();
    }).not.toThrow();
  });

  test('skips log update when log-content element has been removed from DOM', async () => {
    let resolvePrompt;
    mockProcessPrompt.mockReturnValue(new Promise((r) => { resolvePrompt = r; }));
    mockGetWorkerLog.mockResolvedValue('log data');
    getEl('model-path').value = '/m.gguf';
    typeInto('prompt-input', 'p');

    // Start processing — startLogPolling creates #worker-log containing #log-content
    click('process-btn');
    await Promise.resolve();
    await Promise.resolve();

    // Remove log-content so the next interval call finds null
    const logEl = document.getElementById('log-content');
    if (logEl) logEl.remove();

    // Advance timer to trigger the interval-based updateWorkerLog call
    jest.advanceTimersByTime(1100);
    await Promise.resolve();
    await Promise.resolve();

    // No crash should have occurred; log-content is still absent
    expect(document.getElementById('log-content')).toBeNull();

    resolvePrompt('done');
  });
});
