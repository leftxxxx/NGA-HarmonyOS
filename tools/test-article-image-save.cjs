'use strict';
// Runs actual ArkTS logic with local native substitutes; no images are downloaded or saved to a real album.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test, beforeEach } = require('node:test');
const ts = require(path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');
let state;
const jpeg = new Uint8Array([255, 216, 255, 10, 20, 30, 40]).buffer;
beforeEach(() => { state = { bytes: jpeg, status: 200, created: ['file://media/Photo/fixture.jpg'],
  requests: [], writes: [], opened: [], closed: [], unlinked: [], copies: [], released: 0, destroyed: 0 }; });
const mocks = {
  '@kit.NetworkKit': { http: { RequestMethod: { GET: 'GET' }, HttpDataType: { ARRAY_BUFFER: 2 },
    createHttp() { if (state.createError) throw new Error('fixture initialization failure'); return {
      async request(url, options) {
        state.requests.push({ url, options });
        if (state.requestError) throw new Error('fixture download failure');
        state.onRequest?.();
        return { responseCode: state.status, result: state.bytes };
      },
      destroy() { state.destroyed++; if (state.destroyError) throw new Error('fixture destroy failure'); }
    }; }
  } },
  '@kit.CoreFileKit': { fileUri: { getUriFromPath: source => 'file://fixture' + source }, fileIo: {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    async open(uri) { const selected = { fd: state.opened.length + 21 }; state.opened.push({ uri, ...selected }); return selected; },
    async write(fd, bytes, options) {
      state.writes.push({ fd, bytes: Array.from(new Uint8Array(bytes)), options });
      if (state.writeError) throw new Error('fixture write failure');
      return state.writeZero ? 0 : Math.min(bytes.byteLength, state.shortWrite ?? Infinity);
    },
    async close(selected) { state.closed.push(selected.fd); if (state.closeError) throw new Error('fixture close failure'); },
    async copyFile(source, fd) { state.copies.push({ source, fd }); if (state.copyError) throw new Error('fixture copy failure'); },
    async unlink(source) { state.unlinked.push(source); if (state.unlinkError) throw new Error('fixture unlink failure'); }
  } },
  '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoType: { IMAGE: 1 }, getPhotoAccessHelper() { return {
    async showAssetsCreationDialog(uris, config) {
      state.dialog = { uris, config };
      state.onDialog?.();
      if (state.dialogError) throw new Error('fixture dialog failure');
      return state.created;
    },
    async release() { state.released++; if (state.releaseError) throw new Error('fixture release failure'); }
  }; } } }
};
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name).exports;
  const filename = path.join(modelRoot, name + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { fileName: filename,
    reportDiagnostics: true, compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  assert.deepEqual((output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error), []);
  const module = { exports: {} }; cache.set(name, module);
  vm.runInThisContext('(function(require,module,exports){\n' + output.outputText + '\n})', { filename })(id => {
    if (Object.hasOwn(mocks, id)) return mocks[id];
    if (id.startsWith('./')) return load(id.substring(2));
    throw new Error('Unexpected ETS dependency: ' + id);
  }, module, module.exports);
  return module.exports;
}
const { ArticleImageSaver } = load('ArticleImageSaver');
const url = 'https://img.nga.cn/attachments/mon_202610/08/fixture.jpg';
const save = (current = () => true, target = url) => ArticleImageSaver.save(target, { cacheDir: '/cache/fixture' }, current);

test('downloads bounded image, requests explicit gallery consent, then copies exact original bytes', async () => {
  const result = await save();
  assert.equal(result.success, true);
  assert.equal(state.requests[0].options.maxLimit, 20 * 1024 * 1024);
  assert.equal(state.requests[0].options.header.Cookie, undefined);
  assert.equal(state.dialog.config[0].fileNameExtension, 'jpg');
  assert.ok(state.dialog.uris[0].startsWith('file://fixture/cache/fixture/'));
  assert.deepEqual(state.writes[0].bytes, Array.from(new Uint8Array(jpeg)));
  assert.equal(state.copies.length, 1);
  assert.equal(state.closed.length, 2);
  assert.equal(state.destroyed, 1);
  assert.equal(state.released, 1);
  assert.equal(state.unlinked.length, 1);
});
test('user declining gallery consent leaves no album write and removes the private temporary file', async () => {
  state.created = [];
  const result = await save();
  assert.equal(result.cancelled, true);
  assert.equal(result.success, false);
  assert.equal(state.copies.length, 0);
  assert.equal(state.opened.length, 1);
  assert.equal(state.unlinked.length, 1);
});
test('invalid URLs never initiate a request', async () => {
  for (const target of ['file:///private/a.jpg', 'http://img.nga.cn/a.jpg', 'javascript:bad()', 'https://a.test/a".jpg']) {
    assert.equal((await save(() => true, target)).success, false);
  }
  assert.equal(state.requests.length, 0);
});
test('failed, empty, oversize, non-image, and string download results never request album consent', async () => {
  for (const bytes of [new ArrayBuffer(0), new ArrayBuffer(20 * 1024 * 1024 + 1), new TextEncoder().encode('not image').buffer, 'not binary']) {
    state.bytes = bytes;
    assert.equal((await save()).success, false);
    assert.equal(state.dialog, undefined);
  }
  state.bytes = jpeg; state.status = 404;
  assert.equal((await save()).success, false);
  assert.equal(state.opened.length, 0);
});
test('GIF save preserves animation bytes and uses the actual detected extension', async () => {
  state.bytes = new TextEncoder().encode('GIF89afixture frames').buffer;
  const result = await save();
  assert.equal(result.success, true);
  assert.equal(state.dialog.config[0].fileNameExtension, 'gif');
  assert.deepEqual(state.writes[0].bytes, Array.from(new Uint8Array(state.bytes)));
});
test('short writes keep writing remaining bytes at the correct file offset', async () => {
  state.shortWrite = 3;
  const result = await save();
  assert.equal(result.success, true);
  assert.deepEqual(state.writes.map(write => write.options.offset), [0, 3, 6]);
  assert.deepEqual(state.writes[1].bytes, [10, 20, 30, 40]);
});
test('zero writes stop with an error and close the file', async () => {
  state.writeZero = true;
  assert.equal((await save()).success, false);
  assert.equal(state.closed.length, 1);
  assert.equal(state.dialog, undefined);
  assert.equal(state.unlinked.length, 1);
});
test('page disappearing during download prevents the system dialog and any file write', async () => {
  let current = true; state.onRequest = () => { current = false; };
  assert.equal((await save(() => current)).cancelled, true);
  assert.equal(state.writes.length, 0);
  assert.equal(state.dialog, undefined);
});
test('confirmed save finishes when the viewer closes while the system dialog is open', async () => {
  let current = true; state.onDialog = () => { current = false; };
  assert.equal((await save(() => current)).success, true);
  assert.equal(state.copies.length, 1);
});
test('save operations are serialized across article components', async () => {
  let another;
  state.onRequest = () => { another = save(); };
  assert.equal((await save()).success, true);
  assert.equal((await another).success, false);
  assert.equal(state.requests.length, 1);
});
test('download, dialog, and album-copy errors always release their acquired resources', async () => {
  state.requestError = true;
  assert.equal((await save()).success, false);
  assert.equal(state.destroyed, 1);
  state.requestError = false; state.dialogError = true;
  assert.equal((await save()).success, false);
  assert.equal(state.released, 1);
  assert.equal(state.unlinked.length, 1);
  state.dialogError = false; state.copyError = true;
  assert.equal((await save()).success, false);
  assert.equal(state.closed.length, 3);
  assert.equal(state.released, 2);
  assert.equal(state.unlinked.length, 2);
});
test('cleanup failures do not hide successful save or prevent a subsequent save', async () => {
  state.destroyError = true; state.releaseError = true; state.unlinkError = true;
  assert.equal((await save()).success, true);
  assert.equal(state.closed.length, 2);
  assert.equal((await save()).success, true);
  assert.equal(state.requests.length, 2);
});
test('HTTP creation failure resets save mutex and allows a subsequent attempt', async () => {
  state.createError = true;
  assert.equal((await save()).success, false);
  state.createError = false;
  assert.equal((await save()).success, true);
});
