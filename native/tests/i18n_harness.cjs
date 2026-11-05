/*
 * Localization test harness.
 *
 * Production templates now call I18n.t(...) directly. The legacy host tests
 * evaluate production modules in vm contexts with hand-written require maps,
 * so they need a deterministic `zh` stub. Keeping the stub here avoids
 * sprinkling I18n mocks through every regression file.
 *
 * Enable with:
 *   NODE_OPTIONS=--require=./native/tests/i18n_harness.cjs node --test native/tests/test_*.cjs
 */
const vm = require('node:vm');

const I18n = {
  I18n: {
    t: (value) => value,
    category: (value) => value,
    language: () => 'zh',
    setLanguage: () => {}
  }
};
const AppLanguagePreferences = {
  AppLanguagePreferences: {
    current: () => 'zh',
    normalize: (value) => value,
    systemDefault: () => 'zh',
    load: async () => {},
    save: async () => {}
  }
};
const UpdatePushSync = {
  UpdatePushSync: {
    observeCatalog: () => {},
    schedule: () => {},
    sync: async () => {},
    syncBestEffort: async () => {},
    clientId: async () => ''
  }
};

function localizationModule(name) {
  if (name === './I18n' || name.endsWith('/I18n')) return I18n;
  if (name === './AppLanguagePreferences' || name.endsWith('/AppLanguagePreferences')) {
    return AppLanguagePreferences;
  }
  if (name === './UpdatePushSync' || name.endsWith('/UpdatePushSync')) return UpdatePushSync;
  return undefined;
}

const PRELUDE_LINES = [
  ['I18n', 'var I18n = (typeof globalThis.I18n !== "undefined") ? globalThis.I18n : ' +
    '{ t: (value) => value, category: (value) => value, language: () => "zh", setLanguage: () => {} };'],
  ['AppLanguagePreferences', 'var AppLanguagePreferences = (typeof globalThis.AppLanguagePreferences !== "undefined") ? ' +
    'globalThis.AppLanguagePreferences : { current: () => "zh", normalize: (value) => value, ' +
    'systemDefault: () => "zh", load: async () => {}, save: async () => {} };'],
  ['UpdatePushSync', 'var UpdatePushSync = (typeof globalThis.UpdatePushSync !== "undefined") ? globalThis.UpdatePushSync : ' +
    '{ observeCatalog: () => {}, schedule: () => {}, sync: async () => {}, syncBestEffort: async () => {}, clientId: async () => "" };']
];

function preludeFor(code) {
  // Loading the real implementation must not be redeclared by the fallback.
  return PRELUDE_LINES
    .filter(([name]) => !new RegExp('(?:class|const|let|var)\\s+' + name + '\\b').test(code))
    .map(([, line]) => line)
    .join('\n') + '\n';
}

function wrapContext(context) {
  if (context === null || typeof context !== 'object') return { context, restore: () => {} };
  const hadRequire = Object.prototype.hasOwnProperty.call(context, 'require');
  const original = context.require;
  context.require = (name) => {
    const stub = localizationModule(name);
    if (stub !== undefined) {
      if (typeof original === 'function') {
        try {
          const value = original(name);
          if (value && (value.I18n || value.AppLanguagePreferences || value.UpdatePushSync)) {
            return value;
          }
        } catch (_) { /* fall through to the stub */ }
      }
      return stub;
    }
    if (typeof original !== 'function') return {};
    return original(name);
  };
  return {
    context,
    restore: () => {
      if (hadRequire) context.require = original;
      else delete context.require;
    }
  };
}

const runInNewContext = vm.runInNewContext;
vm.runInNewContext = function (code, context, options) {
  const wrapped = wrapContext(context);
  try {
    return runInNewContext.call(vm, preludeFor(code) + code, wrapped.context, options);
  } finally {
    wrapped.restore();
  }
};

const runInContext = vm.runInContext;
if (typeof runInContext === 'function') {
  vm.runInContext = function (code, context, options) {
    return runInContext.call(vm, preludeFor(code) + code, context, options);
  };
}
