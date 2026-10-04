/** Database identities retain a platform prefix for non-GitHub repositories. */
export function repositoryUrl(repo: string): string {
  const raw = repo.trim().replace(/^https?:\/\//i, '').replace(/\/+$/, '');
  const match = /^(?:(github\.com|gitee\.com)\/)?([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+)$/i.exec(raw);
  return match === null ? '' : 'https://' + (match[1]?.toLowerCase() ?? 'github.com') + '/' + match[2];
}
