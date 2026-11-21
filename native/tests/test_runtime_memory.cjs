const {test}=require('node:test');
const assert=require('node:assert/strict');
const {loadEts}=require('./load_ets.cjs');
const {IconResidency}=loadEts('data/IconResidency');
test('hundreds of visited icons retain only visible cells plus the bounded reverse-scroll window',()=>{
 const pool=new IconResidency(20),keys=Array.from({length:500},(_,i)=>'catalog:'+i);
 for(const key of keys){pool.visible(key,true);pool.visible(key,false);}
 for(const key of keys.slice(0,8))pool.visible(key,true);
 const keep=pool.keep(keys);assert.equal(keep.size,28);for(const key of keys.slice(0,8))assert(keep.has(key));
 for(const key of keys.slice(-20))assert(keep.has(key));
 assert.equal(pool.keep(keys,true).size,8);
});
test('duplicate shelf cells independently pin one bitmap until their final owner leaves',()=>{
 const pool=new IconResidency(0);pool.visible('one',true);pool.visible('one',true);
 pool.visible('one',false);assert(pool.wanted('one'));assert(pool.keep(['one']).has('one'));
 pool.visible('one',false);assert(!pool.wanted('one'));assert.equal(pool.keep(['one']).size,0);
 pool.visible('one',false);assert(!pool.wanted('one'));
});
test('pressure does not evict currently displayed or navigation-borrowed images',()=>{
 const pool=new IconResidency();pool.visible('active',true);pool.visible('old',true);pool.visible('old',false);
 assert.deepEqual(Array.from(pool.keep(['active','old'],true)),['active']);
});
