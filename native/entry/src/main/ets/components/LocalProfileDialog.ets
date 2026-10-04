import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { LocalProfileGroup, LocalProfileStore } from '../data/LocalProfileStore';
import { errorText } from '../jobs/ErrorText';
import { Palette } from '../theme/Palette';
import { StoreIconButton, StoreLayout } from '../theme/StoreDesign';

@Component
export struct LocalProfileDialog {
  @StorageProp('darkMode') darkMode: boolean = false;
  titleForBundle: (bundle: string) => string = (bundle: string) => bundle;
  onClose: () => void = () => {};
  @State private rows: LocalProfileGroup[] = [];
  @State private loading: boolean = true;
  @State private deleting: string = '';
  @State private message: string = '';
  private disposed: boolean = false;
  private colors(): Palette { return Palette.forMode(this.darkMode); }

  aboutToAppear(): void { this.load(); }
  aboutToDisappear(): void { this.disposed = true; }

  private async load(): Promise<void> {
    try {
      const rows = await LocalProfileStore.list(getContext(this) as common.UIAbilityContext);
      if (!this.disposed) this.rows = rows;
    } catch (error) { if (!this.disposed) this.message = errorText(error); }
    finally { if (!this.disposed) this.loading = false; }
  }

  private title(row: LocalProfileGroup): string {
    return row.bundleName ? this.titleForBundle(row.bundleName) : '无法识别的 Profile';
  }
  private summary(row: LocalProfileGroup): string {
    let text = row.files.length + ' 份授权';
    if (row.expiresAt > 0) {
      const date = new Date(row.expiresAt * 1000);
      text += ' · 最晚到期 ' + date.getFullYear() + '-' +
        String(date.getMonth() + 1).padStart(2, '0') + '-' + String(date.getDate()).padStart(2, '0');
    }
    return text;
  }
  private confirmRemove(row: LocalProfileGroup): void {
    if (this.deleting) return;
    AlertDialog.show({ title: '删除 ' + this.title(row) + ' 的本地 Profile？',
      message: '将删除 ' + row.files.length + ' 份本机授权。已安装应用和签名证书不受影响，下次签装可能需要重新申请授权。',
      primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', fontColor: this.colors().danger, action: () => { this.remove(row); } } });
  }
  private async remove(row: LocalProfileGroup): Promise<void> {
    if (this.deleting || this.disposed) return;
    this.deleting = row.key; this.message = '';
    try {
      const count = await LocalProfileStore.remove(getContext(this) as common.UIAbilityContext, row.key);
      promptAction.showToast({ message: count > 0 ? '已删除 ' + count + ' 份本地 Profile' : '该 Profile 已不存在' });
    } catch (error) { if (!this.disposed) this.message = errorText(error); }
    finally { await this.load(); if (!this.disposed) this.deleting = ''; }
  }

  @Builder private deleteAction(row: LocalProfileGroup) {
    Column({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.trash')).fontSize(18).fontColor([this.colors().onAccent])
      Text(this.deleting === row.key ? '删除中' : '删除').fontSize(12).fontColor(this.colors().onAccent)
    }.width(64).height('100%').margin({ left: 8 }).justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors().danger).borderRadius(16).enabled(!this.deleting)
      .accessibilityText('删除 ' + this.title(row) + ' 的本地 Profile')
      .id('local-profile-delete-' + row.key).onClick(() => this.confirmRemove(row))
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Column().width('100%').height('100%').backgroundColor(this.colors().scrim).onClick(() => this.onClose())
      Column({ space: 16 }) {
          Row({ space: 12 }) {
            Column({ space: 4 }) {
              Text('本地 Profile').fontSize(22).fontWeight(FontWeight.Bold).fontColor(this.colors().text)
              Text(this.loading ? '正在读取本机授权…' : this.rows.length + ' 个应用 · ' +
                this.rows.reduce((total: number, row: LocalProfileGroup) => total + row.files.length, 0) + ' 份授权')
                .fontSize(12).fontColor(this.colors().textSecondary)
            }.alignItems(HorizontalAlign.Start).layoutWeight(1)
            StoreIconButton({ action: () => this.onClose() })
          }.width('100%')
          List({ space: 12 }) {
          if (this.loading) { ListItem() { Row() { LoadingProgress().width(28).height(28).color(this.colors().accent) }.width('100%').justifyContent(FlexAlign.Center) } }
          else if (this.rows.length === 0 && !this.message) {
            ListItem() { Text('还没有保存的本地 Profile').fontSize(14).fontColor(this.colors().textSecondary).padding({ top: 20, bottom: 20 }).width('100%').textAlign(TextAlign.Center) }
          } else {
            ForEach(this.rows, (row: LocalProfileGroup) => {
              ListItem() {
                Column({ space: 5 }) {
                  Text(this.title(row)).fontSize(15).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
                    .maxLines(2).width('100%')
                  Text(row.bundleName || row.files[0]).fontSize(11).fontColor(this.colors().textSecondary)
                    .maxLines(2).width('100%').wordBreak(WordBreak.BREAK_ALL)
                  Text(this.summary(row)).fontSize(11).fontColor(this.colors().textTertiary).width('100%')
                }.alignItems(HorizontalAlign.Start).width('100%').padding(14)
                  .backgroundColor(this.colors().fill).borderRadius(16)
              }.swipeAction({ end: { builder: () => { this.deleteAction(row) }, actionAreaDistance: 72 },
                edgeEffect: SwipeEdgeEffect.Spring })
            }, (row: LocalProfileGroup) => row.key)
          }
          }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
          if (this.message) { Text(this.message).fontSize(12).fontColor(this.colors().danger).width('100%') }
          Text('正在安装使用的授权会受到保护。仅管理本机文件。').fontSize(11).fontColor(this.colors().textTertiary).width('100%')
      }.alignItems(HorizontalAlign.Start).width('calc(100% - 40vp)').padding(22)
        .height(this.rows.length > 3 ? '80%' : this.rows.length * 110 + 180)
        .constraintSize({ maxWidth: StoreLayout.sheetWidth, maxHeight: '80%' })
        .backgroundColor(this.colors().surface).borderRadius(26).clip(true)
    }.width('100%').height('100%')
  }
}
