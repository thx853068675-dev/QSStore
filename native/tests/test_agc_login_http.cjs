const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.QINGQI_TYPESCRIPT ||
  '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function load(name, http, accountService = {}) {
  const file = path.join(__dirname, '../entry/src/main/ets/data', name + '.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, require: id => id === '@kit.NetworkKit' ? { http } : id === './AccountService' ? { AccountService: accountService } : {} });
  return exports[name];
}

function transport(result) {
  const calls = [];
  const http = {
    RequestMethod: { GET: 'GET', POST: 'POST', DELETE: 'DELETE' },
    createHttp: () => ({
      request: async (url, options) => {
        calls.push({ url, options });
        return { responseCode: 200, result: JSON.stringify(result) };
      },
      destroy: () => {}
    })
  };
  return { calls, http };
}

test('an empty AGC certificate list is a valid bodyless GET', async () => {
  const t = transport({ ret: { code: 0 }, certList: [] });
  const Client = load('AgcClient', t.http);
  const list = await new Client({ accessToken: 'token', teamId: 'team', userId: 'user' })
    .certificates();
  assert.equal(list.length, 0);
  assert.equal(t.calls[0].options.method, 'GET');
  assert.equal(t.calls[0].options.extraData, undefined);
});

test('AGC certificate creation keeps its JSON body', async () => {
  const t = transport({ ret: { code: 0 }, harmonyCert: { id: '42' } });
  const Client = load('AgcClient', t.http);
  await new Client({ accessToken: 'token', teamId: 'team', userId: 'user' })
    .createCertificate('-----BEGIN CERTIFICATE REQUEST-----\nfixture', 'test');
  assert.equal(t.calls[0].options.method, 'POST');
  assert.equal(JSON.parse(t.calls[0].options.extraData).certType, 1);
});

test('first login GET does not send empty extraData', async () => {
  const t = transport({ userInfo: { accessToken: 'a', userId: 'u' } });
  const Login = load('DevEcoLogin', t.http);
  await Login.requestJson('https://example.invalid/login', 'GET');
  assert.equal(t.calls[0].options.extraData, undefined);
});

test('public profile POST retains its form body', async () => {
  const t = transport({});
  const Login = load('DevEcoLogin', t.http);
  await Login.requestJson('https://example.invalid/profile', 'POST',
    { 'Content-Type': 'application/x-www-form-urlencoded' }, 'access_token=x');
  assert.equal(t.calls[0].options.extraData, 'access_token=x');
});

test('temporary Profile creation retains real cloud IDs in the supported response shapes', async () => {
  for (const result of [
    { id: '2053018577916713856', provisionFileUrl: 'https://agc.example/profile' },
    { provisionInfo: { id: '42', provisionFileUrl: 'https://agc.example/profile' } },
    { provisionInfo: { id: '', provisionFileUrl: '' }, provisionId: '43', provisionFileUrl: 'https://agc.example/profile' }
  ]) {
    const t = transport(result), Client = load('AgcClient', t.http);
    const profile = await new Client({}).createProfile('name', 'cert', ['device'], [], 'com.example.app');
    assert.ok(profile.id.length > 0); assert.equal(profile.downloadUrl, 'https://agc.example/profile');
    assert.match(t.calls[0].url, /ide\/test\/provision\/add$/);
  }
});
test('a basic IDE Profile with no cloud receipt remains usable without fabricating a deletion ID', async () => {
  for (const result of [
    { provisionFileUrl: 'https://agc.example/profile' },
    { provisionInfo: { provisionFileUrl: 'https://agc.example/profile' } },
    { ret: { code: 0, downloadUrl: 'https://agc.example/profile' } },
    { id: 'bad?query', provisionFileUrl: 'https://agc.example/profile' },
    { id: 2053018577916713856, provisionFileUrl: 'https://agc.example/profile' }
  ]) {
    const t = transport(result), Client = load('AgcClient', t.http);
    const created = await new Client({}).createProfile('name','cert',[],[],'com.example.app');
    assert.equal(created.id, ''); assert.equal(created.downloadUrl, 'https://agc.example/profile');
    assert.equal(t.calls.length, 1, 'successful creation must not be retried');
  }
  for (const result of [{ ret: { code: 0, id: '42', downloadUrl: 'https://agc.example/profile' } },
    { provisionInfo: { provisionId: '42', provisionFileUrl: 'https://agc.example/profile' } }]) {
    const t = transport(result), Client = load('AgcClient', t.http);
    assert.equal((await new Client({}).createProfile('name','cert',[],[],'com.example.app')).id, '42');
  }
  const t = transport({id:'42'}), Client = load('AgcClient', t.http);
  const created = await new Client({}).createProfile('name','cert',[],[],'com.example.app');
  assert.equal(created.id,'42'); assert.equal(created.downloadUrl,'');
});
test('temporary Profile deletion is a bodyless DELETE and rejects CMS UUIDs and malformed IDs', async () => {
  const t=transport({ret:{code:0}}),Client=load('AgcClient',t.http),client=new Client({});
  await client.deleteProfile('42');assert.match(t.calls[0].url,/\/provision\/delete\?id=42$/);
  assert.equal(t.calls[0].options.method,'DELETE');assert.equal(t.calls[0].options.extraData,undefined);
  for(const id of ['', 'e446cca6-7461-4736-8014-2baf8e2c6852','42&other=true'])await assert.rejects(()=>client.deleteProfile(id));
  assert.equal(t.calls.length,1);
});

test('ordinary Profile creation uses the registered app ID header and is separate from temporary creation', async () => {
  const t=transport({ret:{code:0}}),Client=load('AgcClient',t.http),client=new Client({});
  await client.createManagedProfile('managed','123','77',['device'],['ohos.permission.SYSTEM_FLOAT_WINDOW']);
  const call=t.calls[0],body=JSON.parse(call.options.extraData);
  assert.match(call.url,/\/provision\/add$/);assert.doesNotMatch(call.url,/ide\/test/);
  assert.equal(call.options.header.appId,'123');assert.equal(body.appId,'123');
  assert.equal(body.provisionType,1);assert.deepEqual(body.aclPermissionList,['ohos.permission.SYSTEM_FLOAT_WINDOW']);
});
test('app and signing-project registration preserve official DevEco form encoding', async () => {
  const t=transport({ret:{code:0},appId:'123',mapping:{projectId:'99'}}),Client=load('AgcClient',t.http),client=new Client({userId:'42',teamId:'99'});
  assert.equal(await client.createSigningProject(),'99');
  assert.equal(await client.createSigningApp('99','com.example.app'),'123');
  for(const call of t.calls){assert.equal(call.options.header['Content-Type'],'application/x-www-form-urlencoded');assert.equal(call.options.method,'POST');}
  const form=new URLSearchParams(t.calls[1].options.extraData);
  assert.equal(form.get('parentType'),'13');assert.equal(form.get('installationFree'),'0');assert.equal(form.get('projectId'),'99');assert.equal(form.get('packageName'),'com.example.app');
});
test('ordinary Profile query passes the app ID and keeps the request bodyless',async()=>{
 const t=transport({ret:{code:0},list:[]}),Client=load('AgcClient',t.http);
 await new Client({}).managedProfiles('123');assert.equal(t.calls[0].options.header.appId,'123');assert.equal(t.calls[0].options.extraData,undefined);
});

test('401 refresh retains an ordinary app header and form POST without duplicating successful creation', async () => {
  for (const form of [false,true]) {
    const calls=[],account={accessToken:'expired',teamId:'99',userId:'42'};
    const http={RequestMethod:{GET:'GET',POST:'POST'},createHttp:()=>({request:async(url,options)=>{calls.push({url,options});return calls.length===1?{responseCode:401,result:''}:{responseCode:200,result:JSON.stringify({ret:{code:0},appId:'123'})};},destroy:()=>{}})};
    const Client=load('AgcClient',http,{refresh:async(a)=>{a.accessToken='fresh';}}),client=new Client(account);
    if(form)await client.createSigningApp('99','com.example.app');else await client.createManagedProfile('managed','123','77',['device'],[]);
    assert.equal(calls.length,2);assert.equal(calls[1].options.header.oauth2Token,'fresh');assert.equal(calls[1].options.extraData,calls[0].options.extraData);
    assert.equal(calls[1].options.header['Content-Type'],form?'application/x-www-form-urlencoded':'application/json');
    if(!form)assert.equal(calls[1].options.header.appId,'123');
  }
});
