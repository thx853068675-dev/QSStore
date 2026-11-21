const { test } = require('node:test');
const assert = require('node:assert/strict');
const { loadEts } = require('./load_ets.cjs');

function fixture({ confirm = async () => {}, status = async () => ({ login: '' }) } = {}) {
  const storage = new Map();
  const messages = [];
  class Client {
    confirmGitHubNativeAssociation = confirm;
    githubAssociationStatus = status;
  }
  const { GitHubAssociationReturn: callback } = loadEts('data/GitHubAssociationReturn', {
    './DeveloperAccount': { AccountSession: { load: async () => ({ userId: 'test-account' }) } },
    './StoreClient': { StoreClient: Client },
    '../jobs/ErrorText': { errorText: (error) => error.message }
  }, { AppStorage: { get: key => storage.get(key), setOrCreate: (key, value) => storage.set(key, value) } });
  const want = { uri: `qingqi-installer://github-link?code=abc123&state=${'a'.repeat(43)}` };
  const open = () => callback.openPending({}, {
    getPromptAction: () => ({ showToast: ({ message }) => messages.push(message) })
  });
  return { callback, want, open, storage, messages };
}

test('a duplicated browser callback sends exactly one confirmation and refreshes the page', async () => {
  let count = 0;
  const { callback, want, open, storage } = fixture({ confirm: async () => { count++; } });
  assert.equal(callback.receive(want), true);
  const confirming = open();
  assert.equal(storage.get('githubAssociationPhase'), 'confirming');
  assert.equal(callback.receive(want), true);
  await confirming;
  await open();
  assert.equal(count, 1);
  assert.equal(storage.get('githubAssociationRevision'), 1);
});

test('confirmation failure reads the stored binding before showing an error', async () => {
  const confirm = async () => { throw new Error('response interrupted'); };
  const connected = fixture({ confirm, status: async () => ({ login: 'repo-owner' }) });
  connected.callback.receive(connected.want);
  await connected.open();
  assert.deepEqual(connected.messages, ['GitHub 已关联']);
  assert.equal(connected.storage.get('githubAssociationRevision'), 1);

  const interrupted = fixture({ confirm });
  interrupted.callback.receive(interrupted.want);
  await interrupted.open();
  assert.equal(interrupted.storage.get('githubAssociationPhase'), 'failed');
  assert.equal(interrupted.storage.get('githubAssociationFailure'), 'response interrupted');
});
