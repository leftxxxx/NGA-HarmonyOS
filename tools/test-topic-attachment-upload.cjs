'use strict';

// Actual ArkTS uploader with local bytes/native API substitutes. No login data,
// user photos, network requests, or posts are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { TextDecoder } = require('node:util');
const { test, beforeEach } = require('node:test');

const compiler = process.env.TYPESCRIPT_PATH || path.join(process.env.DEVECO_HOME || 'D:/software/DevEco Studio',
  'sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const ts = require(compiler);
const modelRoot = path.resolve(__dirname, '../entry/src/main/ets/model');
const arrayBuffer = bytes => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
const fakeJpeg = (length = 200) => {
  const bytes = Buffer.alloc(length, 0x42);
  bytes.set([0xff, 0xd8, 0xff]);
  return bytes;
};
const fixtureUpload = () => JSON.stringify({ data: {
  url: 'mon_202610/07/-7Qfixture-test.jpg', attachments: 'fixture-attachment', attachments_check: 'fixture-check'
} });
let state;
beforeEach(() => {
  state = {
    bytes: fakeJpeg(), events: [], opened: 0, closed: 0, httpCreated: 0, destroyed: 0,
    requests: [], prepares: [], reads: [], sourceReleased: 0, pixelReleased: 0, packerReleased: 0,
    packed: [], decoded: [], diagnostics: [], frameCount: 1, packedLength: 65536,
    responseCode: 200, responseBody: Buffer.from(fixtureUpload()),
    responseHeaders: { 'content-type': 'text/plain; charset=utf-8' },
    preparation: { success: true, statusCode: 200, failureStage: '', nativeErrorCode: 0,
      body: JSON.stringify({ data: { auth: 'fixture-auth', fid: -7 } }) }
  };
});
const nativeFile = {
  OpenMode: { READ_ONLY: 0 },
  async open(uri, mode) {
    state.opened++;
    state.events.push('open');
    state.openArgs = { uri, mode };
    if (state.openError) throw new Error('fixture open failure');
    return { fd: 41 };
  },
  async stat(fd) {
    assert.equal(fd, 41);
    if (state.statError) throw new Error('fixture stat failure');
    return { size: state.statSize ?? state.bytes.length };
  },
  async read(fd, content, options) {
    assert.equal(fd, 41);
    state.reads.push(options);
    if (state.readError) throw new Error('fixture read failure');
    if (state.readEof) return 0;
    const size = Math.min(options.length, state.bytes.length - options.offset, state.shortRead ?? Infinity);
    new Uint8Array(content).set(state.bytes.subarray(options.offset, options.offset + size));
    state.onRead?.();
    return size;
  },
  async close(selectedFile) {
    assert.equal(selectedFile.fd, 41);
    state.closed++;
    state.events.push('close');
  }
};
const nativeHttp = {
  RequestMethod: { POST: 'POST' }, HttpDataType: { ARRAY_BUFFER: 2 },
  createHttp() {
    state.httpCreated++;
    return {
      async request(url, options) {
        state.events.push('upload');
        state.requests.push({ url, options });
        if (state.httpError) throw new Error('fixture connection failed');
        state.onRequest?.();
        return { responseCode: state.responseCode, header: state.responseHeaders,
          result: Object.hasOwn(state, 'responseResult') ? state.responseResult : arrayBuffer(state.responseBody) };
      },
      destroy() { state.destroyed++; }
    };
  }
};
const mockHttpClient = {
  getDomain: () => 'https://bbs.nga.cn',
  async post(url, fields) {
    state.events.push('prepare');
    state.prepares.push({ url, fields });
    state.onPrepare?.();
    return state.preparation;
  }
};
const nativeImage = {
  createImageSource(content) {
    state.sourceBytes = content.byteLength;
    return {
      async getFrameCount() { return state.frameCount; },
      async getImageInfo() { return { size: { width: 4000, height: 3000 } }; },
      async createPixelMap(options) {
        state.decoded.push(options);
        return { async release() { state.pixelReleased++; if (state.pixelReleaseError) throw new Error('fixture release failure'); } };
      },
      async release() { state.sourceReleased++; }
    };
  },
  createImagePacker() {
    return {
      async packToData(pixelMap, options) {
        assert.equal(typeof pixelMap.release, 'function');
        state.packed.push(options);
        if (state.packError) throw new Error('fixture encoding failed');
        state.onPack?.();
        return arrayBuffer(fakeJpeg(state.packedLength));
      },
      async release() { state.packerReleased++; }
    };
  }
};
const mocks = {
  '@kit.NetworkKit': { http: nativeHttp }, '@kit.CoreFileKit': { fileIo: nativeFile },
  '@kit.ImageKit': { image: nativeImage },
  '@kit.ArkTS': { util: { Base64Helper: class {
    async encodeToString(bytes) {
      if (state.base64Error) throw new Error('fixture base64 failure');
      return Buffer.from(bytes).toString('base64');
    }
  }, TextDecoder: { create(encoding) {
    const decoder = new TextDecoder(encoding);
    return { decodeToString(bytes) { return decoder.decode(bytes); } };
  } } } },
  './HttpClient': { HttpClient: mockHttpClient },
  './LoginStore': { LoginStore: { getCookie: () => 'fixture-cookie=1' } }
};
const cache = new Map();
function load(name) {
  if (cache.has(name)) return cache.get(name).exports;
  const filename = path.join(modelRoot, name + '.ets');
  const output = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (output.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
  const module = { exports: {} };
  cache.set(name, module);
  const localRequire = id => {
    if (Object.hasOwn(mocks, id)) return mocks[id];
    if (id.startsWith('./')) return load(id.slice(2));
    throw new Error('Unexpected ETS dependency: ' + id);
  };
  vm.runInThisContext('(function(require, module, exports, console) {\n' + output.outputText + '\n})', { filename })
    (localRequire, module, module.exports, { info(message) { state.diagnostics.push(message); } });
  return module.exports;
}
const { TopicAttachmentUploader } = load('TopicAttachmentUploader');
const { TopicAttachmentProtocol } = load('TopicAttachmentProtocol');
const { NgaTopicPostInput } = load('TopicPostProtocol');
const input = () => Object.assign(new NgaTopicPostInput(), { fid: -7, subject: 'Fixture title', content: 'Fixture body' });
const upload = (isCurrent = () => true) => TopicAttachmentUploader.upload('file://media/Photo/fixture.jpg', input(), isCurrent);
const filePart = () => state.requests[0].options.multiFormDataList.find(part => part.name === 'attachment_file1');

test('uploads selected bytes as multipart with auth, then exposes verified receipt', async () => {
  state.bytes = fakeJpeg(190123);
  state.shortRead = 9001;
  const result = await upload();
  assert.equal(result.success, true);
  assert.equal(result.attachment.attachmentsCheck, 'fixture-check');
  assert.equal(TopicAttachmentProtocol.buildMarkup(result.attachment), '[img]./mon_202610/07/-7Qfixture-test.jpg[/img]');
  assert.equal(state.closed, 1);
  assert.equal(state.destroyed, 1);
  assert.ok(state.reads.length > 2);
  assert.equal(state.reads[0].offset, 0);
  assert.equal(state.reads[1].offset, 9001);
  assert.deepEqual(Buffer.from(filePart().data), state.bytes);
  assert.equal(filePart().contentType, 'image/jpeg');
  assert.equal(filePart().remoteFileName, 'image.jpg');
  assert.equal(state.prepares[0].url, 'https://bbs.nga.cn/post.php?fid=-7&lite=js&action=new');
  assert.deepEqual(state.prepares[0].fields, {});
  assert.equal(state.requests[0].url, 'https://img8.nga.cn/attach.php?');
  const fields = Object.fromEntries(state.requests[0].options.multiFormDataList.map(part => [part.name, part.data]));
  assert.equal(fields.auth, 'fixture-auth');
  assert.equal(fields.fid, '-7');
  assert.equal(fields.func, 'upload');
  assert.equal(fields.v2, '1');
  assert.equal(fields.lite, 'js');
  assert.equal(fields.attachment_file1_img, '1');
  assert.equal(fields.origin_domain, 'bbs.ngacn.cc');
  assert.equal(state.events.indexOf('close') < state.events.indexOf('prepare'), true);
  assert.equal(state.requests[0].options.header.Cookie, 'fixture-cookie=1');
  assert.ok(!Object.hasOwn(fields, 'step'), 'Uploader must never submit a post');
});

test('uses the reply board and target topic to prepare attachment authorization', async () => {
  const postInput = Object.assign(input(), { action: 'reply', tid: 123, pid: 4, stid: 99 });
  state.preparation.body = JSON.stringify({ data: { auth: 'fixture-auth', fid: -7, stid: 99 } });
  assert.equal((await TopicAttachmentUploader.upload('file://media/Photo/fixture.jpg', postInput, () => true)).success, true);
  assert.equal(state.prepares[0].url,
    'https://bbs.nga.cn/post.php?fid=-7&lite=js&action=reply&pid=4&tid=123&stid=99');
});

test('stat and read errors close the file and never contact the server', async () => {
  state.statError = true;
  assert.equal((await upload()).success, false);
  assert.equal(state.closed, 1);
  assert.equal(state.prepares.length, 0);
  state.statError = false;
  state.readError = true;
  assert.equal((await upload()).success, false);
  assert.equal(state.closed, 2);
  assert.equal(state.httpCreated, 0);
});

test('zero, oversized, and incomplete images are rejected before authorization', async () => {
  state.statSize = 0;
  assert.equal((await upload()).errorMessage, '图片内容为空');
  state.statSize = TopicAttachmentProtocol.MAX_FILE_BYTES + 1;
  assert.equal((await upload()).errorMessage, '图片不能超过 10 MB');
  state.statSize = state.bytes.length;
  state.readEof = true;
  assert.equal((await upload()).errorMessage, '图片读取不完整，请重新选择');
  assert.equal(state.closed, 3);
  assert.equal(state.prepares.length, 0);
});

test('refuses unsupported bytes and non-picker URI schemes', async () => {
  state.bytes = Buffer.from('<script>fixture</script>');
  assert.equal((await upload()).success, false);
  assert.equal(state.closed, 1);
  assert.equal((await TopicAttachmentUploader.upload('https://example.test/a.jpg', input(), () => true)).success, false);
  assert.equal(state.opened, 1);
  assert.equal(state.prepares.length, 0);
});

test('cancellation before opening, during reading and after preparing suppresses upload', async () => {
  assert.equal((await upload(() => false)).errorMessage, '已取消图片插入');
  assert.equal(state.opened, 0);
  let active = true;
  state.bytes = fakeJpeg(80000);
  state.onRead = () => { active = false; };
  assert.equal((await upload(() => active)).errorMessage, '已取消图片插入');
  assert.equal(state.closed, 1);
  assert.equal(state.prepares.length, 0);
  active = true;
  state.onRead = undefined;
  state.onPrepare = () => { active = false; };
  assert.equal((await upload(() => active)).errorMessage, '已取消图片插入');
  assert.equal(state.closed, 2);
  assert.equal(state.httpCreated, 0);
});

test('failed preparation or missing auth never starts multipart upload', async () => {
  state.preparation.success = false;
  assert.equal((await upload()).success, false);
  state.preparation.success = true;
  state.preparation.body = JSON.stringify({ data: { fid: -7 } });
  assert.equal((await upload()).success, false);
  assert.equal(state.httpCreated, 0);
  assert.equal(state.closed, 2);
});

test('authorization diagnostics reveal only controlled phase and numeric status', async () => {
  state.preparation = { success: false, statusCode: 403, failureStage: 'http', nativeErrorCode: 0,
    error: 'fixture-cookie=1 private-auth secret-full-request', body: 'secret-response-body fixture-auth' };
  const result = await upload();
  assert.equal(result.errorMessage, '图片上传授权请求失败（HTTP 403），请稍后重试');
  assert.deepEqual(state.diagnostics, [
    '[NGAImageUpload] stage=prepare-start method=POST',
    '[NGAImageUpload] stage=prepare-http status=403 success=false reason=http native=0'
  ]);
  assert.ok(!state.diagnostics.join('\n').match(/cookie|secret|fixture-auth|file:\/\//));
  assert.equal(state.httpCreated, 0);
});

test('timeout and decoding failures provide accurate authorization feedback', async () => {
  state.preparation = { success: false, statusCode: 0, failureStage: 'request', nativeErrorCode: 2300028,
    body: '', error: 'fixture raw timeout' };
  assert.equal((await upload()).errorMessage, '获取图片上传授权超时，请重试');
  state.preparation = { success: false, statusCode: 200, failureStage: 'decode', nativeErrorCode: 0,
    body: '', error: 'fixture raw decoder error' };
  assert.equal((await upload()).errorMessage, '图片上传授权响应无法解析，请重试');
  assert.equal(state.httpCreated, 0);
});

test('HTTP rejection and connection failure always destroy the native request without retrying', async () => {
  state.responseCode = 500;
  assert.equal((await upload()).success, false);
  assert.equal(state.requests.length, 1);
  assert.equal(state.destroyed, 1);
  state.responseCode = 200;
  state.httpError = true;
  assert.equal((await upload()).success, false);
  assert.equal(state.requests.length, 2);
  assert.equal(state.destroyed, 2);
});

test('late completion after leaving the editor cannot expose an attachment receipt', async () => {
  let active = true;
  state.onRequest = () => { active = false; };
  const result = await upload(() => active);
  assert.equal(result.success, false);
  assert.equal(result.errorMessage, '已取消图片插入');
  assert.equal(result.attachment.url, '');
  assert.equal(state.destroyed, 1);
});

test('invalid upload data cannot produce BBCode despite HTTP success', async () => {
  state.responseBody = Buffer.from(JSON.stringify({ data: {
    url: 'https://evil.example/test.jpg', attachments: 'fixture', attachments_check: 'fixture'
  } }));
  const result = await upload();
  assert.equal(result.success, false);
  assert.equal(TopicAttachmentProtocol.buildMarkup(result.attachment), '');
  assert.equal(state.destroyed, 1);
});

test('decodes default UTF-8 and explicitly declared GBK attachment rejections', async () => {
  state.responseHeaders = {};
  state.responseBody = Buffer.from(JSON.stringify({ error: '图片无效' }));
  assert.equal((await upload()).errorMessage, '图片无效');
  state.responseHeaders = { 'content-type': 'text/plain; charset=gbk' };
  state.responseBody = Buffer.concat([Buffer.from('{"error":"'), Buffer.from([0xb4, 0xed, 0xce, 0xf3]), Buffer.from('"}')]);
  assert.equal((await upload()).errorMessage, '错误');
  assert.equal(state.destroyed, 2);
});

test('parses the attachment service real literal wrapper without logging any receipt', async () => {
  state.responseHeaders = {};
  state.responseBody = Buffer.from("window.script_muti_get_var_store={data:{url:'mon_202610/07/-7Qfixture-test.jpg'," +
    "attachments:'fixture-attachment',attachments_check:'fixture-check'},encode:'utf-8'}");
  const result = await upload();
  assert.equal(result.success, true);
  const diagnostics = state.diagnostics.join('\n');
  assert.match(diagnostics, /stage=upload-http status=200 responseType=array-buffer length=\d+/);
  assert.match(diagnostics, /stage=upload-structure chars=\d+ shape=nga-assignment wrapper=nga-js json=true/);
  assert.match(diagnostics, /stage=upload-parse success=true reason=none/);
  assert.ok(!diagnostics.match(/fixture-auth|fixture-cookie|fixture-attachment|fixture-check|mon_202610|file:\/\//));
});

test('reports malformed server data separately from network and decoding failures', async () => {
  state.responseBody = Buffer.from('<html><script>window.private="fixture-secret"</script></html>');
  assert.equal((await upload()).errorMessage, '服务器返回了无法识别的图片上传结果，请稍后重试');
  assert.match(state.diagnostics.join('\n'), /shape=html wrapper=html-script json=false/);
  assert.match(state.diagnostics.join('\n'), /stage=upload-parse success=false reason=json/);
  assert.ok(!state.diagnostics.join('\n').includes('fixture-secret'));
  state.responseResult = { fixture: true };
  assert.equal((await upload()).errorMessage, '图片上传响应无法解码，请稍后重试');
  assert.match(state.diagnostics.join('\n'), /stage=upload-failed reason=decode/);
  assert.equal(state.destroyed, 2);
});

test('shrinks large still images and frees compression and local preview resources', async () => {
  state.bytes = fakeJpeg(1100000);
  assert.equal((await upload()).success, true);
  assert.equal(filePart().data.byteLength, 65536);
  assert.equal(filePart().contentType, 'image/jpeg');
  assert.ok(Math.max(state.decoded[0].desiredSize.width, state.decoded[0].desiredSize.height) <= 2048);
  assert.equal(state.packed[0].needsPackProperties, false);
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [2, 2, 2]);
});

test('PNG transparency is kept when reducing the image instead of encoding JPEG', async () => {
  state.bytes = fakeJpeg(1100000);
  state.bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  assert.equal((await upload()).success, true);
  assert.equal(filePart().contentType, 'image/png');
  assert.equal(state.packed[0].format, 'image/png');
});

test('animated GIF and WebP remain intact and can report the server size restriction', async () => {
  state.bytes = Buffer.alloc(1100000, 0);
  state.bytes.write('GIF89a');
  assert.equal((await upload()).success, true);
  assert.deepEqual(Buffer.from(filePart().data), state.bytes);
  assert.equal(state.packed.length, 1, 'Only a small static local preview is encoded');
  assert.equal(state.packed[0].format, 'image/png');
  state.bytes = Buffer.alloc(1100000, 0);
  state.bytes.write('RIFF');
  state.bytes.write('WEBP', 8);
  state.frameCount = 2;
  state.responseBody = Buffer.from('{"error_code":9}');
  const result = await upload();
  assert.equal(result.success, false);
  assert.equal(result.errorMessage, '图片超过论坛允许的大小，请选择更小的图片');
  assert.equal(state.packed.length, 1, 'Rejected upload does not create another preview');
  assert.equal(state.sourceReleased, 2);
  assert.equal(state.requests.length, 2);
});

test('encoding failure releases PixelMap, packer and source, leaving draft and network untouched', async () => {
  state.bytes = fakeJpeg(1100000);
  state.packError = true;
  assert.equal((await upload()).success, false);
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [1, 1, 1]);
  assert.equal(state.closed, 1);
  assert.equal(state.prepares.length, 0);
});

test('failure to release a PixelMap still releases the remaining image resources', async () => {
  state.bytes = fakeJpeg(1100000);
  state.packError = true;
  state.pixelReleaseError = true;
  assert.equal((await upload()).success, false);
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [1, 1, 1]);
  assert.equal(state.prepares.length, 0);
});

test('confirmed upload supplies only an ephemeral bounded data URI from local uploaded bytes', async () => {
  state.packedLength = 180 * 1024;
  const result = await upload();
  assert.equal(result.success, true);
  assert.match(result.previewSource, /^data:image\/jpeg;base64,/);
  assert.ok(result.previewSource.length <= 256 * 1024);
  assert.equal(Buffer.from(result.previewSource.split(',')[1], 'base64').length, 180 * 1024);
  assert.ok(state.decoded.every(options => Math.max(options.desiredSize.width, options.desiredSize.height) <= 512));
  assert.equal(Object.hasOwn(result.attachment, 'previewSource'), false);
  assert.equal(state.requests[0].options.multiFormDataList.some(part => part.name === 'previewSource'), false);
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [1, 1, 1]);
  assert.ok(!state.diagnostics.join('\n').includes('base64,'));
});

test('local preview failures and oversized output do not invalidate a confirmed upload', async () => {
  state.packError = true;
  const packFailure = await upload();
  assert.equal(packFailure.success, true);
  assert.equal(packFailure.previewSource, '');
  assert.equal(packFailure.attachment.attachmentsCheck, 'fixture-check');
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [1, 1, 1]);
  state.packError = false;
  state.base64Error = true;
  assert.equal((await upload()).success, true);
  state.base64Error = false;
  state.packedLength = 200 * 1024;
  const oversized = await upload();
  assert.equal(oversized.success, true);
  assert.equal(oversized.previewSource, '');
  assert.equal(state.destroyed, 3);
  assert.equal(state.packerReleased, 3);
  assert.equal(state.sourceReleased, 3);
});

test('leaving the editor during preview prevents a late attachment insertion and frees all resources', async () => {
  let active = true;
  state.onPack = () => { active = false; };
  const result = await upload(() => active);
  assert.equal(result.success, false);
  assert.equal(result.errorMessage, '已取消图片插入');
  assert.equal(result.previewSource, '');
  assert.equal(result.attachment.url, '');
  assert.equal(state.requests.length, 1);
  assert.equal(state.destroyed, 1);
  assert.deepEqual([state.pixelReleased, state.packerReleased, state.sourceReleased], [1, 1, 1]);
});
