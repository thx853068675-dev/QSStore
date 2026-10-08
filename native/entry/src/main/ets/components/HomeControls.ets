import { HomeVisibility } from '../theme/HomeVisibility';
import { StoreImmersiveIconButton } from '../theme/StoreDesign';
import { CatalogAppTitle } from './CatalogAppTitle';
import { InstallCertificatePrompt } from './InstallCertificatePrompt';

/** Lifecycle changes pause only mounted title animations, not the list owner. */
@Component
export struct HomeAppTitle {
  @Prop title: string = '';
  @Prop titleSize: number = 17;
  @Prop titleLines: number = 1;
  @Prop version: string = '';
  @Prop color: string = '#17213A';
  @Prop versionColor: string = '#FFFFFF';
  @Prop versionBackground: string = '#17213A';
  @Prop active: boolean = true;

  build() {
    CatalogAppTitle({ title: this.title, titleSize: this.titleSize, titleLines: this.titleLines,
      version: this.version, color: this.color, versionColor: this.versionColor,
      versionBackground: this.versionBackground, active: this.active, pauseWhenHomeHidden: true })
  }
}

/** Preserve the shared material, hit target and action; isolate route visibility. */
@Component
export struct HomeIconButton {
  @ObjectLink homeVisibility: HomeVisibility;
  symbol: Resource = $r('sys.symbol.chevron_left');
  label: string = '';
  controlId: string = '';
  @Prop visible: boolean = true;
  @Prop loading: boolean = false;
  @Prop active: boolean = true;
  action: () => void = () => {};
  backAction: () => void = () => {};

  build() {
    StoreImmersiveIconButton({ symbol: this.symbol, label: this.label, controlId: this.controlId,
      visible: this.visible && this.homeVisibility.visible, loading: this.loading, active: this.active,
      action: this.action, backAction: this.backAction })
  }
}

@Component
export struct HomeCertificatePrompt {
  @ObjectLink homeVisibility: HomeVisibility;
  @Link showing: boolean;
  @Prop dismissRequest: number = 0;

  build() {
    InstallCertificatePrompt({ active: this.homeVisibility.visible, showing: this.showing,
      dismissRequest: this.dismissRequest })
  }
}
