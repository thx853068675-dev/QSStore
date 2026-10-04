/** Tool registration is independent of installation and editor page state. */
export class LocalTool {
  id:string;title:string;detail:string;formats:string;page:string;symbol:Resource;
  constructor(id:string,title:string,detail:string,formats:string,page:string,symbol:Resource){
    this.id=id;this.title=title;this.detail=detail;this.formats=formats;this.page=page;this.symbol=symbol;
  }
}
export const LocalTools:LocalTool[]=[
  new LocalTool('local-install-tool','从本地签装','预览后签名安装','HAP · APP · ZIP','pages/LocalInstall',$r('sys.symbol.square_and_arrow_down')),
  new LocalTool('local-editor-tool','包编辑','独立修改名称、包名与图标','HAP · APP · 多选','pages/PackageTools',$r('sys.symbol.square_and_pencil'))
];
