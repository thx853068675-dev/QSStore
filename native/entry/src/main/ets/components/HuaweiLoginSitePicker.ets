import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { HuaweiLoginPreferences } from '../data/HuaweiLoginPreferences';
import { HUAWEI_SITES, HuaweiSite } from '../data/HuaweiSite';
import { I18n } from '../data/I18n';
import { Palette } from '../theme/Palette';
import { StoreSelect } from '../theme/StoreSelect';

@Component
export struct HuaweiLoginSitePicker {
  @Prop active: boolean = true;
  @StorageProp('darkMode') private darkMode: boolean = false;
  @State private site: HuaweiSite | undefined = undefined;
  @State private busy: boolean = true;

  aboutToAppear(): void { this.load(); }

  private async load(): Promise<void> {
    try {
      this.site = await HuaweiLoginPreferences.selected(getContext(this) as common.UIAbilityContext);
    } catch (_) { /* Keep the system-region default. */ }
    finally { this.busy = false; }
  }

  private label(site?: HuaweiSite): string {
    switch (site) {
      case 'CN': return I18n.t('中国大陆');
      case 'SG': return I18n.t('亚太（新加坡）');
      case 'DE': return I18n.t('欧洲（德国）');
      case 'RU': return I18n.t('俄罗斯');
      default: return I18n.t('自动') + ' · ' + this.label(HuaweiLoginPreferences.suggested());
    }
  }

  private options(): SelectOption[] {
    const options: SelectOption[] = [{ value: this.label() }];
    for (const site of HUAWEI_SITES) options.push({ value: this.label(site) });
    return options;
  }

  private async select(index: number): Promise<void> {
    if (this.busy || !this.active || index < 0 || index > HUAWEI_SITES.length) return;
    const site = index > 0 ? HUAWEI_SITES[index - 1] : undefined;
    this.busy = true;
    try {
      await HuaweiLoginPreferences.save(getContext(this) as common.UIAbilityContext, site);
      this.site = site;
    } catch (_) {
      promptAction.showToast({ message: I18n.t('无法保存登录站点，请重试') });
    } finally {
      this.busy = false;
    }
  }

  build() {
    Column({ space: 5 }) {
      Text(I18n.t('华为登录站点')).fontSize(12).fontColor(Palette.forMode(this.darkMode).textSecondary)
      StoreSelect({ options: this.options(), selectedIndex: this.site ? HUAWEI_SITES.indexOf(this.site) + 1 : 0,
        selectedValue: this.label(this.site), active: this.active && !this.busy, controlId: 'huawei-login-site',
        action: (index: number) => this.select(index) })
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
