export class SubmitChoice {
  tag: string = '';
  name: string = '';
  displayName: string = '';
  bundleName: string = '';
  versionName: string = '';
  size: number = 0;

  static fromJson(row: Record<string, Object>): SubmitChoice {
    const choice = new SubmitChoice();
    choice.tag = String(row['tag'] ?? '');
    choice.name = String(row['name'] ?? '');
    choice.displayName = String(row['display_name'] ?? '');
    choice.bundleName = String(row['bundle_name'] ?? '');
    choice.versionName = String(row['version_name'] ?? '');
    choice.size = Number(row['size'] ?? 0);
    return choice;
  }
}

export class SubmitDraft {
  token: string = '';
  repo: string = '';
  displayName: string = '';
  suggestedCategory: string = '';
  categories: string[] = [];
  choices: SubmitChoice[] = [];
  /** 服务端给的本店归属：new / mine / other。 */
  existingState: string = 'new';
  /** 已在架时那条记录的编号（0 表示没有）。 */
  existingAppId: number = 0;

  static fromJson(row: Record<string, Object>): SubmitDraft {
    const draft = new SubmitDraft();
    draft.token = String(row['draft_token'] ?? '');
    draft.repo = String(row['repo'] ?? '');
    draft.displayName = String(row['display_name'] ?? '');
    draft.suggestedCategory = String(row['suggested_category'] ?? '');
    const categories = row['categories'] as string[] | undefined;
    draft.categories = categories ?? [];
    const choices = row['choices'] as Array<Record<string, Object>> | undefined;
    draft.choices = (choices ?? []).map((item: Record<string, Object>) =>
      SubmitChoice.fromJson(item));
    const existing = row['existing'] as Record<string, Object> | undefined;
    draft.existingState = String(existing?.['state'] ?? 'new');
    draft.existingAppId = Number(existing?.['app_id'] ?? 0);
    return draft;
  }
}

export class AppReview {
  id: number = 0;
  displayName: string = '';
  avatarUrl: string = '';
  stars: number = 0;
  body: string = '';
  updatedAt: string = '';

  static fromJson(row: Record<string, Object>): AppReview {
    const review = new AppReview();
    review.id = Number(row['id'] ?? 0);
    review.displayName = String(row['display_name'] ?? '');
    const avatar = String(row['avatar_url'] ?? '');
    review.avatarUrl = /^https:\/\//.test(avatar) ? avatar : '';
    review.stars = Number(row['stars'] ?? 0);
    review.body = String(row['body'] ?? '');
    review.updatedAt = String(row['updated_at'] ?? '');
    return review;
  }
}
