export class ClaimedApplication {
  appId: number = 0;
  name: string = '';
  repo: string = '';

  static fromJson(row: Record<string, Object>): ClaimedApplication {
    const item = new ClaimedApplication();
    item.appId = Number(row['app_id'] ?? 0);
    item.name = String(row['name'] ?? '');
    item.repo = String(row['repo'] ?? '');
    return item;
  }
}

export class DeveloperCenterState {
  enrolled: boolean = false;
  apps: ClaimedApplication[] = [];

  static fromJson(row: Record<string, Object>): DeveloperCenterState {
    const state = new DeveloperCenterState();
    state.enrolled = row['enrolled'] === true;
    const items = row['items'] as Array<Record<string, Object>> | undefined;
    if (Array.isArray(items)) state.apps = items.map((item: Record<string, Object>) =>
      ClaimedApplication.fromJson(item)).filter((item: ClaimedApplication) =>
      Number.isSafeInteger(item.appId) && item.appId > 0);
    return state;
  }
}

export class RepositoryClaim {
  status: string = '';

  static fromJson(row: Record<string, Object>): RepositoryClaim {
    const state = new RepositoryClaim();
    state.status = String(row['status'] ?? '');
    return state;
  }
}

export class GitHubAssociationStatus {
  enabled: boolean = false;
  login: string = '';

  static fromJson(row: Record<string, Object>): GitHubAssociationStatus {
    const result = new GitHubAssociationStatus();
    result.enabled = row['enabled'] === true;
    result.login = String(row['login'] ?? '');
    return result;
  }
}
