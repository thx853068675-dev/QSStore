const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');
const { ApplicationIconQueue } = loadEts('data/ApplicationIconQueue');
const turn = () => new Promise(resolve => setImmediate(resolve));

test('a slow icon cannot hold the other visible icons; concurrency stays at four', async () => {
  const queue = new ApplicationIconQueue(), started = [], gates = [];
  let active = 0, peak = 0;
  const tasks = Array.from({ length: 8 }, (_, i) => queue.submit(() => {
    started.push(i); peak = Math.max(peak, ++active);
    return new Promise(resolve => { gates[i] = () => { active--; resolve(String(i)); }; });
  }));
  await turn(); assert.deepEqual(started, [0,1,2,3]);
  for (const i of [1,2,3,4,5,6,7]) { gates[i](); await turn(); }
  assert.equal(started.length, 8); assert.equal(peak, 4);
  gates[0](); assert.deepEqual(await Promise.all(tasks), ['0','1','2','3','4','5','6','7']);
});

test('failed icon reads free their worker and do not poison later requests', async () => {
  const queue = new ApplicationIconQueue();
  const results = await Promise.allSettled(Array.from({ length: 12 }, (_, i) =>
    queue.submit(async () => { if (i < 4) throw new Error('offline'); return String(i); })));
  assert.equal(results.filter(r => r.status === 'rejected').length, 4);
  assert.equal(results[11].value, '11');
});

function repository() {
  const calls = [], gates = [], files = new Map(), opened = new Map(); let fd = 0;
  const fs = {
    statSync: p => { if (!files.has(p)) throw new Error('missing'); return { size: String(files.get(p)).length, mtime:0 }; },
    accessSync: p => files.has(p), mkdirSync: p => files.set(p, ''),
    readTextSync: p => files.get(p), listFileSync: () => [],
    openSync: p => { opened.set(++fd,p); return { fd }; },
    writeSync: (id, data) => { files.set(opened.get(id),data); return data.length; },
    closeSync: () => {}, fsyncSync: () => {}, renameSync: (a,b) => { files.set(b,files.get(a)); files.delete(a); },
    unlinkSync: p => files.delete(p), OpenMode:{ CREATE:1, WRITE_ONLY:2, TRUNC:4 }
  };
  const http = { RequestMethod:{ POST:'POST' }, HttpDataType:{ STRING:'string' }, createHttp: () => ({
    request: (_url, options) => { calls.push(JSON.parse(options.extraData).pkgName);
      return new Promise(resolve => gates.push(() => resolve({ responseCode:200, result:'{}' }))); }, destroy: () => {}
  }) };
  const { ApplicationIconRepository } = loadEts('data/ApplicationIcons', {
    '@kit.NetworkKit':{http}, '@kit.CoreFileKit':{fileIo:fs,fileUri:{getUriFromPath:p=>'file://'+p}},
    '@kit.ArkTS':{util:{generateRandomUUID:()=> 'abc'}},
    './ApplicationIconQueue':{ApplicationIconQueue}
  });
  return { repo:new ApplicationIconRepository('/cache'), calls, gates, files };
}
test('duplicate requests share work, offscreen rows skip the network, and clearing rejects late cache writes', async () => {
  const { repo,calls,gates,files } = repository();
  const names = Array.from({length:5}, (_,i) => 'com.example.app'+i);
  const tasks = names.slice(0,4).map(n => repo.load(n));
  assert.equal(repo.load(names[0]), tasks[0]);
  let visible = true; tasks.push(repo.load(names[4],()=>visible)); visible = false;
  await turn(); assert.equal(calls.length,4);
  repo.clear(); gates.forEach(resolve=>resolve()); await Promise.all(tasks);
  assert.equal(calls.length,4); assert.equal([...files.keys()].filter(p=>p.endsWith('.json')).length,0);
  files.set('/cache/application-icons/com.example.cached.png','image');
  assert.equal(repo.cached('com.example.cached'),'file:///cache/application-icons/com.example.cached.png');
});
