'use strict';

// Mock for the 'electron' module used in unit tests.
// Provides stubs for app, BrowserWindow, ipcMain, ipcRenderer,
// contextBridge, and dialog so that Electron-specific tests can run
// in plain Node.js (via Jest) without a real Electron binary.

const EventEmitter = require('events');

// ── app ──────────────────────────────────────────────────────────────────────

const appEmitter = new EventEmitter();

const app = {
  whenReady: jest.fn(() => Promise.resolve()),
  quit: jest.fn(),
  getAppPath: jest.fn(() => '/mock/app/path'),
  on: jest.fn((event, handler) => {
    appEmitter.on(event, handler);
  }),
  // Helper to trigger events in tests
  _emit: (event, ...args) => appEmitter.emit(event, ...args),
};

// ── BrowserWindow ────────────────────────────────────────────────────────────

class BrowserWindow {
  constructor(options) {
    this.options = options;
    this.webContents = {
      openDevTools: jest.fn(),
      on: jest.fn(),
      send: jest.fn(),
    };
    BrowserWindow._instances.push(this);
  }

  loadFile = jest.fn();
  on = jest.fn();

  static getAllWindows = jest.fn(() => []);
  static _instances = [];
}

// ── ipcMain ──────────────────────────────────────────────────────────────────

const ipcMainHandlers = {};

const ipcMain = {
  handle: jest.fn((channel, handler) => {
    ipcMainHandlers[channel] = handler;
  }),
  // Helper to invoke a registered handler in tests
  _invoke: (channel, event, ...args) => {
    const handler = ipcMainHandlers[channel];
    if (!handler) throw new Error(`No ipcMain handler for channel: ${channel}`);
    return handler(event, ...args);
  },
  _handlers: ipcMainHandlers,
};

// ── ipcRenderer ──────────────────────────────────────────────────────────────

const ipcRenderer = {
  invoke: jest.fn(),
};

// ── contextBridge ────────────────────────────────────────────────────────────

const contextBridge = {
  exposeInMainWorld: jest.fn(),
};

// ── dialog ───────────────────────────────────────────────────────────────────

const dialog = {
  showOpenDialog: jest.fn(),
};

module.exports = {
  app,
  BrowserWindow,
  ipcMain,
  ipcRenderer,
  contextBridge,
  dialog,
};
