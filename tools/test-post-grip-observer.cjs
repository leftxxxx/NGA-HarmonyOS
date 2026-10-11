'use strict';

/* Run: node --test tools/test-post-grip-observer.cjs
 * Execute the real ETS observer with the DevEco compiler and a native motion
 * callback mock. This does not connect to a device or simulate physical grip.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(devecoHome,
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
const filename = path.resolve(__dirname, '../entry/src/main/ets/model/PostGripObserver.ets');
const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
  fileName: filename, reportDiagnostics: true,
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
});
const errors = (output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);

function createObserver(options = {}) {
  const onCalls = [];
  const offCalls = [];
  const callbacks = new Set();
  const motion = {
    HoldingHandStatus: {
      NOT_HELD: 0, LEFT_HAND_HELD: 1, RIGHT_HAND_HELD: 2,
      BOTH_HANDS_HELD: 3, UNKNOWN_STATUS: 16
    },
    on(type, callback) {
      assert.equal(type, 'holdingHandChanged');
      assert.equal(typeof callback, 'function');
      onCalls.push({ type, callback });
      callbacks.add(callback);
      if (options.onError) throw Object.assign(new Error('native subscription failed'), { code: options.onError });
      if (options.initialStatus !== undefined) callback(options.initialStatus);
    },
    off(type, callback) {
      assert.equal(type, 'holdingHandChanged');
      assert.equal(typeof callback, 'function', 'Unsubscribe only this observer callback');
      offCalls.push({ type, callback });
      if (options.offError) throw Object.assign(new Error('native unsubscribe failed'), { code: options.offError });
      callbacks.delete(callback);
    }
  };
  const module = { exports: {} };
  const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
    output.outputText + '\n})', { filename });
  evaluate(id => {
    if (id === '@kit.MultimodalAwarenessKit') return { motion };
    if (id === '@kit.BasicServicesKit') return {};
    throw new Error('Unexpected ETS dependency: ' + id);
  }, module, module.exports);
  return {
    observer: new module.exports.PostGripObserver(), onCalls, offCalls,
    emit(status) { for (const callback of callbacks) callback(status); }
  };
}

test('actual left/right grip updates side; unheld, both and unknown preserve side', () => {
  const native = createObserver();
  const updates = [];
  native.observer.start(isLeft => updates.push(isLeft));
  for (const status of [0, 3, 16]) native.emit(status);
  assert.deepEqual(updates, [], 'Default right position is not overwritten');
  native.emit(1);
  for (const status of [0, 3, 16]) native.emit(status);
  native.emit(2);
  for (const status of [0, 3, 16, 99]) native.emit(status);
  assert.deepEqual(updates, [true, false]);
});

test('repeated start subscribes once and stop cancels the exact callback once', () => {
  const native = createObserver();
  const updates = [];
  native.observer.stop();
  native.observer.start(isLeft => updates.push(isLeft));
  native.observer.start(() => assert.fail('Repeated start must not replace the observer'));
  assert.equal(native.onCalls.length, 1);
  native.emit(1);
  native.observer.stop();
  native.observer.stop();
  assert.equal(native.offCalls.length, 1);
  assert.equal(native.offCalls[0].callback, native.onCalls[0].callback);
  native.emit(2);
  assert.deepEqual(updates, [true]);
});

test('callbacks retained after stop cannot write back, even after restarting', () => {
  const native = createObserver();
  const oldUpdates = [];
  const newUpdates = [];
  native.observer.start(isLeft => oldUpdates.push(isLeft));
  const oldCallback = native.onCalls[0].callback;
  native.observer.stop();
  oldCallback(1);
  native.observer.start(isLeft => newUpdates.push(isLeft));
  oldCallback(2);
  oldCallback(1);
  native.emit(1);
  assert.notEqual(native.onCalls[1].callback, oldCallback);
  assert.deepEqual(oldUpdates, []);
  assert.deepEqual(newUpdates, [true]);
});

test('unsupported, denied and service errors fall back without throwing or duplicate retries', () => {
  for (const code of [801, 201, 31500001, 31500002]) {
    const native = createObserver({ onError: code });
    const updates = [];
    assert.doesNotThrow(() => native.observer.start(isLeft => updates.push(isLeft)));
    const failedCallback = native.onCalls[0].callback;
    failedCallback(1);
    native.observer.start(() => assert.fail('Repeated failed start must not retry'));
    assert.equal(native.onCalls.length, 1);
    assert.equal(native.offCalls[0].callback, failedCallback);
    assert.deepEqual(updates, []);
    assert.doesNotThrow(() => native.observer.stop());
    native.observer.start(isLeft => updates.push(isLeft));
    assert.equal(native.onCalls.length, 2, 'Explicit stop/start allows a fresh attempt');
    failedCallback(2);
    native.onCalls[1].callback(1);
    assert.deepEqual(updates, []);
  }
});

test('unsubscribe failure is contained and stale native callbacks stay invalid after restart', () => {
  const native = createObserver({ offError: 31500003 });
  const oldUpdates = [];
  const newUpdates = [];
  native.observer.start(isLeft => oldUpdates.push(isLeft));
  native.emit(2);
  assert.doesNotThrow(() => native.observer.stop());
  native.emit(1);
  native.observer.start(isLeft => newUpdates.push(isLeft));
  native.emit(1);
  assert.deepEqual(oldUpdates, [false]);
  assert.deepEqual(newUpdates, [true]);
  assert.doesNotThrow(() => native.observer.stop());
  native.emit(2);
  assert.deepEqual(newUpdates, [true]);
});

test('failed subscription cleanup failure also invalidates retained callbacks', () => {
  const native = createObserver({ onError: 801, offError: 801 });
  const updates = [];
  assert.doesNotThrow(() => native.observer.start(isLeft => updates.push(isLeft)));
  native.emit(1);
  assert.doesNotThrow(() => native.observer.stop());
  native.emit(2);
  assert.deepEqual(updates, []);
});

test('a native initial status can arrive during subscription and stop from the callback', () => {
  const native = createObserver({ initialStatus: 1 });
  const updates = [];
  native.observer.start(isLeft => {
    updates.push(isLeft);
    native.observer.stop();
  });
  assert.deepEqual(updates, [true]);
  assert.equal(native.offCalls[0].callback, native.onCalls[0].callback);
  native.onCalls[0].callback(2);
  assert.deepEqual(updates, [true]);
});
