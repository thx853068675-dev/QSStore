const {test}=require('node:test');
const assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const release=loadEts('data/ReleaseInfo');
const catalog=loadEts('data/CatalogApp',{'./ReleaseInfo':release});
const {CatalogApp}=catalog;
const {DiscoveryCollections}=loadEts('data/DiscoveryCollections',{'./CatalogApp':catalog});

test('global marker only follows the authoritative server field and survives catalog/channel copies',()=>{
  const app=CatalogApp.fromJson({id:274,display_name:'HGhub',distribution_region:'overseas'});
  assert.equal(app.overseas,true);
  assert.equal(CatalogApp.copy(app).overseas,true);
  for(const row of [{}, {display_name:'VPN'}, {category:'海外'}, {distribution_region:'review'}, {distribution_region:true}]){
    assert.equal(CatalogApp.fromJson(row).overseas,false);
  }
});

test('ordinary and legacy responses cannot create an overseas shelf, and switching networks removes it',()=>{
  const ordinary={key:'stars',items:[{id:1}]};
  const overseas={key:'overseas',items:[{id:274,distribution_region:'overseas'}]};
  for(const flag of [undefined,false,'true',1]){
    const data=DiscoveryCollections.fromJson({show_overseas_section:flag,blocks:[ordinary,overseas]});
    assert.deepEqual(Array.from(data.blocks,b=>b.key),['stars']);
    assert.equal(data.apps().some(a=>a.id===274),false);
  }
  const foreign=DiscoveryCollections.fromJson({show_overseas_section:true,blocks:[ordinary,overseas]});
  assert.equal(foreign.showOverseasSection,true);
  assert.equal(foreign.block('overseas').entries[0].app.overseas,true);
  const domestic=DiscoveryCollections.fromJson({show_overseas_section:false,blocks:[ordinary]});
  assert.equal(domestic.block('overseas').entries.length,0);
});

test('overseas pagination and shelf rehydration preserve the same identity and marker',()=>{
  const data=DiscoveryCollections.fromJson({show_overseas_section:true,blocks:[{key:'overseas',page:2,page_size:24,total:30,
    items:[{id:274,distribution_region:'overseas',latest_asset:{name:'HGhub.hap',bundle_name:'io.example.hghub',version_code:1}}]}]});
  const block=data.block('overseas');
  assert.equal(block.page,2);assert.equal(block.total,30);
  assert.equal(block.entries[0].app.latestAsset.bundleName,'io.example.hghub');
  assert.equal(data.apps()[0].overseas,true);
});
