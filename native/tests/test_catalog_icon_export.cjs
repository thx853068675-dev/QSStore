const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');
const { loadEts } = require('./load_ets.cjs');

function fixture(t, bytes) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'catalog-icon-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const f = { target: path.join(dir, 'saved'), selected: true, reads: 0, picks: 0, opens: 0, closes: 0,
    maxWrite: 7, fail: false, names: [] };
  const { CatalogIconExport } = loadEts('jobs/CatalogIconExport', {
    '../data/StoreClient': { StoreClient: class { async originalIconBytes() { f.reads++; return bytes; } } },
    '@kit.CoreFileKit': { picker: { DocumentViewPicker: class { async save(options) {
      f.picks++; f.names = options.newFileNames; return f.selected ? [f.target] : [];
    } } }, fileIo: {
      OpenMode: { WRITE_ONLY: 1, TRUNC: 2 },
      async open() { f.opens++; return { fd: fs.openSync(f.target, 'w') }; },
      async write(fd, data) { if (f.fail) throw Error('disk full'); return fs.writeSync(fd, Buffer.from(data).subarray(0, f.maxWrite)); },
      async fsync(fd) { fs.fsyncSync(fd); }, async stat(fd) { return fs.fstatSync(fd); },
      async close(file) { f.closes++; fs.closeSync(file.fd); }
    } }
  }, { ArrayBuffer, Uint8Array });
  f.save = (current = () => true, title = '../应用:图标') => CatalogIconExport.save({}, {}, title, current);
  return f;
}
const buffer = value => Uint8Array.from(value).buffer;

test('PNG, JPEG and WebP exports retain every source byte and use the actual format', async t => {
  const images = [
    ['png', [137,80,78,71,13,10,26,10]], ['jpg', [255,216,255,224]],
    ['webp', [82,73,70,70,24,0,0,0,87,69,66,80]]
  ];
  for (const [extension, signature] of images) {
    const source = buffer([...signature, ...Array.from({ length: 40 }, (_, i) => i)]), f = fixture(t, source);
    assert.equal(await f.save(), true);
    assert.deepEqual(fs.readFileSync(f.target), Buffer.from(source));
    assert.equal(path.extname(f.names[0]), '.' + extension);
    assert(!/[\\/:]/.test(f.names[0])); assert.equal(f.opens, 1); assert.equal(f.closes, 1);
  }
});

test('missing, invalid and oversized responses cannot create an exported image', async t => {
  for (const source of [undefined, buffer([60,104,116,109,108,62]), new ArrayBuffer(1048577)]) {
    const f = fixture(t, source);
    await assert.rejects(f.save()); assert.equal(f.picks, 0); assert.equal(f.opens, 0);
  }
});

test('canceling or leaving the detail page does not write a file', async t => {
  const f = fixture(t, buffer([255,216,255])); f.selected = false;
  assert.equal(await f.save(), false); assert.equal(f.opens, 0);
  const left = fixture(t, buffer([255,216,255]));
  assert.equal(await left.save(() => false), false); assert.equal(left.picks, 0);
  let checks = 0;
  assert.equal(await left.save(() => ++checks === 1), false); assert.equal(left.opens, 0);
});

test('a write failure closes the destination and does not report success', async t => {
  const f = fixture(t, buffer([255,216,255])); f.fail = true;
  await assert.rejects(f.save(), /disk full/); assert.equal(f.closes, 1);
  f.fail = false; f.maxWrite = 0;
  await assert.rejects(f.save(), /保存不完整/); assert.equal(f.closes, 2);
});
