import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { I18n } from './I18n';

const DEVELOPER_MODE_KEY: string = 'localDeveloperMode';

export class LocalDeveloperMode {
  private static restored: boolean = false;

  static enabled(): boolean {
    return AppStorage.get<boolean>(DEVELOPER_MODE_KEY) === true;
  }

  static async restore(context: common.UIAbilityContext): Promise<void> {
    if (LocalDeveloperMode.restored || LocalDeveloperMode.enabled()) return;
    try {
      const store = await preferences.getPreferences(context, 'qingqi-settings');
      const enabled = await store.get(DEVELOPER_MODE_KEY, false);
      if (!LocalDeveloperMode.restored && enabled === true) {
        AppStorage.setOrCreate<boolean>(DEVELOPER_MODE_KEY, true);
      }
      LocalDeveloperMode.restored = true;
    } catch (_) { /* Keep the tool hidden if the preference cannot be read. */ }
  }

  static async enable(context: common.UIAbilityContext): Promise<void> {
    await LocalDeveloperMode.restore(context);
    if (LocalDeveloperMode.enabled()) return;
    const store = await preferences.getPreferences(context, 'qingqi-settings');
    LocalDeveloperMode.restored = true;
    await store.put(DEVELOPER_MODE_KEY, true);
    await store.flush();
    AppStorage.setOrCreate<boolean>(DEVELOPER_MODE_KEY, true);
  }
}

/** Tool registration is independent of installation and editor page state. */
export class LocalTool {
  id:string;title:string;formats:string;page:string;symbol:Resource;
  constructor(id:string,title:string,formats:string,page:string,symbol:Resource){
    this.id=id;this.title=title;this.formats=formats;this.page=page;this.symbol=symbol;
  }
}
export function localTools(developerMode: boolean = false):LocalTool[] {
  const tools: LocalTool[] = [
  new LocalTool('local-install-tool',I18n.t('从本地签装'),'HAP · APP · ZIP','pages/LocalInstall',$r('sys.symbol.square_and_arrow_down')),
  new LocalTool('local-editor-tool',I18n.t('包编辑'),I18n.t('HAP · APP · 多选'),'pages/PackageTools',$r('sys.symbol.square_and_pencil')),
  new LocalTool('local-app-list-tool',I18n.t('应用列表'),'', 'pages/InstalledApplications',$r('sys.symbol.square_grid_2x2'))
  ];
  if (developerMode) {
    tools.push(new LocalTool('local-grab-tool', I18n.t('应用市场提取'), I18n.t('HAP · APP · 自动'),
      'pages/AppGalleryGrab', $r('sys.symbol.square_and_arrow_down')));
  }
  return tools;
}
