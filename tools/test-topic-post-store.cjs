'use strict';

// Run: node --test tools/test-topic-post-store.cjs
// Execute the real ETS model with fresh process-local state per fixture.
// No device, preferences, account credentials, or network service is accessed.
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
const filename = path.resolve(__dirname, '../entry/src/main/ets/model/TopicPostStore.ets');

function fixture() {
  const cache = new Map();
  function load(modelPath) {
    if (cache.has(modelPath)) return cache.get(modelPath).exports;
    const compiled = ts.transpileModule(fs.readFileSync(modelPath, 'utf8'), {
      fileName: modelPath.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    });
    const errors = (compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
    assert.equal(errors.length, 0,
      errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
    const module = { exports: {} };
    cache.set(modelPath, module);
    const sourceRequire = id => {
      assert.ok(id.startsWith('./'), 'Unexpected native dependency: ' + id);
      return load(path.resolve(path.dirname(modelPath), id + '.ets'));
    };
    const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
      compiled.outputText + '\n})', { filename: modelPath });
    evaluate(sourceRequire, module, module.exports);
    return module.exports;
  }
  return load(filename);
}

function makeDraft(Draft, label) {
  const draft = new Draft();
  draft.subject = 'title: ' + label;
  draft.content = 'body: ' + label;
  draft.anonymous = true;
  draft.uncertain = true;
  return draft;
}

function fields(draft) {
  return [draft.subject, draft.content, draft.anonymous, draft.uncertain];
}

test('new and removed drafts return all default fields without shared references', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const first = store.load('account-a', 'new', -7, 0, 0, 0);
  assert.deepEqual(fields(first), ['', '', false, false]);
  first.subject = 'not stored';
  assert.deepEqual(fields(store.load('account-a', 'new', -7, 0, 0, 0)), ['', '', false, false]);
  store.save('account-a', 'new', -7, 0, 0, 0, makeDraft(Draft, 'saved'));
  store.remove('account-a', 'new', -7, 0, 0, 0);
  assert.deepEqual(fields(store.load('account-a', 'new', -7, 0, 0, 0)), ['', '', false, false]);
});

test('drafts are isolated by account and negative board fid', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const contexts = [['account-a', -7], ['account-b', -7], ['account-a', -447601], ['account-a', 7]];
  contexts.forEach(([account, fid], index) => {
    store.save(account, 'new', fid, 0, 0, 0, makeDraft(Draft, String(index)));
  });
  contexts.forEach(([account, fid], index) => {
    assert.equal(store.load(account, 'new', fid, 0, 0, 0).subject, 'title: ' + index);
  });
  store.remove('account-a', 'new', -7, 0, 0, 0);
  assert.equal(store.load('account-b', 'new', -7, 0, 0, 0).subject, 'title: 1');
});

test('parent, child, sibling and stid-only boards retain the exact caller context', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const contexts = [[414, 0], [414, 12007887], [414, 13011773], [0, 12007887], [0, 13011773]];
  contexts.forEach(([fid, stid], index) => {
    store.save('account-a', 'new', fid, stid, 0, 0, makeDraft(Draft, String(index)));
  });
  contexts.forEach(([fid, stid], index) => {
    assert.equal(store.load('account-a', 'new', fid, stid, 0, 0).subject, 'title: ' + index);
  });
  store.remove('account-a', 'new', 0, 12007887, 0, 0);
  assert.equal(store.load('account-a', 'new', 414, 12007887, 0, 0).subject, 'title: 1');
  assert.equal(store.load('account-a', 'new', 0, 13011773, 0, 0).subject, 'title: 4');
});

test('action, tid and pid are all part of the draft identity', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const contexts = [['new', 0, 0], ['reply', 0, 0], ['new', 123, 0], ['new', 123, 456], ['new', 0, 456]];
  contexts.forEach(([action, tid, pid], index) => {
    store.save('account-a', action, -7, 0, tid, pid, makeDraft(Draft, String(index)));
  });
  contexts.forEach(([action, tid, pid], index) => {
    assert.equal(store.load('account-a', action, -7, 0, tid, pid).subject, 'title: ' + index);
  });
});

test('saving and loading copy every draft field and prevent page reference leaks', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const draft = makeDraft(Draft, 'original');
  store.save('account-a', 'new', -7, 0, 0, 0, draft);
  const expected = fields(draft);
  draft.subject = 'mutated input';
  draft.content = 'mutated input body';
  draft.anonymous = false;
  draft.uncertain = false;
  const firstLoad = store.load('account-a', 'new', -7, 0, 0, 0);
  assert.deepEqual(fields(firstLoad), expected);
  firstLoad.subject = 'mutated result';
  firstLoad.content = 'mutated result body';
  firstLoad.anonymous = false;
  firstLoad.uncertain = false;
  const secondLoad = store.load('account-a', 'new', -7, 0, 0, 0);
  assert.deepEqual(fields(secondLoad), expected);
  assert.notEqual(firstLoad, secondLoad);
});

test('uploaded attachments survive reopening and are copied in both directions', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const draft = makeDraft(Draft, 'with image');
  const attachment = { url: 'mon_202610/07/fixture.png', attachments: 'fixture-id', attachmentsCheck: 'fixture-check' };
  draft.attachments = [attachment];
  store.save('account-a', 'reply', -7, 0, 123, 456, draft);
  const expected = JSON.parse(JSON.stringify(draft.attachments));
  attachment.attachmentsCheck = 'changed original';
  draft.attachments.push({ ...attachment, url: 'mon_202610/07/other.png' });
  const first = store.load('account-a', 'reply', -7, 0, 123, 456);
  assert.deepEqual(JSON.parse(JSON.stringify(first.attachments)), expected);
  first.attachments[0].url = 'changed load';
  first.attachments.splice(0);
  const reopened = store.load('account-a', 'reply', -7, 0, 123, 456);
  assert.deepEqual(JSON.parse(JSON.stringify(reopened.attachments)), expected);
  assert.notEqual(reopened.attachments, first.attachments);
  assert.deepEqual(store.load('account-b', 'reply', -7, 0, 123, 456).attachments, []);
  store.remove('account-a', 'reply', -7, 0, 123, 456);
  assert.deepEqual(store.load('account-a', 'reply', -7, 0, 123, 456).attachments, []);
});

test('separator characters in account and action cannot collide with another draft key', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const contexts = [['account|new', 'reply'], ['account', 'new|reply'], ['1:a|b', 'c'], ['a', 'b|c']];
  contexts.forEach(([account, action], index) => {
    store.save(account, action, -7, 0, 0, 0, makeDraft(Draft, String(index)));
  });
  contexts.forEach(([account, action], index) => {
    assert.equal(store.load(account, action, -7, 0, 0, 0).subject, 'title: ' + index);
  });
});

test('publish revisions increment only the specified account and board context', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  const contexts = [['account-a', -7, 0], ['account-b', -7, 0], ['account-a', 414, 0],
    ['account-a', 414, 12007887], ['account-a', 0, 12007887], ['account-a', 0, 13011773]];
  contexts.forEach(([account, fid, stid], index) => {
    assert.equal(store.getRevision(account, fid, stid), 0);
    for (let count = 0; count <= index; count++) store.markPublished(account, fid, stid);
  });
  contexts.forEach(([account, fid, stid], index) => {
    assert.equal(store.getRevision(account, fid, stid), index + 1);
  });
  store.save('account-a', 'new', -7, 0, 0, 0, makeDraft(Draft, 'retained'));
  store.markPublished('account-a', -7, 0);
  assert.equal(store.getRevision('account-a', -7, 0), 2);
  assert.equal(store.load('account-a', 'new', -7, 0, 0, 0).subject, 'title: retained');
  store.remove('account-a', 'new', -7, 0, 0, 0);
  assert.equal(store.getRevision('account-a', -7, 0), 2);
});

test('empty account keys never save drafts or publication revisions', () => {
  const { TopicPostStore: store, NgaTopicPostDraft: Draft } = fixture();
  store.save('', 'new', -7, 0, 0, 0, makeDraft(Draft, 'anonymous'));
  store.markPublished('', -7, 0);
  store.remove('', 'new', -7, 0, 0, 0);
  assert.deepEqual(fields(store.load('', 'new', -7, 0, 0, 0)), ['', '', false, false]);
  assert.equal(store.getRevision('', -7, 0), 0);
  assert.equal(store.getRevision('account-a', -7, 0), 0);
});

test('a fresh model lifetime does not inherit drafts or publication revisions', () => {
  const first = fixture();
  first.TopicPostStore.save('account-a', 'new', -7, 0, 0, 0, makeDraft(first.NgaTopicPostDraft, 'old process'));
  first.TopicPostStore.markPublished('account-a', -7, 0);
  const second = fixture();
  assert.deepEqual(fields(second.TopicPostStore.load('account-a', 'new', -7, 0, 0, 0)), ['', '', false, false]);
  assert.equal(second.TopicPostStore.getRevision('account-a', -7, 0), 0);
});
