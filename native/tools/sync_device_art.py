#!/usr/bin/env python3
"""Refresh Huawei's public phone/tablet/computer product artwork index.
No device identifier is sent. Product images stay remote and are cached on demand.
"""
import argparse, html.parser, json, pathlib, urllib.request
SOURCE='https://consumer.huawei.com/cn/support/product/'
CATEGORIES={'smart-phone':'phone','tablet':'tablet','mate-book':'pc'}
class Catalog(html.parser.HTMLParser):
 def __init__(self):super().__init__();self.items=[]
 def handle_starttag(self,tag,attrs):
  attrs=dict(attrs);kind=CATEGORIES.get(attrs.get('id'))
  if not kind or 'json' not in attrs:return
  data=json.loads(attrs['json'])
  for series in data.values():
   for group in series:
    for item in group.get('items',[]):
     name=item.get('productName','').strip();image=item.get('productImage','')
     if image.startswith('/content/dam/huawei-cbg-site/') and image.lower().endswith('.png') and name:
      self.items.append({'name':name,'kind':kind,'image':'https://consumer.huawei.com'+image})
def main():
 p=argparse.ArgumentParser();p.add_argument('--source',type=pathlib.Path);a=p.parse_args()
 text=a.source.read_text() if a.source else urllib.request.urlopen(SOURCE,timeout=20).read().decode()
 parser=Catalog();parser.feed(text)
 rows=list({(r['name'],r['kind']):r for r in parser.items}.values())
 if len(rows)<100:raise RuntimeError('Incomplete official catalogue; refusing to replace')
 out=pathlib.Path(__file__).resolve().parents[1]/'entry/src/main/resources/rawfile/device-art/catalog.json'
 out.parent.mkdir(parents=True,exist_ok=True)
 out.write_text(json.dumps({'source':SOURCE,'products':rows},ensure_ascii=False,separators=(',',':'))+'\n')
 print(len(rows),'products;',out.stat().st_size,'bytes;',out)
if __name__=='__main__':main()
