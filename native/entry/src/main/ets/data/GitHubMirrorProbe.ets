import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { CatalogCache } from './CatalogCache';
import { CatalogApp } from './CatalogApp';
import { GitHubMirrorPreferences } from './GitHubMirrorPreferences';
import { PrivacyConsent } from './PrivacyConsent';
import { I18n } from './I18n';

export class GitHubMirrorProbeResult {
  state: string = 'unconfirmed';
  message: string = '';
}

class MirrorProbeRun {
  startedAt: number = Date.now();
  completed: boolean = false;
  timer: number = -1;
  request: http.HttpRequest | undefined;
  resolve: ((result: GitHubMirrorProbeResult) => void) | undefined;
}

/** Checks one cached public release with HEAD, without discovering or downloading a package. */
export class GitHubMirrorProbe {
  private pending: MirrorProbeRun | undefined;

  private result(state: string, message: string): GitHubMirrorProbeResult {
    const result = new GitHubMirrorProbeResult();
    result.state = state; result.message = message;
    return result;
  }

  private active(run: MirrorProbeRun): boolean { return this.pending === run && !run.completed; }

  private finish(run: MirrorProbeRun, result: GitHubMirrorProbeResult): void {
    if (run.completed) return;
    run.completed = true;
    if (run.timer !== -1) clearTimeout(run.timer);
    run.timer = -1;
    try { run.request?.destroy(); } catch (_) {}
    run.request = undefined;
    if (this.pending === run) this.pending = undefined;
    const resolve = run.resolve;
    run.resolve = undefined;
    resolve?.(result);
  }

  cancel(): void {
    const run = this.pending;
    if (run !== undefined) this.finish(run, this.result('unconfirmed', '检查已取消'));
  }

  check(context: common.UIAbilityContext, prefix: string): Promise<GitHubMirrorProbeResult> {
    this.cancel();
    try { PrivacyConsent.assertBusinessAllowed(); }
    catch (_) { return Promise.resolve(this.result('unconfirmed', I18n.t('请先同意隐私声明'))); }
    let normalized: string;
    try { normalized = GitHubMirrorPreferences.normalize(prefix); }
    catch (_) { return Promise.resolve(this.result('warning', I18n.t('请输入有效的 HTTPS 镜像地址'))); }
    if (!normalized) return Promise.resolve(this.result('unconfirmed', I18n.t('填写镜像地址后检验')));
    const run = new MirrorProbeRun();
    this.pending = run;
    return new Promise<GitHubMirrorProbeResult>((resolve: (result: GitHubMirrorProbeResult) => void) => {
      run.resolve = resolve;
      run.timer = setTimeout(() => this.finish(run,
        this.result('warning', I18n.t('连接检查超时，下载时自动回退'))), 8000);
      this.perform(context, normalized, run).then((result: GitHubMirrorProbeResult) => this.finish(run, result))
        .catch(() => this.finish(run, this.result('warning', '连接检查失败，下载时自动回退')));
    });
  }

  private officialUrl(value: string): string {
    const selector = value.indexOf('#qingqi-package=');
    const source = selector >= 0 ? value.substring(0, selector) : value;
    // Do not disclose query credentials to a third party during a connectivity check.
    return /^https:\/\/github\.com\/[^\/?#\\\s]+\/[^\/?#\\\s]+\/releases\/download\/[^\/?#\\\s]+\/[^\/?#\\\s]+$/i.test(source) ? source : '';
  }

  private selectTarget(apps: CatalogApp[]): string {
    for (const app of apps) {
      for (const asset of (app.latestAssets ?? []).concat(app.latestAsset !== undefined ? [app.latestAsset] : [])) {
        const target = this.officialUrl(asset.url);
        if (target) return target;
      }
    }
    return '';
  }

  private async perform(context: common.UIAbilityContext, prefix: string,
    run: MirrorProbeRun): Promise<GitHubMirrorProbeResult> {
    const unconfirmed = this.result('unconfirmed', I18n.t('地址格式有效，下载时检验'));
    let target = '';
    for (const sort of ['stars', 'downloads', 'new']) {
      for (const direction of ['desc', 'asc']) {
        if (!this.active(run)) return unconfirmed;
        try { PrivacyConsent.assertBusinessAllowed(); }
        catch (_) { return this.result('unconfirmed', I18n.t('检查已停止')); }
        try { target = this.selectTarget(await CatalogCache.load(context, sort, direction)); }
        catch (_) { /* A missing or corrupt local snapshot is not a network failure. */ }
        if (!this.active(run)) return unconfirmed;
        if (target) break;
      }
      if (target) break;
    }
    if (!target || !this.active(run)) return unconfirmed;
    try { PrivacyConsent.assertBusinessAllowed(); }
    catch (_) { return this.result('unconfirmed', I18n.t('检查已停止')); }
    const remaining = 8000 - Math.max(0, Date.now() - run.startedAt);
    if (remaining <= 0) return this.result('warning', I18n.t('连接检查超时，下载时自动回退'));
    try {
      const request = http.createHttp();
      run.request = request;
      const response = await request.request(prefix + target, {
        method: http.RequestMethod.HEAD,
        usingCache: false,
        connectTimeout: Math.min(6000, remaining),
        readTimeout: Math.min(6000, remaining),
        maxLimit: 1024,
        maxRedirects: 3
      });
      if (!this.active(run)) return unconfirmed;
      try { PrivacyConsent.assertBusinessAllowed(); }
      catch (_) { return this.result('unconfirmed', I18n.t('检查已停止')); }
      const code = response.responseCode;
      if (code === 405 || code === 501) return unconfirmed;
      if (code < 200 || code >= 300) {
        return this.result('warning', I18n.t('连接检查未通过（HTTP ') + code + I18n.t('），下载时自动回退'));
      }
      const headers = response.header as Record<string, Object>;
      const type = Object.keys(headers).filter((key: string) => key.toLowerCase() === 'content-type')
        .map((key: string) => String(headers[key])).join(';');
      if (/text\/html|application\/xhtml\+xml/i.test(type) || (typeof response.result === 'string' &&
        /^\s*(?:<!doctype\s+html|<html(?:\s|>))/i.test(response.result))) return unconfirmed;
      return this.result('success', I18n.t('连接检查通过'));
    } catch (error) {
      const record = error as Record<string, Object>;
      return this.result('warning', Number(record['code']) === 2300028 || /timeout|timed out/i.test(String(error)) ?
        I18n.t('连接检查超时，下载时自动回退') : '连接检查失败，下载时自动回退');
    } finally {
      // Timeout/cancel may already have destroyed it while the response was pending.
      try { run.request?.destroy(); } catch (_) {}
      run.request = undefined;
    }
  }
}
