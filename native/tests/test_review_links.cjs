const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

const { reviewTextRuns } = loadEts('data/ReviewLinks', { '@kit.ArkTS': { url: { URL } } });

function recognized(text) {
  const runs = reviewTextRuns(text);
  assert.equal(runs.map(run => run.text).join(''), text);
  return Array.from(runs.filter(run => run.uri), run => [run.text, run.uri]);
}

test('web links preserve queries, fragments, surrounding punctuation and line breaks', () => {
  assert.deepEqual(recognized('详情:https://example.com/?q=a%20b&x=1#top。\n另见（http://example.org:8080/）'), [
    ['https://example.com/?q=a%20b&x=1#top', 'https://example.com/?q=a%20b&x=1#top'],
    ['http://example.org:8080/', 'http://example.org:8080/']
  ]);
});

test('balanced path delimiters are retained and www uses HTTPS', () => {
  assert.deepEqual(recognized('([详情](https://example.com/wiki/Name_(test))). www.example.com'), [
    ['https://example.com/wiki/Name_(test)', 'https://example.com/wiki/Name_(test)'],
    ['www.example.com', 'https://www.example.com/']
  ]);
});

test('untrusted schemes, credentials, malformed hosts and lookalike identifiers remain text', () => {
  assert.deepEqual(recognized('file://www.example.org javascript:https://example.org data:text/html,text ' +
    'https://example.org@evil.example http:///example.org hello@www.example.org nothttps://example.org ' +
    'http://example.org:99999'), []);
});
