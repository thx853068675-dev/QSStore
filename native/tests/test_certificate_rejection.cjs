const {test}=require('node:test');
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const ts=require(process.env.QINGQI_TYPESCRIPT||'/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const exportsBox={};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(__dirname,'../entry/src/main/ets/data/CertificateRejection.ets'),'utf8'),{
 compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020}}).outputText,{
 exports:exportsBox,require:()=>({FailureKind:{NETWORK:'network',ACCOUNT:'account'}})});
test('only explicit missing-certificate rejections permit automatic identity recovery',()=>{
 for(const text of ['AGC 拒绝请求：cert not exist.','CERT NOT EXISTS','certificate does not exist','certificate_not_found'])
  assert.equal(exportsBox.isMissingCertificate(new Error(text)),true,text);
 for(const text of ['device not exist','Profile not exist','certificate number exceeds limit','certificate parsing failed','permission denied','request timeout'])
  assert.equal(exportsBox.isMissingCertificate(new Error(text)),false,text);
 for(const failureKind of ['network','account'])
  assert.equal(exportsBox.isMissingCertificate(Object.assign(new Error('cert not exist'),{failureKind})),false);
});
