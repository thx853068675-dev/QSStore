const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.join(__dirname, '../entry/src/main/ets');

function load(file, mocks = {}, globals = {}) {
  const exports = {};
  vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root, file + '.ets'), 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText, { exports, require: name => mocks[name] || {}, ...globals });
  return exports;
}

const i18n = load('data/I18n').I18n;

function languageFixture(systemLanguage = 'zh-Hans') {
  const disk = new Map(), storage = new Map();
  const { AppLanguagePreferences } = load('data/AppLanguagePreferences', {
    '@kit.AbilityKit': { common: {} },
    '@kit.ArkData': { preferences: { getPreferences: async () => ({
      get: async (key, fallback) => disk.has(key) ? disk.get(key) : fallback,
      put: async (key, value) => disk.set(key, value),
      flush: async () => {}
    }) } },
    '@kit.LocalizationKit': { i18n: { System: { getSystemLanguage: () => systemLanguage } } },
    './I18n': { I18n: i18n }
  }, {
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value) },
    I18n: i18n
  });
  return { AppLanguagePreferences, disk, storage };
}

test('Chinese is the untouched default and unknown keys fall back to their source', () => {
  i18n.setLanguage('zh');
  assert.equal(i18n.language(), 'zh');
  assert.equal(i18n.t('设置'), '设置');
  assert.equal(i18n.t('not-a-real-key'), 'not-a-real-key');
});

test('English switches common settings, actions and server categories', () => {
  i18n.setLanguage('en');
  assert.equal(i18n.language(), 'en');
  assert.equal(i18n.t('设置'), 'Settings');
  assert.equal(i18n.t('安装'), 'Install');
  assert.equal(i18n.t('Discover'), 'Discover');
  assert.equal(i18n.category('影音'), 'Media');
  assert.equal(i18n.category('未知分类'), '未知分类');
  assert.equal(i18n.sortLabel('new'), 'Newest');
  assert.equal(i18n.sortLabel('downloads'), 'Downloads');
  assert.equal(i18n.sortLabel('stars'), 'Stars');
  assert.equal(i18n.t('已读取 HAP'), 'HAP loaded');
  assert.equal(i18n.t('已读取 HAP，等待开始'), 'HAP loaded. Waiting to start');
  assert.equal(i18n.t('失败'), 'Failed');
  assert.equal(i18n.t('安装失败'), 'Install failed');
  assert.equal(i18n.t('续签中'), 'Renewing');
  i18n.setLanguage('zh');
});

test('every I18n.t literal used by production UI has an English entry', () => {
  const map = new Map();
  const source = fs.readFileSync(path.join(root, 'data/I18n.ets'), 'utf8');
  for (const match of source.matchAll(/ENGLISH\.set\(("(?:[^"\\]|\\.)*"),/g)) {
    map.set(JSON.parse(match[1]), true);
  }
  const missing = new Set();
  for (const file of fs.readdirSync(root, { recursive: true })) {
    if (!String(file).endsWith('.ets') || String(file) === 'data/I18n.ets') continue;
    const body = fs.readFileSync(path.join(root, String(file)), 'utf8');
    for (const match of body.matchAll(/I18n\.t\('((?:[^'\\]|\\.)*)'\)/g)) {
      const key = eval("'" + match[1] + "'");
      if (key === '中文原文') continue;
      if (!map.has(key)) missing.add(key + ' @ ' + file);
    }
  }
  assert.deepEqual([...missing], []);
});

test('first launch follows the system language, then saves and reloads the choice', async () => {
  const en = languageFixture('en-US');
  await en.AppLanguagePreferences.load({});
  assert.equal(en.AppLanguagePreferences.current(), 'en');
  assert.equal(en.storage.get('appLanguage'), 'en');

  const zh = languageFixture('zh-Hans');
  await zh.AppLanguagePreferences.load({});
  assert.equal(zh.AppLanguagePreferences.current(), 'zh');
  await zh.AppLanguagePreferences.save({}, 'en');
  assert.equal(zh.disk.get('appLanguage'), 'en');
  assert.equal(zh.storage.get('appLanguage'), 'en');
  assert.equal(zh.AppLanguagePreferences.current(), 'en');

  const reopened = languageFixture('zh-Hans');
  reopened.disk.set('appLanguage', 'en');
  await reopened.AppLanguagePreferences.load({});
  assert.equal(reopened.AppLanguagePreferences.current(), 'en');
  i18n.setLanguage('zh');
});
