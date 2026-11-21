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
  inspectionStatus: string = 'ready';
  supportsMultiSelect: boolean = false;
  repo: string = '';
  displayName: string = '';
  suggestedCategory: string = '';
  description: string = '';
  categories: string[] = [];
  choices: SubmitChoice[] = [];
  /** 服务端给的本店归属：new / mine / other。 */
  existingState: string = 'new';
  /** 已在架时那条记录的编号（0 表示没有）。 */
  existingAppId: number = 0;

  static fromJson(row: Record<string, Object>): SubmitDraft {
    const draft = new SubmitDraft();
    draft.token = String(row['draft_token'] ?? '');
    draft.inspectionStatus = String(row['inspection_status'] ?? 'ready');
    draft.supportsMultiSelect = row['supports_multi_select'] === true;
    draft.repo = String(row['repo'] ?? '');
    draft.displayName = String(row['display_name'] ?? '');
    draft.description = String(row['description'] ?? '');
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

export function reviewDeviceModel(value: Object | undefined): string {
  if (typeof value !== 'string') return '';
  const label = value.trim();
  return label.length > 80 || /[\u0000-\u001f\u007f-\u009f]/.test(label) ||
    /^(unknown|null|undefined|n\/a|-|未知)$/i.test(label) ? '' : label;
}

export function reviewMetadata(time: string, model: string): string {
  return time && model ? time + ' · ' + model : time || model;
}

class ReviewMessage {
  canDelete: boolean = false;
  isDeveloper: boolean = false;
  id: number = 0;
  displayName: string = '';
  avatarUrl: string = '';
  body: string = '';
  updatedAt: string = '';
  deviceModel: string = '';

  static read(review: ReviewMessage, row: Record<string, Object>): void {
    review.id = Number(row['id'] ?? 0);
    review.canDelete = row['can_delete'] === true || row['can_delete'] === 1;
    review.isDeveloper = row['is_developer'] === true;
    review.displayName = String(row['display_name'] ?? '');
    const avatar = String(row['avatar_url'] ?? '');
    review.avatarUrl = /^https:\/\//.test(avatar) ? avatar : '';
    review.body = String(row['body'] ?? '');
    review.updatedAt = String(row['updated_at'] ?? row['created_at'] ?? '');
    review.deviceModel = reviewDeviceModel(row['device_model']);
  }
}

export class ReviewReply extends ReviewMessage {
  replyToId: number = 0;
  replyToName: string = '';

  static fromJson(row: Record<string, Object>): ReviewReply {
    const reply = new ReviewReply();
    ReviewMessage.read(reply, row);
    const target = Number(row['reply_to_id'] ?? 0);
    reply.replyToId = Number.isSafeInteger(target) && target > 0 ? target : 0;
    reply.replyToName = reply.replyToId > 0 ? String(row['reply_to_name'] ?? '') : '';
    return reply;
  }
}

export class AppReview extends ReviewMessage {
  stars: number = 0;
  hidden: boolean = false;
  replyCount: number = 0;
  replyPreview?: ReviewReply[];

  static fromJson(row: Record<string, Object>): AppReview {
    const review = new AppReview();
    ReviewMessage.read(review, row);
    review.hidden = row['hidden'] === true;
    review.stars = Number(row['stars'] ?? 0);
    const count = Number(row['reply_count'] ?? 0);
    review.replyCount = Number.isSafeInteger(count) && count > 0 ? count : 0;
    const preview = row['reply_preview'] as Array<Record<string, Object>> | undefined;
    if (Array.isArray(preview)) review.replyPreview = preview.map(item => ReviewReply.fromJson(item));
    return review;
  }
}
