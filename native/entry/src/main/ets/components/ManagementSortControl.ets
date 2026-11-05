
import { Palette } from '../theme/Palette';
import { I18n } from '../data/I18n';

/** A fixed capsule keeps sorting independent of the search/category morph and viewport mask. */
@Component
export struct ManagementSortControl {
  @StorageProp('materialMode') private materialMode: string = 'adaptive';
  @StorageProp('routeTransitioning') @Watch('closeMenuWhenHidden') private routeTransitioning: boolean = false;
  @Prop @Watch('closeMenuWhenHidden') active: boolean = true;
  @Prop @Watch('closeMenuWhenHidden') foreground: boolean = true;
  @Prop darkMode: boolean = false;
  @Prop sortKey: string = 'updated';
  @Prop sortDirection: string = 'desc';
  @Prop loading: boolean = false;
  @Prop onlyUpdated:boolean=false;
  controlId:string='management-sort';
  @State private menuOpen: boolean = false;
  onSort: (key: string) => void = () => {};
  onReverse: () => void = () => {};
  backAction: () => void = () => {};

  private closeMenuWhenHidden(): void {
    if (!this.active || !this.foreground || this.routeTransitioning) this.menuOpen = false;
  }
  private choose(key: string): void { this.menuOpen = false; this.onSort(key); }
  private chooseDirection(direction: string): void {
    this.menuOpen = false;
    if (direction !== this.sortDirection) this.onReverse();
  }

  private materialBack(): void {
    if (!this.active || !this.foreground || this.routeTransitioning) return;
    if (this.menuOpen) this.menuOpen = false;
    else this.backAction();
  }

  @Builder private sortMenu() {
    Menu() {
      if(!this.onlyUpdated){
        MenuItem({content:I18n.t('更新时间'),labelInfo:this.sortKey==='updated'?'✓':''})
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(()=>this.choose('updated'))
        MenuItem({content:I18n.t('到期时间'),labelInfo:this.sortKey==='expiry'?'✓':''})
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent).onClick(()=>this.choose('expiry'))
      }
      MenuItemGroup() {
        MenuItem({ content: I18n.t('升序'), labelInfo: this.sortDirection === 'asc' ? '✓' : '' })
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent)
          .onClick(() => this.chooseDirection('asc'))
        MenuItem({ content: I18n.t('降序'), labelInfo: this.sortDirection === 'desc' ? '✓' : '' })
          .contentFontColor(Palette.forMode(this.darkMode).text).labelFontColor(Palette.forMode(this.darkMode).accent)
          .onClick(() => this.chooseDirection('desc'))
      }
    }
  }

  build(){
    Button({type:ButtonType.Normal}){
      Row({space:4}){
        Text(I18n.t(this.sortKey==='expiry'?'到期时间':'更新时间')).fontSize(13).fontWeight(FontWeight.Medium)
          .fontColor(Palette.forMode(this.darkMode).textSecondary)
        SymbolGlyph(this.sortDirection==='asc'?$r('sys.symbol.arrow_up'):$r('sys.symbol.arrow_down'))
          .fontSize(12).fontColor([Palette.forMode(this.darkMode).textSecondary])
      }
    }.height(44).padding({left:6,right:2}).backgroundColor(Color.Transparent).borderRadius(8)
      .id(this.controlId).accessibilityText(I18n.t('排序，')+I18n.t(this.sortKey==='expiry'?'到期时间':'更新时间')+
        I18n.t(this.sortDirection==='asc'?'，升序':'，降序'))
      .enabled(this.active).onClick(()=>{this.menuOpen=!this.menuOpen;})
      .bindMenu(this.menuOpen,this.sortMenu,{
        placement:Placement.BottomRight,backgroundColor:Palette.forMode(this.darkMode).surface,
        backgroundBlurStyle:BlurStyle.NONE,borderRadius:18,onDisappear:()=>{this.menuOpen=false;}
      })
  }
}
