'use strict';

/*
 * Run: node --test tools/test-topic-post-page.cjs
 * Execute real ReplyPage and TopicListPage methods extracted with the DevEco
 * ETS AST, plus the actual post protocol/parser/store. HTTP, login and UI are
 * local fixtures only; no network, cookies, credentials or device are accessed.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { test } = require('node:test');

const root = path.resolve(__dirname, '..');
const devecoHome = process.env.DEVECO_HOME || 'D:/software/DevEco Studio';
const loaderRoot = path.join(devecoHome, 'sdk/default/openharmony/ets/build-tools/ets-loader');
const compilerPath = process.env.TYPESCRIPT_PATH || path.join(loaderRoot, 'node_modules/typescript');
assert.ok(fs.existsSync(compilerPath), 'Set DEVECO_HOME or TYPESCRIPT_PATH to the DevEco SDK compiler');
const ts = require(compilerPath);
const componentMap = require(path.join(loaderRoot, 'lib/component_map.js'));
const parserOptions = { ets: { components: Object.keys(componentMap.COMPONENT_MAP)
  .concat(['AppSubPage', 'PostEmoticonPicker', 'PostContentPreview']) } };

function transpile(source, filename) {
  const result = ts.transpileModule(source, {
    fileName: filename, reportDiagnostics: true,
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  });
  const errors = (result.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error);
  assert.equal(errors.length, 0,
    errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')).join('\n'));
  return result.outputText;
}

function realMethods(relativePath, name, names, globals, options = {}) {
  const filename = path.join(root, relativePath);
  const source = fs.readFileSync(filename, 'utf8');
  const ast = ts.createSourceFile(filename, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parserOptions);
  assert.deepEqual(ast.parseDiagnostics.map(item => {
    const pos = ast.getLineAndCharacterOfPosition(item.start || 0);
    return `${pos.line + 1}:${pos.character + 1} ${ts.flattenDiagnosticMessageText(item.messageText, '\n')}`;
  }), [], `${name} must parse with the DevEco ETS parser`);
  const component = ast.statements.find(node => node.name && node.name.getText(ast) === name);
  assert.ok(component, name);
  const methods = new Map(component.members.filter(ts.isMethodDeclaration).map(method => [method.name.getText(ast), method]));
  const selected = new Map();
  const excluded = new Set(options.exclude || []);
  function add(methodName) {
    if (selected.has(methodName) || excluded.has(methodName)) return;
    const method = methods.get(methodName);
    assert.ok(method, `Missing actual ${name} method ${methodName}`);
    selected.set(methodName, method);
    function visit(node) {
      if (ts.isPropertyAccessExpression(node) &&
        (node.expression.kind === ts.SyntaxKind.ThisKeyword ||
          (options.static && ts.isIdentifier(node.expression) && node.expression.getText(ast) === name))) {
        const dependency = node.name.getText(ast);
        if (methods.has(dependency)) add(dependency);
      }
      ts.forEachChild(node, visit);
    }
    visit(method.body);
  }
  names.forEach(add);
  const helpers = ast.statements.filter(node =>
    (ts.isClassDeclaration(node) && node !== component) || ts.isVariableStatement(node))
    .map(node => node.getText(ast)).join('\n');
  const className = options.static ? name : 'RealSubject';
  const output = transpile(helpers + '\nclass ' + className + ' {\n' +
    Array.from(selected.values(), method => method.getText(ast)).join('\n') +
    `\n}\nglobalThis.RealSubject = ${className};`, filename);
  const context = vm.createContext({ ...globals });
  vm.runInContext(output, context);
  return options.static ? context.RealSubject : new context.RealSubject();
}

function loadModel(name, dependencies = {}) {
  const filename = path.join(root, 'entry/src/main/ets/model', name + '.ets');
  const module = { exports: {} };
  const sourceRequire = id => {
    assert.ok(Object.hasOwn(dependencies, id), 'Unexpected model dependency: ' + id);
    return dependencies[id];
  };
  const evaluate = vm.runInThisContext('(function(require, module, exports) {\n' +
    transpile(fs.readFileSync(filename, 'utf8'), filename) + '\n})', { filename });
  evaluate(sourceRequire, module, module.exports);
  return module.exports;
}

function defer() {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}
const settle = () => new Promise(resolve => setImmediate(resolve));
const clone = value => JSON.parse(JSON.stringify(value));
const DOMAIN = 'https://forum.invalid';
const TID = 34567001;
const SUBJECT = '  标题 [s:ac:good] & 保留首尾空格  ';
const CONTENT = '  你好\n[img]https://img.invalid/a.png[/img][s:ac:good]\n保留换行与首尾空格  ';
const ACK = JSON.stringify({ data: { __MESSAGE: { 0: 0,
  1: `发贴完毕 ... <a href="read.php?tid=${TID}">查看话题</a>` } } });
const REJECTED = JSON.stringify({ data: { __MESSAGE: { 0: 1, 1: '没有发帖权限' } } });
const defaultFields = draft => [draft.subject, draft.content, draft.anonymous, draft.uncertain];
const IMAGE = { url: 'mon_202610/07/fixture.png', attachments: 'fixture-image-id',
  attachmentsCheck: 'fixture-image-check' };
const IMAGE_PREVIEW = 'data:image/png;base64,' +
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl4hUMAAAAASUVORK5CYII=';
const IMAGE_PREVIEW_URL = 'https://img.nga.cn/attachments/' + IMAGE.url;

function pageFixture(params = {}) {
  const requests = [], encodings = [], toasts = [], dialogs = [], pushes = [], replacements = [], backs = [], keyboards = [];
  const selections = [], uploads = [], carets = [];
  const config = {
    account: 'account-a', loggedIn: true,
    params: { action: 'new', fid: -7, stid: 0, tid: 0, pid: 0, title: '板块名称', ...params },
    encode: value => encodeURIComponent(value),
    dialog: async () => ({ index: 0 }),
    push: async () => undefined,
    select: async () => ({ photoUris: [] }),
    upload: async () => ({ success: true, errorMessage: '', attachment: { ...IMAGE } }),
    prepare: async request => {
      const query = new URL(request.url).searchParams;
      return { success: true, statusCode: 200, body: JSON.stringify({ data: {
        auth: 'fixture-attachment-auth', fid: Number(query.get('fid')) || 414,
        stid: Number(query.get('stid') || 0)
      } }) };
    },
    submit: async () => ({ success: true, statusCode: 200, body: ACK })
  };
  const HttpClient = {
    getDomain: () => DOMAIN,
    post(url, fields, useGbk) {
      const request = { url, fields: clone(fields), useGbk };
      requests.push(request);
      return fields.step === '2' ? config.submit(request) : config.prepare(request);
    }
  };
  const NgaJsonParser = realMethods('entry/src/main/ets/model/NgaJsonParser.ets', 'NgaJsonParser',
    ['parseResponseObject'], {}, { static: true });
  const parser = loadModel('TopicPostParser', { './NgaJsonParser': { NgaJsonParser } });
  const attachmentLiteral = loadModel('TopicAttachmentLiteral');
  const attachmentProtocol = loadModel('TopicAttachmentProtocol', {
    './NgaJsonParser': { NgaJsonParser }, './TopicPostParser': parser,
    './TopicAttachmentLiteral': attachmentLiteral, './HttpClient': { HttpClient }
  });
  const protocol = loadModel('TopicPostProtocol', { './HttpClient': { HttpClient },
    './TopicAttachmentProtocol': attachmentProtocol });
  const store = loadModel('TopicPostStore', { './TopicAttachmentProtocol': attachmentProtocol });
  const editor = loadModel('PostEditorText');
  const emoticons = loadModel('EmoticonUtils');
  const UrlBuilder = realMethods('entry/src/main/ets/model/UrlBuilder.ets', 'UrlBuilder',
    ['buildPostSubmitUrl'], { HttpClient }, { static: true });
  const globals = {
    ...parser, ...protocol, ...store, ...attachmentProtocol, ...editor, ...emoticons, HttpClient, UrlBuilder,
    photoAccessHelper: {
      PhotoViewMIMETypes: { IMAGE_TYPE: 'image' }, PhotoSelectOptions: class {},
      PhotoViewPicker: class { select(options) { selections.push(clone(options)); return config.select(options); } }
    },
    TopicAttachmentUploader: { upload(uri, input, isCurrent) {
      const request = { uri, input: clone(input), isCurrent };
      uploads.push(request); return config.upload(request);
    } },
    setTimeout, clearTimeout, focusControl: { requestFocus() {} },
    GbkEncoder: { encode(value) { encodings.push(value); return config.encode(value); } },
    LoginStore: { init() {}, hasUser: () => config.loggedIn, getUser: () => ({ uid: config.account }) },
    SettingsStore: { init() {}, getBool: () => false, getInt: () => 0 },
    SettingKeys: { NIGHT: 'night', THEME: 'theme' }, SettingDefaults: { NIGHT: false, THEME: 0 },
    KeyboardAvoidMode: { OFFSET: 'offset', RESIZE: 'resize' }, applyWindowTheme() {},
    COLOR_DAY_SUB: '#57616B', COLOR_NIGHT_SUB: '#B1BAC4', themeAccentTextColor: () => '#0960BD'
  };
  function attachUi(host) {
    host.getUIContext = () => ({
      getKeyboardAvoidMode: () => 'offset', setKeyboardAvoidMode: mode => keyboards.push(mode),
      getFocusController: () => ({ requestFocus() {} }),
      getRouter: () => ({ getParams: () => config.params, back: () => backs.push(true),
        pushUrl: async request => { pushes.push(clone(request)); await config.push(request); },
        replaceUrl: async request => { replacements.push(clone(request)); } }),
      getPromptAction: () => ({ showToast: item => toasts.push(clone(item)),
        showDialog: item => { dialogs.push(clone(item)); return config.dialog(item); } })
    });
    return host;
  }
  function reopen() {
    const host = realMethods('entry/src/main/ets/pages/ReplyPage.ets', 'ReplyPage',
      ['aboutToAppear', 'aboutToDisappear', 'submitPost', 'onPageShow', 'navigateBack', 'onBackPress',
        'viewCurrentBoard', 'confirmRetry', 'viewPublishedTopic', 'insertContent', 'insertEmoticon',
        'addImages', 'canEdit', 'isCurrentMedia'], globals);
    Object.assign(host, { nightMode: false, themeIndex: 0, action: 'reply', tid: 0, fid: 0, stid: 0, pid: 0,
      title: '', postContent: '', postSubject: '', anonymous: false, isSubmitting: false,
      submitResult: '', submitSuccess: false, submitUncertain: false, uncertainReviewed: false,
      contextInvalid: false, publishedTid: 0, mounted: false, sendVersion: 0, activeAccountKey: '',
      boardReviewPending: false, publishedFid: 0, keyboardAvoidMode: 'offset', keyboardModeSet: false,
      uploadedAttachments: [], isAddingImages: false, mediaMessage: '', mediaVersion: 0, showEmoticonSheet: false,
      imagePreviews: {},
      selectionStart: -1, selectionEnd: -1,
      textController: { caretPosition: position => carets.push(position), stopEditing() {} }, ctx: {} });
    attachUi(host).aboutToAppear();
    return host;
  }
  const host = reopen();
  host.postSubject = SUBJECT;
  host.postContent = CONTENT;
  host.anonymous = true;
  const savedDraft = (account = 'account-a', context = config.params) => store.TopicPostStore.load(account,
    context.action, context.fid, context.stid, context.tid, context.pid);
  function boardHost() {
    const board = realMethods('entry/src/main/ets/pages/TopicListPage.ets', 'TopicListPage',
      ['goToPost', 'refreshPublishedTopics'], globals, { exclude: ['loadTopicList'] });
    Object.assign(board, { fid: config.params.fid, stid: config.params.stid, title: config.params.title,
      nightMode: false, isLoading: false, isLoadingMore: false, publishAccountKey: config.account,
      publishRevision: store.TopicPostStore.getRevision(config.account, config.params.fid, config.params.stid) });
    const loads = [];
    board.loadTopicList = page => { loads.push(page); };
    attachUi(board);
    return { board, loads };
  }
  return { host, config, requests, encodings, toasts, dialogs, pushes, replacements, backs, keyboards,
    selections, uploads, carets, ...store, ...attachmentProtocol, ...editor, ...emoticons,
    savedDraft, reopen, boardHost };
}

function visibleState(host) {
  return [host.postSubject, host.postContent, host.submitResult, host.submitSuccess,
    host.submitUncertain, host.publishedTid, host.contextInvalid, host.isSubmitting];
}

test('negative fid and child stid use an empty-body prepare followed by the exact raw-text submit', async () => {
  for (const params of [{ fid: -7, stid: 0 }, { fid: 414, stid: 12007887 }]) {
    const f = pageFixture(params);
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
    const prepare = new URL(f.requests[0].url);
    assert.equal(prepare.pathname, '/post.php');
    assert.equal(prepare.searchParams.get('fid'), String(params.fid));
    assert.equal(prepare.searchParams.get('stid'), params.stid ? String(params.stid) : null);
    assert.equal(prepare.searchParams.get('action'), 'new');
    assert.equal(prepare.searchParams.get('lite'), 'js');
    assert.deepEqual(f.requests[0].fields, {});
    assert.equal(f.requests[0].useGbk, true);
    assert.deepEqual(f.requests[1], { url: DOMAIN + '/post.php', useGbk: true, fields: {
      step: '2', post_content: CONTENT, action: 'new', post_subject: SUBJECT,
      fid: String(params.fid), ...(params.stid ? { stid: String(params.stid) } : {}), anony: '1'
    } });
    assert.deepEqual(f.encodings, [CONTENT, SUBJECT]);
    assert.equal(f.host.submitSuccess, true);
    assert.equal(f.host.publishedTid, TID);
  }
});

test('stid-only publish resolves its actual fid but clears and refreshes only the original board context', async () => {
  const f = pageFixture({ fid: 0, stid: 12007887 });
  f.host.saveDraft();
  await f.host.submitPost();
  assert.equal(f.requests[1].fields.fid, '414');
  assert.equal(f.requests[1].fields.stid, '12007887');
  assert.equal(f.host.fid, 0, 'The original board/draft identity must remain stid-only');
  assert.deepEqual(defaultFields(f.savedDraft()), ['', '', false, false]);
  assert.equal(f.TopicPostStore.getRevision('account-a', 0, 12007887), 1);
  assert.equal(f.TopicPostStore.getRevision('account-a', 414, 12007887), 0);
  await f.host.viewPublishedTopic();
  assert.deepEqual(f.replacements, [{ url: 'pages/ArticleListPage', params: { tid: TID, fid: 414 } }]);
});

test('blank titles and bodies never initiate prepare or submit requests', async () => {
  for (const field of ['postSubject', 'postContent']) {
    for (const text of ['', '   ', '\n\t\r']) {
      const f = pageFixture();
      f.host[field] = text;
      await f.host.submitPost();
      assert.equal(f.requests.length, 0);
      assert.equal(f.host[field], text);
      assert.ok(f.host.submitResult.length > 0);
      assert.equal(f.host.isSubmitting, false);
    }
  }
});

test('local GBK failure in either raw field sends zero requests and retains an editable draft', async () => {
  for (const unsupported of [CONTENT, SUBJECT]) {
    const f = pageFixture();
    f.config.encode = text => { if (text === unsupported) throw new Error('文本包含 GBK 不支持的字符'); return text; };
    await f.host.submitPost();
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.postContent, CONTENT);
    assert.equal(f.host.postSubject, SUBJECT);
    assert.equal(f.host.submitUncertain, false);
    assert.equal(f.host.isSubmitting, false);
    assert.match(f.host.submitResult, /GBK|字符/);
  }
});

test('invalid posting context and changed login never send a prepare request', async () => {
  for (const alter of [f => { f.host.fid = 0; }, f => { f.host.stid = -1; },
    f => { f.host.fid = NaN; }, f => { f.host.stid = 1.5; }, f => { f.host.action = 'unsupported'; },
    f => { f.config.loggedIn = false; }, f => { f.config.account = 'account-b'; }]) {
    const f = pageFixture();
    alter(f);
    await f.host.submitPost();
    assert.equal(f.requests.length, 0);
    assert.equal(f.host.postSubject, SUBJECT);
    assert.equal(f.host.postContent, CONTENT);
  }
});

test('failed, rejected, mismatched or malformed preparation never submits content', async () => {
  for (const response of [
    { success: false, statusCode: 0, body: '', error: 'timeout' },
    { success: true, statusCode: 200, body: REJECTED },
    { success: true, statusCode: 200, body: '{}' },
    { success: true, statusCode: 200, body: '{malformed' },
    { success: true, statusCode: 200, body: JSON.stringify({ data: { auth: 'fixture', fid: 414 } }) }
  ]) {
    const f = pageFixture();
    f.config.prepare = async () => response;
    await f.host.submitPost();
    assert.equal(f.requests.length, 1);
    assert.deepEqual(f.requests[0].fields, {});
    assert.equal(f.host.submitUncertain, false);
    assert.equal(f.host.submitSuccess, false);
    assert.equal(f.host.isSubmitting, false);
    assert.equal(f.savedDraft().content, CONTENT);
    assert.ok(f.host.submitResult.length > 0);
  }
});

test('a thrown prepare request remains definitely unsent and can be retried deliberately', async () => {
  const f = pageFixture();
  const defaultPrepare = f.config.prepare;
  f.config.prepare = async () => { throw new Error('prepare offline'); };
  await f.host.submitPost();
  assert.equal(f.requests.length, 1);
  assert.equal(f.host.submitUncertain, false);
  f.config.prepare = defaultPrepare;
  await f.host.submitPost();
  assert.equal(f.requests.length, 3);
  assert.equal(f.host.submitSuccess, true);
});

test('concurrent taps during preparation and submission cause only one final POST', async () => {
  const f = pageFixture(), prepared = defer(), sent = defer();
  f.config.prepare = () => prepared.promise;
  f.config.submit = () => sent.promise;
  const operation = f.host.submitPost();
  assert.equal(f.host.isSubmitting, true);
  await f.host.submitPost();
  assert.equal(f.requests.length, 1);
  prepared.resolve({ success: true, statusCode: 200, body: JSON.stringify({ data: { auth: 'fixture', fid: -7 } }) });
  await settle();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.submitUncertain, true, 'Persist uncertainty before the final POST can leave the process');
  assert.equal(f.savedDraft().uncertain, true);
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
  sent.resolve({ success: true, statusCode: 200, body: ACK });
  await operation;
  assert.equal(f.host.isSubmitting, false);
  assert.equal(f.host.submitSuccess, true);
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
});

test('confirmed success clears its draft and marks only its account and original board', async () => {
  const f = pageFixture({ fid: -7, stid: 123 });
  const other = new f.NgaTopicPostDraft(); other.content = 'other board draft';
  f.TopicPostStore.save('account-b', 'new', -7, 123, 0, 0, other);
  f.TopicPostStore.save('account-a', 'new', -7, 456, 0, 0, other);
  await f.host.submitPost();
  assert.equal(f.host.postSubject, '');
  assert.equal(f.host.postContent, '');
  assert.equal(f.host.submitUncertain, false);
  assert.equal(f.host.submitSuccess, true);
  assert.deepEqual(defaultFields(f.savedDraft()), ['', '', false, false]);
  assert.equal(f.TopicPostStore.getRevision('account-a', -7, 123), 1);
  assert.equal(f.TopicPostStore.getRevision('account-b', -7, 123), 0);
  assert.equal(f.TopicPostStore.getRevision('account-a', -7, 456), 0);
  assert.equal(f.TopicPostStore.load('account-b', 'new', -7, 123, 0, 0).content, other.content);
  assert.equal(f.TopicPostStore.load('account-a', 'new', -7, 456, 0, 0).content, other.content);
  await f.host.navigateBack();
  assert.equal(f.backs.length, 1);
  assert.equal(f.dialogs.length, 0);
});

test('unknown bodies and transport results retain draft and block blind duplicate submissions', async () => {
  for (const response of [
    { success: true, statusCode: 200, body: '{}' },
    { success: true, statusCode: 200, body: '{malformed' },
    { success: true, statusCode: 200, body: '' },
    { success: false, statusCode: 0, body: '', error: 'timeout' },
    { success: false, statusCode: 502, body: ACK, error: 'HTTP 502' }
  ]) {
    const f = pageFixture();
    f.config.submit = async () => response;
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
    assert.equal(f.host.submitUncertain, true);
    assert.equal(f.host.submitSuccess, false);
    assert.equal(f.host.isSubmitting, false);
    assert.equal(f.host.postSubject, SUBJECT);
    assert.equal(f.host.postContent, CONTENT);
    assert.equal(f.savedDraft().uncertain, true);
    assert.equal(f.TopicPostStore.getRevision('account-a', -7, 0), 0);
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
  }
});

test('a thrown final POST preserves the uncertain draft without an automatic retry', async () => {
  const f = pageFixture();
  f.config.submit = async () => { throw new Error('submit timeout'); };
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.submitUncertain, true);
  assert.equal(f.savedDraft().uncertain, true);
  assert.equal(f.savedDraft().content, CONTENT);
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
});

test('explicit server rejection leaves an editable draft for an intentional modified retry', async () => {
  const f = pageFixture();
  f.config.submit = async () => ({ success: true, statusCode: 200, body: REJECTED });
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.submitUncertain, false);
  assert.equal(f.savedDraft().uncertain, false);
  assert.equal(f.host.postContent, CONTENT);
  assert.match(f.host.submitResult, /没有发帖权限/);
  f.host.postContent = '修改后的内容';
  f.config.submit = async () => ({ success: true, statusCode: 200, body: ACK });
  await f.host.submitPost();
  assert.equal(f.requests.length, 4);
  assert.equal(f.requests[3].fields.post_content, '修改后的内容');
  assert.equal(f.host.submitSuccess, true);
});

test('leaving or changing accounts during prepare never initiates the final POST', async () => {
  for (const alter of [f => f.host.aboutToDisappear(), f => { f.config.account = 'account-b'; f.host.onPageShow(); }]) {
    const f = pageFixture(), prepared = defer();
    f.config.prepare = () => prepared.promise;
    const operation = f.host.submitPost();
    alter(f);
    const afterAlter = visibleState(f.host);
    prepared.resolve({ success: true, statusCode: 200, body: JSON.stringify({ data: { auth: 'fixture', fid: -7 } }) });
    await operation;
    assert.equal(f.requests.length, 1);
    assert.deepEqual(visibleState(f.host), afterAlter);
    assert.equal(f.savedDraft().content, CONTENT);
    assert.equal(f.savedDraft().uncertain, false);
    assert.equal(f.TopicPostStore.getRevision('account-a', -7, 0), 0);
  }
});

test('late submit success after exit or account change never mutates UI or erases an unconfirmed draft', async () => {
  for (const alter of [f => f.host.aboutToDisappear(), f => { f.config.account = 'account-b'; f.host.onPageShow(); }]) {
    const f = pageFixture(), sent = defer();
    f.config.submit = () => sent.promise;
    const operation = f.host.submitPost();
    await settle();
    assert.equal(f.requests.length, 2);
    alter(f);
    const afterAlter = visibleState(f.host);
    sent.resolve({ success: true, statusCode: 200, body: ACK });
    await operation;
    assert.deepEqual(visibleState(f.host), afterAlter);
    assert.equal(f.savedDraft().content, CONTENT);
    assert.equal(f.savedDraft().subject, SUBJECT);
    assert.equal(f.savedDraft().uncertain, true);
    assert.equal(f.TopicPostStore.getRevision('account-a', -7, 0), 0);
    assert.equal(f.TopicPostStore.getRevision('account-b', -7, 0), 0);
  }
});

test('unmounted composer never sends and restores the previous keyboard avoidance mode', async () => {
  const f = pageFixture();
  f.host.aboutToDisappear();
  await f.host.submitPost();
  assert.equal(f.requests.length, 0);
  assert.deepEqual(f.keyboards, ['resize', 'offset']);
  assert.equal(f.savedDraft().content, CONTENT);
});

test('back navigation retains editing unless explicitly choosing save and return', async () => {
  const f = pageFixture();
  await f.host.navigateBack();
  assert.equal(f.backs.length, 0);
  assert.equal(f.host.postContent, CONTENT);
  f.config.dialog = async () => ({ index: 1 });
  await f.host.navigateBack();
  assert.equal(f.backs.length, 1);
  assert.deepEqual(defaultFields(f.savedDraft()), [SUBJECT, CONTENT, true, false]);
  const reopened = f.reopen();
  assert.deepEqual([reopened.postSubject, reopened.postContent, reopened.anonymous, reopened.submitUncertain],
    [SUBJECT, CONTENT, true, false]);
});

test('the same page cannot navigate back while a final POST is pending', async () => {
  const f = pageFixture(), sent = defer();
  f.config.submit = () => sent.promise;
  const operation = f.host.submitPost();
  await settle();
  await f.host.navigateBack();
  assert.equal(f.backs.length, 0);
  assert.equal(f.dialogs.length, 0);
  assert.ok(f.toasts.some(item => /正在发布/.test(item.message)));
  sent.resolve({ success: true, statusCode: 200, body: ACK });
  await operation;
});

test('reopening drafts restores only the same account and exact board context', () => {
  const f = pageFixture({ fid: 0, stid: 12007887 });
  f.host.saveDraft();
  const same = f.reopen();
  assert.equal(same.postContent, CONTENT);
  f.config.params = { ...f.config.params, fid: 414 };
  assert.equal(f.reopen().postContent, '');
  f.config.params = { ...f.config.params, fid: 0, stid: 13011773 };
  assert.equal(f.reopen().postContent, '');
  f.config.params = { ...f.config.params, stid: 12007887 };
  f.config.account = 'account-b';
  assert.equal(f.reopen().postContent, '');
  f.config.account = 'account-a';
  assert.equal(f.reopen().postContent, CONTENT);
});

test('an uncertain draft stays locked after reopen and needs board review plus explicit confirmation', async () => {
  const f = pageFixture({ fid: 0, stid: 12007887 });
  f.config.submit = async () => ({ success: true, statusCode: 200, body: '{}' });
  await f.host.submitPost();
  const reopened = f.reopen();
  assert.equal(reopened.submitUncertain, true);
  assert.equal(reopened.postContent, CONTENT);
  assert.equal(reopened.uncertainReviewed, false);
  f.config.dialog = async () => ({ index: 1 });
  await reopened.confirmRetry();
  assert.equal(f.dialogs.length, 0);
  assert.equal(reopened.submitUncertain, true);
  await reopened.viewCurrentBoard();
  assert.deepEqual(f.pushes, [{ url: 'pages/TopicListPage', params: { fid: 0, stid: 12007887, title: '板块名称' } }]);
  assert.equal(reopened.uncertainReviewed, false);
  reopened.onPageShow();
  assert.equal(reopened.uncertainReviewed, true);
  await reopened.submitPost();
  assert.equal(f.requests.length, 2, 'Review alone must not unlock or automatically resend');
  f.config.dialog = async () => ({ index: 0 });
  await reopened.confirmRetry();
  assert.equal(reopened.submitUncertain, true);
  f.config.dialog = async () => ({ index: 1 });
  await reopened.confirmRetry();
  assert.equal(reopened.submitUncertain, false);
  assert.equal(f.savedDraft().uncertain, false);
  assert.equal(f.requests.length, 2);
  f.config.submit = async () => ({ success: true, statusCode: 200, body: ACK });
  await reopened.submitPost();
  assert.equal(f.requests.length, 4);
  assert.equal(reopened.submitSuccess, true);
});

test('a failed board navigation cannot satisfy uncertain-result review', async () => {
  const f = pageFixture();
  f.host.submitUncertain = true;
  f.config.push = async () => { throw new Error('fixture router failure'); };
  await f.host.viewCurrentBoard();
  f.host.onPageShow();
  assert.equal(f.host.uncertainReviewed, false);
  assert.equal(f.host.boardReviewPending, false);
  assert.equal(f.host.submitUncertain, true);
});

test('a late confirmation dialog cannot unlock the composer after switching accounts', async () => {
  const f = pageFixture(), decision = defer();
  f.host.submitUncertain = true;
  f.host.uncertainReviewed = true;
  f.host.saveDraft();
  f.config.dialog = () => decision.promise;
  const operation = f.host.confirmRetry();
  f.config.account = 'account-b';
  f.host.onPageShow();
  const afterChange = visibleState(f.host);
  decision.resolve({ index: 1 });
  await operation;
  assert.deepEqual(visibleState(f.host), afterChange);
  assert.equal(f.savedDraft().uncertain, true);
});

test('board post entry forwards negative fid, child stid and stid-only identity', async () => {
  for (const params of [{ fid: -7, stid: 0 }, { fid: 414, stid: 12007887 }, { fid: 0, stid: 12007887 }]) {
    const f = pageFixture(params), { board } = f.boardHost();
    await board.goToPost();
    assert.deepEqual(f.pushes, [{ url: 'pages/ReplyPage', params: {
      action: 'new', fid: params.fid, stid: params.stid, title: '板块名称'
    } }]);
  }
});

test('board post entry rejects invalid fid/stid contexts and offers login when signed out', async () => {
  for (const params of [{ fid: 0, stid: 0 }, { fid: NaN }, { stid: 1.5 }, { fid: -7, stid: -1 }]) {
    const f = pageFixture(params), { board } = f.boardHost();
    await board.goToPost();
    assert.equal(f.pushes.length, 0, JSON.stringify(params));
    assert.ok(f.toasts.length > 0);
  }
  const f = pageFixture(), { board } = f.boardHost();
  f.config.loggedIn = false;
  await board.goToPost();
  assert.equal(f.pushes.length, 0);
  f.config.dialog = async () => ({ index: 1 });
  await board.goToPost();
  assert.deepEqual(f.pushes, [{ url: 'pages/LoginPage' }]);
  assert.equal(f.requests.length, 0);
});

test('board refresh reacts once to its own publication and defers during existing pagination', () => {
  const f = pageFixture({ fid: 0, stid: 12007887 }), { board, loads } = f.boardHost();
  board.refreshPublishedTopics();
  assert.deepEqual(loads, []);
  f.TopicPostStore.markPublished('account-a', 414, 12007887);
  f.TopicPostStore.markPublished('account-b', 0, 12007887);
  board.refreshPublishedTopics();
  assert.deepEqual(loads, []);
  f.TopicPostStore.markPublished('account-a', 0, 12007887);
  board.isLoadingMore = true;
  board.refreshPublishedTopics();
  assert.deepEqual(loads, []);
  assert.equal(board.publishRevision, 0);
  board.isLoadingMore = false;
  board.refreshPublishedTopics();
  assert.deepEqual(loads, [1]);
  assert.equal(board.publishRevision, 1);
  board.refreshPublishedTopics();
  assert.deepEqual(loads, [1]);
  f.config.account = 'account-b';
  board.refreshPublishedTopics();
  assert.deepEqual(loads, [1, 1]);
  assert.equal(board.publishAccountKey, 'account-b');
});

test('reply mode preserves existing topic targeting and never marks a board as newly published', async () => {
  const f = pageFixture({ action: 'reply', fid: -7, tid: 123456, pid: 789 });
  f.host.postSubject = '';
  await f.host.submitPost();
  const prepare = new URL(f.requests[0].url);
  assert.equal(prepare.searchParams.get('tid'), '123456');
  assert.equal(prepare.searchParams.get('pid'), '789');
  assert.deepEqual(f.requests[1].fields, { step: '2', post_content: CONTENT, action: 'reply',
    fid: '-7', tid: '123456', pid: '789', anony: '1' });
  assert.deepEqual(f.encodings, [CONTENT]);
  assert.equal(f.host.submitSuccess, true);
  assert.equal(f.TopicPostStore.getRevision('account-a', -7, 0), 0);
});

test('editor inserts at a caret, replaces the selected range, and appends when no selection is available', () => {
  const { PostEditorText } = loadModel('PostEditorText');
  for (const [content, start, end, markup, expected, caret] of [
    ['前后', 1, 1, '[s:ng:doge]', '前[s:ng:doge]后', 12],
    ['前选中的文字后', 1, 6, '[img]./mon_202610/07/fixture.png[/img]',
      '前[img]./mon_202610/07/fixture.png[/img]后', 39],
    ['已有正文', -1, -1, '[s:ac:哭笑]', '已有正文[s:ac:哭笑]', 13]
  ]) {
    const result = PostEditorText.insert(content, start, end, markup);
    assert.equal(result.content, expected);
    assert.equal(result.caret, caret);
  }
});

test('editor normalizes reversed and stale selections without splitting a Unicode surrogate pair', () => {
  const { PostEditorText } = loadModel('PostEditorText');
  const reversed = PostEditorText.insert('前选中后', 3, 1, '[s:ng:doge]');
  assert.equal(reversed.content, '前[s:ng:doge]后');
  assert.equal(reversed.caret, 12);
  const stale = PostEditorText.insert('正文', 100, 100, '图');
  assert.equal(stale.content, '正文图');
  assert.equal(stale.caret, 3);
  const unavailable = PostEditorText.insert('正文', NaN, NaN, '图');
  assert.equal(unavailable.content, '正文图');
  const pair = PostEditorText.insert('A😀B', 2, 2, '图');
  assert.equal(pair.content, 'A图😀B');
  assert.equal(pair.caret, 2);
});

test('every selectable emoticon has a packaged image and inserts its original compatible BBCode', () => {
  const f = pageFixture();
  const rawfileRoot = path.join(root, 'entry/src/main/resources/rawfile');
  let total = 0;
  for (const category of f.EMOTION_CATEGORIES) {
    for (const name of f.getEmoticonList(category)) {
      const rawfile = f.getEmoticonRawfilePath(category, name);
      assert.ok(rawfile.length > 0, category + ':' + name);
      assert.ok(fs.statSync(path.join(rawfileRoot, rawfile)).size > 0, rawfile);
      f.host.postContent = '前后';
      f.host.selectionStart = 1;
      f.host.selectionEnd = 1;
      const code = '[s:' + category + ':' + name + ']';
      f.host.insertEmoticon(code);
      assert.equal(f.host.postContent, '前' + code + '后');
      const rendered = f.decodeAllEmoticons(code, () => 'data:image/png;base64,eA==');
      assert.match(rendered, /<img\b/);
      assert.ok(rendered.includes("alt='" + code + "'"));
      total++;
    }
  }
  assert.ok(total > 100);
  const original = f.host.postContent;
  for (const code of ['[s:ng:不存在]', '[s:constructor:doge]', '[s:ng:doge]\nextra', '<img src=x>']) {
    f.host.insertEmoticon(code);
    assert.equal(f.host.postContent, original);
  }
});

test('cancelled photo selection performs no upload and leaves the draft editable', async () => {
  const f = pageFixture();
  await f.host.addImages();
  assert.equal(f.selections.length, 1);
  assert.equal(f.selections[0].MIMEType, 'image');
  assert.equal(f.selections[0].maxSelectNumber, 6);
  assert.equal(f.uploads.length, 0);
  assert.equal(f.host.postContent, CONTENT);
  assert.deepEqual(clone(f.host.uploadedAttachments), []);
  assert.equal(f.host.isAddingImages, false);
  assert.equal(f.host.canEdit(), true);
});

test('signed out or locked composers never select, upload or insert media', async () => {
  const signedOut = pageFixture();
  signedOut.config.loggedIn = false;
  await signedOut.host.addImages();
  assert.equal(signedOut.selections.length, 0);
  assert.equal(signedOut.uploads.length, 0);
  for (const field of ['isSubmitting', 'submitSuccess', 'submitUncertain', 'contextInvalid', 'isAddingImages']) {
    const f = pageFixture();
    f.host[field] = true;
    assert.equal(f.host.canEdit(), false);
    f.host.insertEmoticon('[s:ng:doge]');
    await f.host.addImages();
    assert.equal(f.host.postContent, CONTENT, field);
    assert.equal(f.selections.length, 0, field);
    assert.equal(f.uploads.length, 0, field);
  }
  const unmounted = pageFixture();
  unmounted.host.aboutToDisappear();
  await unmounted.host.addImages();
  assert.equal(unmounted.selections.length, 0);
  assert.equal(unmounted.uploads.length, 0);
});

test('uploaded images insert at the captured selection and retain their paired attachment metadata', async () => {
  const f = pageFixture();
  f.host.postContent = '前删除后';
  f.host.selectionStart = 1;
  f.host.selectionEnd = 3;
  f.config.select = async () => ({ photoUris: ['photo://one', 'photo://two'] });
  f.config.upload = async request => ({ success: true, errorMessage: '', attachment: {
    url: 'mon_202610/07/' + (request.uri.endsWith('one') ? 'one' : 'two') + '.png',
    attachments: request.uri, attachmentsCheck: request.uri + '-check'
  } });
  await f.host.addImages();
  assert.equal(f.uploads.length, 2);
  assert.equal(f.uploads[0].uri, 'photo://one');
  assert.equal(f.uploads[1].uri, 'photo://two');
  assert.ok(f.uploads.every(request => request.isCurrent()));
  assert.equal(f.host.postContent,
    '前[img]./mon_202610/07/one.png[/img]\n[img]./mon_202610/07/two.png[/img]\n后');
  assert.deepEqual(clone(f.host.uploadedAttachments), [
    { url: 'mon_202610/07/one.png', attachments: 'photo://one', attachmentsCheck: 'photo://one-check' },
    { url: 'mon_202610/07/two.png', attachments: 'photo://two', attachmentsCheck: 'photo://two-check' }
  ]);
  assert.equal(f.host.isAddingImages, false);
});

test('picker or upload failures retain the exact original draft and allow an intentional retry', async () => {
  for (const setup of [
    f => { f.config.select = async () => { throw new Error('picker fixture failure'); }; },
    f => { f.config.select = async () => ({ photoUris: ['photo://one'] });
      f.config.upload = async () => ({ success: false, errorMessage: '图片过大，请缩小图片', attachment: { ...IMAGE } }); },
    f => { f.config.select = async () => ({ photoUris: ['photo://one'] });
      f.config.upload = async () => { throw new Error('upload fixture offline'); }; }
  ]) {
    const f = pageFixture();
    setup(f);
    await f.host.addImages();
    assert.equal(f.host.postContent, CONTENT);
    assert.deepEqual(clone(f.host.uploadedAttachments), []);
    assert.equal(f.host.isAddingImages, false);
    assert.equal(f.host.canEdit(), true);
    assert.ok(f.host.mediaMessage.length > 0);
    assert.equal(f.requests.length, 0, 'Failed image insertion cannot publish content');
  }
});

test('a partially failed selection keeps successful images and reports the failed image without duplicate insertion', async () => {
  const f = pageFixture();
  f.host.postContent = '正文';
  f.host.selectionStart = f.host.selectionEnd = -1;
  f.config.select = async () => ({ photoUris: ['photo://one', 'photo://two', 'photo://three'] });
  f.config.upload = async request => request.uri.endsWith('two') ?
    { success: false, errorMessage: '第二张图片过大', attachment: { ...IMAGE } } :
    { success: true, errorMessage: '', attachment: { ...IMAGE,
      url: 'mon_202610/07/' + (request.uri.endsWith('one') ? 'one' : 'three') + '.png' } };
  await f.host.addImages();
  assert.equal(f.uploads.length, 3);
  assert.equal(f.host.uploadedAttachments.length, 2);
  assert.equal(f.host.postContent,
    '正文[img]./mon_202610/07/one.png[/img]\n[img]./mon_202610/07/three.png[/img]\n');
  assert.match(f.host.mediaMessage, /2.*第二张图片过大/);
  assert.equal(f.host.isAddingImages, false);
  assert.equal(f.requests.length, 0);
});

test('leaving or switching accounts while choosing photos never starts an upload', async () => {
  for (const alter of [f => f.host.aboutToDisappear(), f => { f.config.account = 'account-b'; f.host.onPageShow(); }]) {
    const f = pageFixture(), selected = defer();
    f.config.select = () => selected.promise;
    const operation = f.host.addImages();
    alter(f);
    const afterChange = [f.host.postContent, clone(f.host.uploadedAttachments), f.host.mediaMessage];
    selected.resolve({ photoUris: ['photo://one'] });
    await operation;
    assert.equal(f.uploads.length, 0);
    assert.deepEqual([f.host.postContent, clone(f.host.uploadedAttachments), f.host.mediaMessage], afterChange);
  }
});

test('late uploaded images never enter a destroyed or different-account draft', async () => {
  for (const alter of [f => f.host.aboutToDisappear(), f => { f.config.account = 'account-b'; f.host.onPageShow(); }]) {
    const f = pageFixture(), uploaded = defer();
    f.config.select = async () => ({ photoUris: ['photo://one'] });
    f.config.upload = () => uploaded.promise;
    const operation = f.host.addImages();
    await settle();
    assert.equal(f.uploads.length, 1);
    assert.equal(f.uploads[0].isCurrent(), true);
    alter(f);
    const afterChange = [f.host.postContent, clone(f.host.uploadedAttachments), f.host.mediaMessage];
    assert.equal(f.uploads[0].isCurrent(), false);
    uploaded.resolve({ success: true, errorMessage: '', attachment: { ...IMAGE } });
    await operation;
    assert.deepEqual([f.host.postContent, clone(f.host.uploadedAttachments), f.host.mediaMessage], afterChange);
    assert.equal(f.savedDraft().content, CONTENT);
    assert.deepEqual(clone(f.savedDraft().attachments), []);
  }
});

test('pending image upload blocks duplicate selection, publish and back navigation until insertion completes', async () => {
  const f = pageFixture(), uploaded = defer();
  f.config.select = async () => ({ photoUris: ['photo://one'] });
  f.config.upload = () => uploaded.promise;
  const operation = f.host.addImages();
  await settle();
  assert.equal(f.host.isAddingImages, true);
  await f.host.addImages();
  await f.host.submitPost();
  await f.host.navigateBack();
  assert.equal(f.selections.length, 1);
  assert.equal(f.requests.length, 0);
  assert.equal(f.backs.length, 0);
  assert.equal(f.dialogs.length, 0);
  uploaded.resolve({ success: true, errorMessage: '', attachment: { ...IMAGE } });
  await operation;
  assert.equal(f.host.isAddingImages, false);
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
  assert.equal(f.host.submitSuccess, true);
});

test('image drafts restore attachment metadata with content and remain isolated from loaded arrays', async () => {
  const f = pageFixture({ action: 'reply', tid: 123456, pid: 789 });
  f.config.select = async () => ({ photoUris: ['photo://one'] });
  await f.host.addImages();
  f.host.saveDraft();
  const expectedContent = f.host.postContent;
  const reopened = f.reopen();
  assert.equal(reopened.postContent, expectedContent);
  assert.deepEqual(clone(reopened.uploadedAttachments), [IMAGE]);
  reopened.uploadedAttachments[0].attachmentsCheck = 'mutated page';
  assert.deepEqual(clone(f.savedDraft().attachments), [IMAGE]);
});

test('new topics and replies submit only remaining image metadata in the expected paired fields', async () => {
  for (const params of [{ action: 'new' }, { action: 'reply', tid: 123456, pid: 789 }]) {
    const f = pageFixture(params);
    f.host.uploadedAttachments = [{ ...IMAGE }, { ...IMAGE, url: 'mon_202610/07/deleted.png',
      attachments: 'deleted-id', attachmentsCheck: 'deleted-check' }];
    f.host.postContent = '正文[s:ng:doge]' + f.TopicAttachmentProtocol.buildMarkup(IMAGE);
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
    assert.equal(f.requests[1].fields.attachments, '\t' + IMAGE.attachments);
    assert.equal(f.requests[1].fields.attachments_check, '\t' + IMAGE.attachmentsCheck);
    assert.ok(!JSON.stringify(f.requests[1].fields).includes('deleted-id'));
    assert.equal(f.host.submitSuccess, true);
    assert.deepEqual(clone(f.host.uploadedAttachments), []);
    assert.deepEqual(clone(f.savedDraft().attachments), []);
  }
});

test('removing an uploaded image from the body leaves no attachment fields on the submitted form', async () => {
  const f = pageFixture();
  f.host.uploadedAttachments = [{ ...IMAGE }];
  f.host.postContent = '只保留文字';
  await f.host.submitPost();
  assert.equal(f.requests.length, 2);
  assert.equal(Object.hasOwn(f.requests[1].fields, 'attachments'), false);
  assert.equal(Object.hasOwn(f.requests[1].fields, 'attachments_check'), false);
});

test('editing an inserted image size or tag case keeps its paired metadata in the final submit', async () => {
  for (const content of [
    '[IMG]./' + IMAGE.url + '[/IMG]',
    '[img50]./' + IMAGE.url + '[/img]',
    '[img=100,200]./' + IMAGE.url + '[/img]',
    '[img]' + IMAGE.url + '[/img]',
    '[img]https://img.nga.cn/attachments/' + IMAGE.url + '[/img]',
    '[img]https://img8.nga.cn/attachments/' + IMAGE.url + '[/img]'
  ]) {
    const f = pageFixture();
    f.host.postContent = '正文' + content;
    f.host.uploadedAttachments = [{ ...IMAGE }];
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
    assert.equal(f.requests[1].fields.post_content, '正文' + content);
    assert.equal(f.requests[1].fields.attachments, '\t' + IMAGE.attachments);
    assert.equal(f.requests[1].fields.attachments_check, '\t' + IMAGE.attachmentsCheck);
    assert.equal(f.host.submitSuccess, true);
  }
});

test('an image kept only as BBCode in a code block contributes no attachment fields', async () => {
  for (const content of [
    '[code]' + '[img]./' + IMAGE.url + '[/img]' + '[/code]',
    '[CODE=bbcode]' + '[IMG50]./' + IMAGE.url + '[/IMG]' + '[/CODE]'
  ]) {
    const f = pageFixture({ action: 'reply', tid: 123456 });
    f.host.postContent = '代码示例：' + content;
    f.host.uploadedAttachments = [{ ...IMAGE }];
    await f.host.submitPost();
    assert.equal(f.requests.length, 2);
    assert.equal(f.requests[1].fields.post_content, '代码示例：' + content);
    assert.equal(Object.hasOwn(f.requests[1].fields, 'attachments'), false);
    assert.equal(Object.hasOwn(f.requests[1].fields, 'attachments_check'), false);
    assert.equal(f.host.submitSuccess, true);
  }
});

test('an uncertain submission preserves image metadata on reopen and blocks blind duplicate publication', async () => {
  const f = pageFixture();
  f.host.uploadedAttachments = [{ ...IMAGE }];
  f.host.postContent = '正文' + f.TopicAttachmentProtocol.buildMarkup(IMAGE);
  f.config.submit = async () => ({ success: true, statusCode: 200, body: '{}' });
  await f.host.submitPost();
  assert.equal(f.host.submitUncertain, true);
  assert.deepEqual(clone(f.savedDraft().attachments), [IMAGE]);
  const reopened = f.reopen();
  assert.deepEqual(clone(reopened.uploadedAttachments), [IMAGE]);
  assert.equal(reopened.postContent, f.host.postContent);
  await reopened.submitPost();
  assert.equal(f.requests.length, 2);
});

test('uploaded image preview maps its confirmed attachment URL without changing forum markup or receipts', async () => {
  const f = pageFixture();
  f.host.selectionStart = f.host.selectionEnd = CONTENT.length;
  f.config.select = async () => ({ photoUris: ['photo://one'] });
  f.config.upload = async () => ({ success: true, errorMessage: '', attachment: { ...IMAGE },
    previewSource: IMAGE_PREVIEW });
  await f.host.addImages();
  assert.deepEqual(clone(f.host.imagePreviews), { [IMAGE_PREVIEW_URL]: IMAGE_PREVIEW });
  assert.equal(f.host.postContent, CONTENT + '[img]./' + IMAGE.url + '[/img]\n');
  assert.deepEqual(clone(f.host.uploadedAttachments), [IMAGE]);
  assert.ok(!JSON.stringify(f.host.uploadedAttachments).includes('data:image'));
  assert.equal(f.host.isAddingImages, false);
});

test('preview cache rejects unsafe data sources and invalid attachment receipts', () => {
  const f = pageFixture();
  for (const source of [undefined, null, {}, '', 'https://image.invalid/example.png',
    'file://local/image.png', 'javascript:alert(1)', 'data:text/html;base64,PHNjcmlwdD4=',
    'data:image/svg+xml;base64,PHN2Zz4=', 'data:image/gif;base64,R0lGODlh',
    'data:image/png;base64,', 'data:image/png;base64,not-base64!',
    'data:image/png;base64,=', 'data:image/png;base64,AAA', 'data:image/png;base64,AA=',
    'data:image/png;base64,A===', 'data:image/png;base64,AAA=extra',
    'data:image/png;base64,AAA\nA', 'data:image/png;base64,' + 'A'.repeat(256 * 1024)]) {
    f.host.rememberImagePreview(IMAGE, source);
    assert.deepEqual(clone(f.host.imagePreviews), {});
  }
  for (const attachment of [{ ...IMAGE, url: 'https://other.invalid/image.png' },
    { ...IMAGE, attachmentsCheck: '' }, { ...IMAGE, url: 'mon_202610/07/../image.png' }]) {
    f.host.rememberImagePreview(attachment, IMAGE_PREVIEW);
    assert.deepEqual(clone(f.host.imagePreviews), {});
  }
  f.host.rememberImagePreview(IMAGE, IMAGE_PREVIEW);
  const jpeg = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2Q==';
  f.host.rememberImagePreview({ ...IMAGE, url: 'mon_202610/07/fixture.jpg' }, jpeg);
  assert.equal(Object.keys(f.host.imagePreviews).length, 2);
  assert.equal(f.host.imagePreviews[IMAGE_PREVIEW_URL], IMAGE_PREVIEW);
  assert.equal(f.host.imagePreviews['https://img.nga.cn/attachments/mon_202610/07/fixture.jpg'], jpeg);
});

test('preview cache keeps only twelve images and replacing a URL updates its recency without duplication', () => {
  const f = pageFixture();
  const url = index => 'https://img.nga.cn/attachments/mon_202610/07/preview_' + index + '.png';
  const attachment = index => ({ ...IMAGE, url: 'mon_202610/07/preview_' + index + '.png' });
  for (let index = 0; index < 14; index++) f.host.rememberImagePreview(attachment(index), IMAGE_PREVIEW);
  assert.deepEqual(Object.keys(f.host.imagePreviews), Array.from({ length: 12 }, (_, index) => url(index + 2)));
  const replacement = 'data:image/png;base64,QUJD';
  f.host.rememberImagePreview(attachment(2), replacement);
  assert.equal(Object.keys(f.host.imagePreviews).length, 12);
  assert.equal(Object.keys(f.host.imagePreviews).at(-1), url(2));
  f.host.rememberImagePreview(attachment(14), IMAGE_PREVIEW);
  assert.equal(Object.keys(f.host.imagePreviews).length, 12);
  assert.equal(Object.hasOwn(f.host.imagePreviews, url(3)), false);
  assert.equal(f.host.imagePreviews[url(2)], replacement);
});

test('local previews never enter drafts, upload inputs or submitted forum fields and clear after success', async () => {
  const f = pageFixture();
  f.config.select = async () => ({ photoUris: ['photo://one'] });
  f.config.upload = async () => ({ success: true, errorMessage: '', attachment: { ...IMAGE },
    previewSource: IMAGE_PREVIEW });
  await f.host.addImages();
  f.host.saveDraft();
  assert.ok(!JSON.stringify(f.savedDraft()).includes('data:image'));
  assert.equal(Object.hasOwn(f.savedDraft(), 'imagePreviews'), false);
  assert.ok(!JSON.stringify(f.uploads[0].input).includes('data:image'));
  assert.equal(Object.hasOwn(f.uploads[0].input, 'imagePreviews'), false);
  await f.host.submitPost();
  assert.equal(f.host.submitSuccess, true);
  assert.equal(f.requests.length, 2);
  assert.ok(!JSON.stringify(f.requests).includes('data:image'));
  assert.ok(f.requests.every(request => !Object.hasOwn(request.fields, 'imagePreviews')));
  assert.deepEqual(clone(f.host.imagePreviews), {});
});

test('leaving the composer clears local previews while preserving the text and receipt draft', () => {
  const f = pageFixture();
  f.host.uploadedAttachments = [{ ...IMAGE }];
  f.host.postContent = CONTENT + '[img]./' + IMAGE.url + '[/img]';
  f.host.rememberImagePreview(IMAGE, IMAGE_PREVIEW);
  const expectedContent = f.host.postContent;
  f.host.aboutToDisappear();
  assert.deepEqual(clone(f.host.imagePreviews), {});
  assert.equal(f.savedDraft().content, expectedContent);
  assert.deepEqual(clone(f.savedDraft().attachments), [IMAGE]);
  assert.ok(!JSON.stringify(f.savedDraft()).includes('data:image'));
  const reopened = f.reopen();
  assert.equal(reopened.postContent, expectedContent);
  assert.deepEqual(clone(reopened.uploadedAttachments), [IMAGE]);
  assert.deepEqual(clone(reopened.imagePreviews), {});
});

test('account changes and sign-out clear previews and cannot accept a late upload preview', async () => {
  for (const invalidate of [f => { f.config.account = 'account-b'; f.host.onPageShow(); },
    f => { f.config.loggedIn = false; f.host.onPageShow(); }, f => f.host.aboutToDisappear()]) {
    const f = pageFixture();
    f.host.rememberImagePreview(IMAGE, IMAGE_PREVIEW);
    f.config.select = async () => ({ photoUris: ['photo://one'] });
    const upload = defer(); f.config.upload = () => upload.promise;
    const operation = f.host.addImages(); await settle();
    assert.equal(f.uploads.length, 1);
    invalidate(f);
    assert.deepEqual(clone(f.host.imagePreviews), {});
    upload.resolve({ success: true, errorMessage: '', attachment: { ...IMAGE }, previewSource: IMAGE_PREVIEW });
    await operation;
    assert.deepEqual(clone(f.host.imagePreviews), {});
    assert.equal(f.host.uploadedAttachments.length, 0);
    assert.equal(f.requests.length, 0);
  }
});
