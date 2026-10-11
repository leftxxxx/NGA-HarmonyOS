'use strict';

// Run: node --test tools/test-board-stores.cjs
// Exercise the real ETS stores with isolated, in-memory HarmonyOS preferences.
// No device, user preferences, credentials, or network service is accessed.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const devecoHome = process.env.DEVECO_HOME || 'D:\\software\\DevEco Studio';
const compilerCandidates = [
  process.env.ETS_TYPESCRIPT_PATH,
  process.env.TYPESCRIPT_PATH,
  path.join(devecoHome, 'tools/hvigor/hvigor-ohos-plugin/node_modules/typescript'),
  path.join(devecoHome, 'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript')
].filter(Boolean);
const compilerPath = compilerCandidates.find(candidate => fs.existsSync(candidate));
assert.ok(compilerPath, 'Set DEVECO_HOME or TYPESCRIPT_PATH to a DevEco TypeScript installation');
const ts = require(compilerPath);
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');

function fixture(favoriteSeed) {
  const preferenceFiles = new Map();
  let flushes = 0;
  if (favoriteSeed !== undefined) {
    preferenceFiles.set('nga_favorite_store', new Map([
      ['pref_favorite_list', favoriteSeed]
    ]));
  }
  const preferences = {
    getPreferencesSync(_context, options) {
      if (!preferenceFiles.has(options.name)) preferenceFiles.set(options.name, new Map());
      const values = preferenceFiles.get(options.name);
      return {
        getSync(key, fallback) { return values.has(key) ? values.get(key) : fallback; },
        putSync(key, value) { values.set(key, value); },
        flush() { flushes++; return Promise.resolve(); }
      };
    }
  };
  const cache = new Map();
  function load(name) {
    if (cache.has(name)) return cache.get(name).exports;
    const filename = path.join(modelRoot, name + '.ets');
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: filename.replace(/\.ets$/, '.ts'),
      reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    });
    const errors = (compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
    assert.equal(errors.length, 0,
      errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
    const module = { exports: {} };
    cache.set(name, module);
    const sourceRequire = id => {
      if (id === '@kit.ArkData') return { preferences };
      if (id.startsWith('./')) return load(id.slice(2));
      throw new Error('Unexpected ETS dependency: ' + id);
    };
    const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
      compiled.outputText + '\n})', { filename });
    evaluate(sourceRequire, module, module.exports);
    return module.exports;
  }
  const { FavoriteStore } = load('FavoriteStore');
  const { RecentBoardStore } = load('RecentBoardStore');
  FavoriteStore.init({});
  RecentBoardStore.init({});
  return {
    FavoriteStore,
    RecentBoardStore,
    Board: load('Board').Board,
    flushes: () => flushes,
    favoriteJson: () => preferenceFiles.get('nga_favorite_store').get('pref_favorite_list')
  };
}

function keys(boards) {
  return boards.map(board => [board.fid, board.stid]);
}

test('favorites keep parent and sibling boards distinct and deduplicate the full key', () => {
  const { FavoriteStore: store, Board } = fixture();
  store.add(new Board(414, 0, 'parent'));
  store.add(new Board(414, 12007887, 'news'));
  assert.equal(store.addByFidStid(414, 13011773, 'other child'), true);
  store.add(new Board(414, 12007887, 'duplicate'));
  assert.equal(store.addByFidStid(414, 0, 'duplicate parent'), false);
  assert.equal(store.addByFidStid(414, 13011773, 'duplicate child'), false);
  assert.deepEqual(keys(store.getList()), [[414, 0], [414, 12007887], [414, 13011773]]);
  assert.equal(store.getList()[1].name, 'news');
  assert.equal(store.checkExists(414), true);
  assert.equal(store.checkExists(414, 12007887), true);
  assert.equal(store.checkExistsByKey(414, 13011773), true);
  assert.equal(store.checkExists(414, 99), false);
});

test('removing a child preserves siblings; default removal and existence target the parent', () => {
  const { FavoriteStore: store } = fixture();
  for (const stid of [0, 12007887, 13011773]) store.addByFidStid(414, stid, String(stid));
  store.remove(414, 12007887);
  assert.deepEqual(keys(store.getList()), [[414, 0], [414, 13011773]]);
  store.remove(414);
  assert.deepEqual(keys(store.getList()), [[414, 13011773]]);
  assert.equal(store.checkExists(414), false);
  assert.equal(store.checkExists(414, 13011773), true);
  store.remove(414, 99);
  assert.deepEqual(keys(store.getList()), [[414, 13011773]]);
});

test('favorite ordering retains all distinct boards sharing one fid', () => {
  const { FavoriteStore: store } = fixture();
  for (const stid of [0, 10, 20]) store.addByFidStid(414, stid, String(stid));
  store.moveUp(2);
  assert.deepEqual(keys(store.getList()), [[414, 0], [414, 20], [414, 10]]);
  store.moveDown(0);
  assert.deepEqual(keys(store.getList()), [[414, 20], [414, 0], [414, 10]]);
  store.swap(2, 0);
  assert.deepEqual(keys(store.getList()), [[414, 10], [414, 20], [414, 0]]);
  store.moveUp(0);
  store.moveDown(2);
  assert.deepEqual(keys(store.getList()), [[414, 10], [414, 20], [414, 0]]);
});

test('existing serialized favorites are read without clearing or migration writes', () => {
  const legacy = JSON.stringify([
    { fid: 414, name: 'legacy parent without stid' },
    { fid: 414, stid: 12007887, name: 'saved child' },
    { fid: 0, stid: 0, name: 'existing incomplete entry' }
  ]);
  const f = fixture(legacy);
  assert.deepEqual(keys(f.FavoriteStore.getList()), [[414, 0], [414, 12007887], [0, 0]]);
  assert.equal(f.favoriteJson(), legacy);
  assert.equal(f.flushes(), 0);
  f.FavoriteStore.addByFidStid(414, 13011773, 'new child');
  assert.deepEqual(keys(f.FavoriteStore.getList()), [[414, 0], [414, 12007887], [0, 0], [414, 13011773]]);
});

test('favorite writes allow negative fid and stid-only boards and reject invalid keys', () => {
  const { FavoriteStore: store, Board } = fixture();
  store.add(new Board(-7, 0, 'negative board'));
  assert.equal(store.addByFidStid(-447601, 0, 'another negative board'), true);
  assert.equal(store.addByFidStid(0, 12007887, 'stid-only board'), true);
  for (const [fid, stid] of [[0, 0], [0, -1], [NaN, 0], [7, NaN], [Infinity, 0], [7, 1.5]]) {
    store.add(new Board(fid, stid, 'invalid'));
    assert.equal(store.addByFidStid(fid, stid, 'invalid'), false);
  }
  assert.deepEqual(keys(store.getList()), [[-7, 0], [-447601, 0], [0, 12007887]]);
});

test('recent access accepts negative fid and stid-only boards and preserves sibling identity', () => {
  const { RecentBoardStore: store } = fixture();
  store.record(-7, 0, 'negative board');
  store.record(414, 0, 'parent');
  store.record(414, 12007887, 'news');
  store.record(0, 13011773, 'stid-only board');
  store.record(-7, 0, 'revisited negative board');
  assert.deepEqual(keys(store.getList()), [[-7, 0], [0, 13011773], [414, 12007887], [414, 0]]);
  assert.equal(store.getList()[0].name, 'revisited negative board');
});

test('recent access still limits history to ten unique boards and ignores invalid input', () => {
  const { RecentBoardStore: store } = fixture();
  for (let fid = -1; fid >= -11; fid--) store.record(fid, 0, String(fid));
  assert.equal(store.getList().length, 10);
  assert.deepEqual(store.getList().map(board => board.fid), [-11, -10, -9, -8, -7, -6, -5, -4, -3, -2]);
  for (const [fid, stid] of [[0, 0], [0, -1], [NaN, 0], [7, NaN], [Infinity, 0], [7, 1.5]]) {
    store.record(fid, stid, 'invalid');
  }
  assert.equal(store.getList().length, 10);
  assert.equal(store.getList()[0].fid, -11);
});
