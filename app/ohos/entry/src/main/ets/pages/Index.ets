
import common from '@ohos.app.ability.common';
import { FlutterPage } from '@ohos/flutter_ohos'
import { HdsTabs, hdsMaterial } from '@kit.UIDesignKit';
import { SymbolGlyphModifier } from '@kit.ArkUI';

let storage = LocalStorage.getShared()
const EVENT_BACK_PRESS = 'EVENT_BACK_PRESS'

@Entry(storage)
@Component
struct Index {
  private context = getContext(this) as common.UIAbilityContext
  @LocalStorageLink('viewId') viewId: string = "";
  @StorageLink('nativeTabsVisible') nativeTabsVisible: boolean = false;
  @StorageLink('nativeTabIndex') nativeTabIndex: number = 0;

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      FlutterPage({ viewId: this.viewId })
        .width('100%').height('100%')
      if (this.nativeTabsVisible) {
        HdsTabs({ barPosition: BarPosition.End, index: this.nativeTabIndex }) {
          TabContent().tabBar(BottomTabBarStyle.of({
            normal: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2'))
          }, '发现'))
          TabContent().tabBar(BottomTabBarStyle.of({
            normal: new SymbolGlyphModifier($r('sys.symbol.folder'))
          }, '本地'))
          TabContent().tabBar(BottomTabBarStyle.of({
            normal: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2'))
          }, '管理'))
          TabContent().tabBar(BottomTabBarStyle.of({
            normal: new SymbolGlyphModifier($r('sys.symbol.person'))
          }, '我的'))
        }
        .vertical(false)
        .barMode(BarMode.Fixed)
        .barOverlap(true)
        .barFloatingStyle({
          barSideMargin: 12,
          barBottomMargin: 6,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          }
        })
        .onChange((index: number) => {
          this.nativeTabIndex = index;
          this.context.eventHub.emit('NATIVE_TAB_TAP', index);
        })
        .width('100%').height(86)
      }
    }.width('100%').height('100%')
  }

  onBackPress(): boolean {
    // hdcCmd("hdc conn -t 192.168.3.47:44433", this.context.tempDir, ()=>{
    //
    // })
    this.context.eventHub.emit(EVENT_BACK_PRESS)
    return true
  }
}
