const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

// Existing host regressions model the public sideload build, whose invite-only
// consent flag is disabled. Invite tests pass explicit, stateful consent mocks.
function publicConsentModule(name) {
  if(name.endsWith('/DownloadProxyPreferences'))return{DownloadProxyPreferences:{load:async()=>({enabled:false,protocol:'http',host:'',port:0})}};
  if(name.endsWith('/StoreBuildConfig'))return{StoreBuildConfig:{configured:true,baseUrl:'https://store.example.invalid',publicKeySha256:'a'.repeat(43)+'=',caData:''}};
  if(name.endsWith('/ApplicationIcons'))return{applicationIcons:()=>({stats:()=>({bytes:0}),size:async()=>0,clear:async()=>{}})};
  if(name.endsWith('/SelfInstallRecovery'))return loadEts('jobs/SelfInstallRecovery', {
    './InstallJob':loadEts('jobs/InstallJob'), './LocalBundles':{LocalBundles:{selfInstalledIdentity:()=>undefined}},
    './JobScheduler':{JobScheduler:{isRunning:()=>false}}
  });
  if(name.endsWith('/DeviceNetwork'))return{DeviceNetwork:{available:true,ready:true,signature:'wifi-1',start:async()=>true,refresh:async()=>true,subscribe:()=>1,unsubscribe(){}}};
  if(name.endsWith('/InstallPreflight'))return loadEts('jobs/InstallPreflight',{
    './InstallJob':loadEts('jobs/InstallJob'),
    './ReleaseUpdate':loadEts('jobs/ReleaseUpdate',{
      '../data/DisplayVersion':loadEts('data/DisplayVersion'),'../data/ReleaseInfo':loadEts('data/ReleaseInfo'),'./InstallJob':loadEts('jobs/InstallJob')
    })
  });
  if (name.endsWith('/DeviceInstallTarget')) return loadEts('jobs/DeviceInstallTarget');
  if (name.endsWith('/DeviceInstallGroup')) return loadEts('jobs/DeviceInstallGroup',{'./InstallJob':loadEts('jobs/InstallJob')});
  if (name.endsWith('/DeviceOrbHost')) return {DeviceOrbHost:{install(){},dispose(){},attached:()=>true}};
  if (name.endsWith('/DeviceOrbNavigation')) return loadEts('jobs/DeviceOrbNavigation');
  if (name.endsWith('/PrivacyConsent')) return { PrivacyConsent: {
    isManaged: () => false, isBusinessAllowed: () => true, assertBusinessAllowed: () => {},
    refresh: () => true, configure: () => {}, subscribe: () => 1, unsubscribe: () => {},
    lastError: () => '', links: () => [], ensureConsent: async () => true, withdraw: () => {}
  } };
  if (name.endsWith('/CloudBackupConsent')) return { CloudBackupConsent: {
    selected: async () => true, allowed: async () => true, isAllowedNow: () => true,
    setEnabled: async () => {}
  } };
  if (name.endsWith('/I18n')) return { I18n: { t: (value) => value, language: () => 'zh', setLanguage: () => {} } };
  if (name.endsWith('/AppLanguagePreferences')) return { AppLanguagePreferences: {
    current: () => 'zh', normalize: (value) => value, systemDefault: () => 'zh',
    load: async () => {}, save: async () => {}
  } };
  return {};
}

/** Load production logic, with explicit platform mocks supplied by its test. */
function loadEts(file, mocks = {}, globals = {}) {
  const exports = {};
  const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets', file + '.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS
  } }).outputText, { exports, require: name => mocks[name] || publicConsentModule(name), console, ...globals });
  return exports;
}
module.exports = { loadEts, publicConsentModule };
