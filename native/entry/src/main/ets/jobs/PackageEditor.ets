import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { readArchiveFile, readModuleJson, readPackInfo, rewriteArchive, listPackageEntries, listProfileEntries } from 'libhap_core.so';
import { BundleReferences } from './BundleReferences';
import { ResourceIndex } from './ResourceIndex';
import { PackageArchive } from './PackageArchive';
import { PackageIdentity } from './PackageInspector';
import { StorageBudget } from './StorageBudget';

export class EditablePackage {
  path: string = ''; filename: string = ''; identity: PackageIdentity = new PackageIdentity();
  bytes: number = 0; newName: string = ''; editedPath: string = ''; status: string = ''; icon?: ArrayBuffer;
  modules: Record<string, Object>[] = []; permissions: string[] = [];
}
export class PackageEditor {
  static async select(context: common.UIAbilityContext): Promise<EditablePackage[]> {
    const paths = await new picker.DocumentViewPicker(context).select({fileSuffixFilters:['HarmonyOS 安装包|.hap,.app'],maxSelectNumber:20});
    const dir = context.cacheDir + '/package-editor'; if (!fileIo.accessSync(dir)) fileIo.mkdirSync(dir,true);
    const rows: EditablePackage[] = [];let copiedBytes=0;
    for (let i=0;i<paths.length;i++) {
      const row = new EditablePackage(); const decoded = decodeURIComponent(paths[i].split('?')[0]);
      row.filename = decoded.substring(decoded.lastIndexOf('/')+1); row.path = dir + '/edit-' + Date.now() + '-' + i + PackageArchive.extension(row.filename);
      try {
        const file = fileIo.openSync(paths[i],fileIo.OpenMode.READ_ONLY);
        try { row.bytes=fileIo.statSync(file.fd).size; if (row.bytes<=0 || row.bytes>2*1024*1024*1024) throw new Error('文件大小无效'); if(copiedBytes+row.bytes>2*1024*1024*1024)throw new Error('每批文件总大小不能超过 2 GB');await StorageBudget.require(dir,row.bytes*3); await fileIo.copyFile(file.fd,row.path);copiedBytes+=row.bytes; }
        finally {fileIo.closeSync(file);}
        row.identity = await PackageArchive.inspect(row.path); row.newName=row.identity.displayName;
        row.icon=await PackageArchive.icon(row.path); row.permissions=await PackageArchive.permissions(row.path);
        row.modules=(await PackageArchive.modulePaths(row.path)).map((path: string) => JSON.parse(readModuleJson(path)) as Record<string,Object>);
        row.status='已读取';
      } catch (error) {PackageArchive.release(row.path);if(fileIo.accessSync(row.path))fileIo.unlinkSync(row.path);row.status='读取失败：'+String(error);}
      rows.push(row);
    }
    return rows;
  }
  static write(path: string, bytes: Uint8Array): void {
    const file=fileIo.openSync(path,fileIo.OpenMode.CREATE|fileIo.OpenMode.TRUNC|fileIo.OpenMode.WRITE_ONLY);
    try {let at=0; while(at<bytes.length) {const chunk=bytes.slice(at); const count=fileIo.writeSync(file.fd,chunk.buffer); if(count<=0)throw new Error('文件写入失败');at+=count;}}
    finally{fileIo.closeSync(file);}
  }
  static text(path: string, value: Object): void {PackageEditor.write(path,new util.TextEncoder().encodeInto(JSON.stringify(value)));}
  static async normalizeIcon(uri: string, context: common.UIAbilityContext): Promise<string> {
    const file=fileIo.openSync(uri,fileIo.OpenMode.READ_ONLY); const source=image.createImageSource(file.fd);
    try {
      const info=await source.getImageInfo();const side=Math.min(info.size.width,info.size.height);
      if(side<=0 || info.size.width*info.size.height>40000000)throw new Error('图片尺寸过大');
      const pixels=await source.createPixelMap({desiredSize:{width:512,height:512},desiredRegion:{x:Math.floor((info.size.width-side)/2),y:Math.floor((info.size.height-side)/2),size:{width:side,height:side}},cropAndScaleStrategy:image.CropAndScaleStrategy.CROP_FIRST});const packer=image.createImagePacker();
      try {const bytes=await packer.packing(pixels,{format:'image/png',quality:100});if(bytes.byteLength>1024*1024)throw new Error('图标过大');const path=context.cacheDir+'/package-editor/icon-'+Date.now()+'.png';PackageEditor.write(path,new Uint8Array(bytes));return path;}
      finally {pixels.release();packer.release();}
    } finally{source.release();fileIo.closeSync(file);}
  }
  static async edit(row: EditablePackage, name: string, iconPath: string, bundleName: string = ''): Promise<string> {
    const previous=row.editedPath;row.editedPath='';
    if(previous){PackageArchive.release(previous);if(fileIo.accessSync(previous))fileIo.unlinkSync(previous);}
    const label=name.trim();if(label.length>64 || /[\x00-\x1f]/.test(label))throw new Error('应用名称应为 1–64 个字符');
    const bundle=bundleName.trim()||row.identity.bundleName;
    if(bundle.length<7||bundle.length>128||!/^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$/.test(bundle))throw new Error('包名应为 7–128 位字母、数字、下划线及点，且每段以字母开头');
    if(!label && !iconPath && bundle===row.identity.bundleName)throw new Error('请填写名称、包名或选择图标');
    await StorageBudget.require(row.path,PackageArchive.workingBytes(row.path));
    const modules=await PackageArchive.modulePaths(row.path), modified: string[]=[]; const tempFiles: string[]=[];
    const output=row.path.replace(/\.(hap|app)$/i,'-edited.$1'); const staging=output+'.part';
    try {
      for(let i=0;i<modules.length;i++) {
        const path=modules[i], manifest=JSON.parse(readModuleJson(path)) as Record<string,Object>;
        let index:ResourceIndex|undefined;try{index=new ResourceIndex(readArchiveFile(path,'resources.index'));}catch(_){}
        const app=manifest['app'] as Record<string,Object>, module=manifest['module'] as Record<string,Object>;
        if(bundle!==row.identity.bundleName)BundleReferences.object(manifest,row.identity.bundleName,bundle);
        const targets: Record<string,Object>[]=[app];
        for(const ability of (module['abilities']??[]) as Record<string,Object>[]) {
          const skills=(ability['skills']??[]) as Record<string,Object>[];
          if(ability['name']===module['mainElement'] || skills.some((skill:Record<string,Object>) => ((skill['entities']??[]) as string[]).includes('entity.system.home')))targets.push(ability);
        }
        const changes=new Map<number,string>();const iconEntry='resources/base/media/qingqi_edited_icon.png';
        for(const target of targets) {
          if(label) {const id=Number(target['labelId']??0);if(id>0 && index?.value(id))changes.set(id,label);target['label']=label;}
          if(iconPath) {const id=Number(target['iconId']??0);if(id>0 && index?.value(id))changes.set(id,String(module['name'])+'/'+iconEntry);else if(modules.length===1)throw new Error('安装包没有可编辑的图标资源编号');target['icon']='$media:qingqi_edited_icon';}
        }
        const names=['module.json'],files=[path+'.edit-manifest']; tempFiles.push(files[0]);PackageEditor.text(files[0],manifest);
        if(changes.size>0 || (index && bundle!==row.identity.bundleName)) {if(!index)throw new Error('安装包没有可编辑资源索引');const indexFile=path+'.edit-index';PackageEditor.write(indexFile,index.replace(changes,bundle!==row.identity.bundleName?row.identity.bundleName:'',bundle));names.push('resources.index');files.push(indexFile);tempFiles.push(indexFile);}
        if(iconPath){names.push(iconEntry);files.push(iconPath);}
        if(bundle!==row.identity.bundleName){
          const decoder=util.TextDecoder.create('utf-8',{fatal:true});
          for(const entry of listProfileEntries(path)){
            const profile=JSON.parse(decoder.decodeToString(readArchiveFile(path,entry.name))) as Record<string,Object>;
            const original=JSON.stringify(profile);BundleReferences.object(profile,row.identity.bundleName,bundle);
            if(JSON.stringify(profile)!==original){const file=path+'.edit-profile-'+names.length;PackageEditor.text(file,profile);names.push(entry.name);files.push(file);tempFiles.push(file);}
          }
        }
        const packText=readPackInfo(path);
        if(packText) {const pack=JSON.parse(packText) as Record<string,Object>;if(bundle!==row.identity.bundleName)BundleReferences.object(pack,row.identity.bundleName,bundle);const summary=pack['summary'] as Record<string,Object>;const packApp=summary?.['app'] as Record<string,Object>;if(packApp && label)packApp['label']=label;const packFile=path+'.edit-pack';PackageEditor.text(packFile,pack);names.push('pack.info');files.push(packFile);tempFiles.push(packFile);}
        const changed=path+'.edited.hap';tempFiles.push(changed);
        if(bundle!==row.identity.bundleName)await rewriteArchive(path,changed,names,files,row.identity.bundleName,bundle);
        else await rewriteArchive(path,changed,names,files);
        modified.push(changed);
      }
      if(PackageArchive.extension(row.path)==='.app') {
        const names=listPackageEntries(row.path).map((entry)=>entry.name),files=modified.slice();
        const packText=readPackInfo(row.path);
        if(packText){const pack=JSON.parse(packText) as Record<string,Object>;if(bundle!==row.identity.bundleName)BundleReferences.object(pack,row.identity.bundleName,bundle);const packApp=(pack['summary'] as Record<string,Object>)?.['app'] as Record<string,Object>;if(packApp&&label)packApp['label']=label;const packFile=row.path+'.edit-pack';PackageEditor.text(packFile,pack);names.push('pack.info');files.push(packFile);tempFiles.push(packFile);}
        await rewriteArchive(row.path,staging,names,files);
      } else await fileIo.copyFile(modified[0],staging);
      const actual=await PackageArchive.inspect(staging,PackageArchive.extension(row.path));
      if(label && actual.displayName!==label)throw new Error('编辑后的应用名称校验失败');
      if(actual.bundleName!==bundle || actual.versionCode!==row.identity.versionCode)throw new Error('编辑后的包名或版本校验失败');
      PackageArchive.release(staging);
      if(fileIo.accessSync(output))fileIo.unlinkSync(output);fileIo.renameSync(staging,output);row.editedPath=output;return output;
    } finally {
      PackageArchive.release(staging);
      if(fileIo.accessSync(staging))fileIo.unlinkSync(staging);
      for(const path of tempFiles)try{if(fileIo.accessSync(path))fileIo.unlinkSync(path);}catch(_){}
    }
  }
  static async saveMany(context:common.UIAbilityContext,rows:EditablePackage[]):Promise<number>{
    const selected=rows.filter((row:EditablePackage)=>!!row.editedPath);
    if(!selected.length)throw new Error('请先生成修改后的安装包');
    const used=new Set<string>();
    const filenames=selected.map((row:EditablePackage,index:number)=>{
      let name=row.filename.replace(/\.(hap|app)$/i,'-修改.$1');
      if(used.has(name))name=name.replace(/\.(hap|app)$/i,'-'+(index+1)+'.$1');used.add(name);return name;
    });
    const selection=await new picker.DocumentViewPicker(context).save({newFileNames:filenames});
    if(!selection.length)return 0;
    if(selection.length!==selected.length)throw new Error('保存位置数量与安装包数量不一致');
    let saved=0;
    for(let i=0;i<selected.length;i++){
      const row=selected[i];
      try{const output=fileIo.openSync(selection[i],fileIo.OpenMode.WRITE_ONLY|fileIo.OpenMode.TRUNC);
        try{await fileIo.copyFile(row.editedPath,output.fd);}finally{fileIo.closeSync(output);}
        row.status='已导出';saved++;
      }catch(error){row.status='导出失败：'+String(error);}
    }
    return saved;
  }
  static cleanup(context:common.UIAbilityContext):void{
    const dir=context.cacheDir+'/package-editor';
    if(!fileIo.accessSync(dir))return;
    for(const name of fileIo.listFileSync(dir))try{fileIo.unlinkSync(dir+'/'+name);}catch(_){}
  }
  static dispose(rows:EditablePackage[]):void{
    for(const row of rows)for(const path of [row.path,row.editedPath]){
      PackageArchive.release(path);if(path)try{if(fileIo.accessSync(path))fileIo.unlinkSync(path);}catch(_){}
    }
  }
}
