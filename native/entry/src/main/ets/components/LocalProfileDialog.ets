import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { LocalProfileGroup, LocalProfileStore } from '../data/LocalProfileStore';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';
import { I18n } from '../data/I18n';

@Component
export struct LocalProfileDialog {
  @StorageProp('darkMode') darkMode: boolean = false;
  titleForBundle: (bundle: string) => string = (bundle: string) => bundle;
  onClose: () => void = () => {};
  @State private rows: LocalProfileGroup[] = [];
  @State private loading: boolean = true;
  @State private deleting: string = '';
  @State private message: string = '';
  @State private listHeight: number = 64;
  private rowHeights: Map<string, number> = new Map();
  private disposed: boolean = false;
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.disposed = true; }

  private async load(): Promise<void> {
    try {
      const rows = await LocalProfileStore.list(getContext(this) as common.UIAbilityContext);
      if (!this.disposed) { this.rows = rows; this.measureList(); }
    } catch (error) { if (!this.disposed) this.message = errorText(error); }
    finally { if (!this.disposed) this.loading = false; }
  }

  private measureList(): void {
    const height = this.rows.length === 0 ? 64 : this.rows.reduce((total: number, row: LocalProfileGroup) =>
      total + (this.rowHeights.get(row.key) ?? 86), 0) + Math.max(0, this.rows.length - 1) * 12;
    if (this.listHeight !== height) this.listHeight = height;
  }

  private title(row: LocalProfileGroup): string {
    return row.bundleName ? this.titleForBundle(row.bundleName) : I18n.t('无法识别的 Profile');
  }
  private summary(row: LocalProfileGroup): string {
    let text = row.files.length + I18n.t(' 份授权');
    if (row.expiresAt > 0) {
      const date = new Date(row.expiresAt * 1000);
      text += I18n.t(' · 最晚到期 ') + date.getFullYear() + '-' +
        String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
    }
    return text;
  }
  private confirmRemove(row: LocalProfileGroup): void {
    if (this.deleting) return;
    AlertDialog.show({ title: I18n.t('删除 ') + this.title(row) + I18n.t(' 的本地 Profile？'),
      message: I18n.t('将删除 ') + row.files.length + I18n.t(' 份本机授权。已安装应用和签名证书不受影响，下次签装可能需要重新申请授权。'),
      primaryButton: { value: I18n.t('取消'), action: () => {} },
      secondaryButton: { value: I18n.t('删除'), fontColor: this.colors().danger, action: () => { this.remove(row); } } });
  }
  private async remove(row: LocalProfileGroup): Promise<void> {
    if (this.deleting || this.disposed) return;
    this.deleting = row.key; this.message = '';
    try {
      const count = await LocalProfileStore.remove(getContext(this) as common.UIAbilityContext, row.key);
      promptAction.showToast({ message: count > 0 ? I18n.t('已删除 ') + count + I18n.t(' 份本地 Profile') : I18n.t('该 Profile 已不存在') });
    } catch (error) { if (!this.disposed) this.message = errorText(error); }
    finally { await this.load(); if (!this.disposed) this.deleting = ''; }
  }

  @Builder private deleteAction(row: LocalProfileGroup) {
    Column({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([this.colors().onAccent])
      Text(this.deleting === row.key ? I18n.t('删除中') : I18n.t('删除')).fontSize(12).fontColor(this.colors().onAccent)
    }.width(64).height('100%').margin({ left: 8 }).justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors().danger).borderRadius(16).enabled(!this.deleting)
      .accessibilityText(I18n.t('删除 ') + this.title(row) + I18n.t(' 的本地 Profile'))
      .id('local-profile-delete-' + row.key).onClick(() => this.confirmRemove(row))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.onClose())
      Column({ space: 16 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text(I18n.t('本地 Profile')).fontSize(20).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
              Text(this.loading ? I18n.t('正在读取本机授权…') : this.rows.length + I18n.t(' 个应用 · ') +
                this.rows.reduce((total: number, row: LocalProfileGroup) => total + row.files.length, 0) + I18n.t(' 份授权'))
                .fontSize(12).fontColor(this.colors().textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            StoreIconButton({ action: () => this.onClose() })
          }.width('100%')
          List({ space: 12 }) {
          if (this.loading) { ListItem() { Row() { LoadingProgress().width(28).height(28).color(this.colors().accent) }.width('100%').justifyContent(FlexAlign.Center) } }
          else if (this.rows.length === 0 && !this.message) {
            ListItem() { Text(I18n.t('还没有保存的本地 Profile')).fontSize(14).fontColor(this.colors().textSecondary).padding({ top: 20, bottom: 20 }).width('100%').textAlign(TextAlign.Center) }
          } else {
            ForEach(this.rows, (row: LocalProfileGroup) => {
              ListItem() {
                Column({ space: 5 }) {
                  Text(this.title(row)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
                    .maxLines(2).width('100%')
                  Text(row.bundleName || row.files[0]).fontSize(12).fontColor(this.colors().textSecondary)
                    .maxLines(2).width('100%').wordBreak(WordBreak.BREAK_ALL)
                  Text(this.summary(row)).fontSize(12).fontColor(this.colors().textSecondary).width('100%')
                }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
                  .backgroundColor(this.colors().fill).borderRadius(16)
                  .onSizeChange((_old: SizeOptions, size: SizeOptions) => {
                    const height = Number(size.height);
                    if (height > 0 && this.rowHeights.get(row.key) !== height) {
                      this.rowHeights.set(row.key, height); this.measureList();
                    }
                  })
              }.swipeAction({ end: { builder: () => { this.deleteAction(row) }, actionAreaDistance: 72 },
                edgeEffect: SwipeEdgeEffect.Spring })
            }, (row: LocalProfileGroup) => row.key)
          }
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
          if (this.message) { Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%') }
      }.alignItems(HorizontalAlign.Start).width('calc(100% - 40vp)').padding(22)
        .height(this.rows.length > 3 ? '80%' : this.listHeight + 106 + (this.message ? 32 : 0))
        .constraintSize({ maxWidth: StoreLayout.sheetWidth, maxHeight: '80%' })
        .backgroundColor(this.colors().surface).borderRadius(StoreLayout.dialogRadius).clip(true)
    }.width('100%').height('100%')
  }
}
