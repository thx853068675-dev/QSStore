import { I18n } from './I18n';
/** Tool registration is independent of installation and editor page state. */
export class LocalTool {
  id:string;title:string;formats:string;page:string;symbol:Resource;
  constructor(id:string,title:string,formats:string,page:string,symbol:Resource){
    this.id=id;this.title=title;this.formats=formats;this.page=page;this.symbol=symbol;
  }
}
export function localTools():LocalTool[] {
  return [
  new LocalTool('local-install-tool',I18n.t('从本地签装'),'HAP · APP · ZIP','pages/LocalInstall',$r('sys.symbol.square_and_arrow_down')),
  new LocalTool('local-editor-tool',I18n.t('包编辑'),I18n.t('HAP · APP · 多选'),'pages/PackageTools',$r('sys.symbol.square_and_pencil')),
  new LocalTool('local-app-list-tool',I18n.t('应用列表'),'', 'pages/InstalledApplications',$r('sys.symbol.square_grid_2x2'))
  ];
}
