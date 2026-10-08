const { test } = require('node:test');
const { execFileSync } = require('node:child_process');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path');

test('native opening cadence expires, extends safely, cancels on background and tolerates API failures', () => {
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'qingqi-pacing-'));
  try {
    const output = path.join(temp, 'pacing');
    execFileSync(process.env.CXX || 'c++', ['-std=c++17', '-pthread',
      '-I' + path.join(__dirname, 'native_stubs'),
      path.join(__dirname, '../entry/src/main/cpp/hap_core/resume_pacing.cpp'),
      path.join(__dirname, 'resume_pacing_test.cpp'), '-o', output], { timeout: 30000 });
    execFileSync(output, [], { timeout: 6000 });
  } finally { fs.rmSync(temp, { recursive: true, force: true }); }
});
