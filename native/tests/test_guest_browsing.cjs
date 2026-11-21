const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const source = fs.readFileSync(__dirname + '/../entry/src/main/ets/pages/Index.ets', 'utf8');

test('homepage navigation depends on startup and privacy, independently of the developer session', () => {
  const start = source.match(/if \(this\.privacyAllowed\) \{\s*if \(([^)]+)\) \{\s*this\.navigationPages\(\);\s*this\.bottomDock\(\);/);
  assert.ok(start, 'homepage navigation is rendered under the privacy gate');
  const canBrowse = vm.runInNewContext('(function () { return this.privacyAllowed && (' + start[1] + '); })');
  const guest = { privacyAllowed: true, shellReady: true, signedIn: false, accountChecked: false };
  assert.equal(canBrowse.call(guest), true);
  assert.equal(canBrowse.call({ ...guest, accountChecked: true }), true);
  assert.equal(canBrowse.call({ ...guest, privacyAllowed: false }), false);
  assert.equal(canBrowse.call({ ...guest, shellReady: false }), false);
  assert.doesNotMatch(source, /this\.loginGate\(|GuestBrowsing/);
});
