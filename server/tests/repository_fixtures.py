"""Deterministic forge identities for tests that already stub repository HTTP."""
import hashlib
from unittest.mock import patch
from server.hapstore import submission_repository


def identity_for(repo):
    return dict(provider='gitee' if repo.startswith('gitee.com/') else 'github',
        remote_id=int.from_bytes(hashlib.sha256(repo.lower().encode()).digest()[:7], 'big') + 1,
        canonical_repo=repo.lower())


def mock_repository_identity(case):
    mock = patch.object(submission_repository, 'resolve', side_effect=lambda repo, **kw: identity_for(repo))
    case.addCleanup(mock.stop)
    return mock.start()
