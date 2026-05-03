'use strict';

// Mock for the llama_addon native Node.js addon.
// Returns Jest mock functions so tests can assert on and control
// processPrompt / getWorkerLog behaviour without a compiled .node binary.

const processPrompt = jest.fn();
const getWorkerLog = jest.fn();

module.exports = { processPrompt, getWorkerLog };
