import { util } from '@kit.ArkTS';
import { BundleReferences } from './BundleReferences';

class ResourceValue { pointer: number = 0; offset: number = 0; }
/** RestoolV2 and compact Restool 6 indexes. Append replacement values rather than relocating unrelated records. */
export class ResourceIndex {
  private data: Uint8Array;
  private view: DataView;
  constructor(bytes: Uint8Array) {
    this.data = bytes; this.view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    if (bytes.length < 140 || bytes.length > 4 * 1024 * 1024 || this.u32(128) !== bytes.length) throw new Error('资源索引无效或过大');
  }
  private u32(at: number): number {
    if (at < 0 || at + 4 > this.data.length) throw new Error('资源索引越界');
    return this.view.getUint32(at, true);
  }
  private tag(at: number, tag: string): boolean {
    return at >= 0 && at + tag.length <= this.data.length &&
      tag.split('').every((char: string, index: number) => this.data[at + index] === char.charCodeAt(0));
  }
  private values(id: number): ResourceValue[] {
    const result: ResourceValue[] = []; const keys = this.u32(132);
    if (keys > 256) throw new Error('资源配置超限');
    if (this.tag(0, 'Restool 6.')) {
      let at = 136;
      for (let k = 0; k < keys; k++) {
        if (!this.tag(at, 'KEYS') || this.u32(at + 8) > 64) throw new Error('资源配置无效');
        const section = this.u32(at + 4); at += 12 + this.u32(at + 8) * 8;
        if (!this.tag(section, 'IDSS')) throw new Error('资源表无效');
        const count = this.u32(section + 4); if (count > 10000) throw new Error('资源数量超限');
        for (let n = 0; n < count; n++) {
          const pointer = section + 12 + n * 8;
          if (this.u32(pointer - 4) !== id) continue;
          const record = this.u32(pointer);
          if (this.u32(record + 8) !== id) throw new Error('资源记录不匹配');
          const value = new ResourceValue(); value.pointer = pointer; value.offset = record; result.push(value);
        }
      }
      return result;
    }
    if (!this.tag(0, 'RestoolV2')) throw new Error('暂不支持此资源索引格式');
    let at = 140;
    for (let k = 0; k < keys; k++) {
      if (!this.tag(at, 'KEYS') || this.u32(at + 8) > 64) throw new Error('资源配置无效');
      at += 12 + this.u32(at + 8) * 8;
    }
    if (!this.tag(at, 'IDSS')) throw new Error('资源表无效');
    const types = this.u32(at + 8); if (types > 256) throw new Error('资源类型超限'); at += 16;
    for (let t = 0; t < types; t++) {
      const count = this.u32(at + 8); if (count > 10000) throw new Error('资源数量超限'); at += 12;
      for (let n = 0; n < count; n++) {
        const rid = this.u32(at), record = this.u32(at + 4), length = this.u32(at + 8); at += 12 + length;
        if (at > this.data.length) throw new Error('资源表越界');
        if (rid !== id) continue;
        if (this.u32(record) !== id || this.u32(record + 8) > 256) throw new Error('资源记录无效');
        for (let c = 0; c < this.u32(record + 8); c++) {
          const value = new ResourceValue(); value.pointer = record + 16 + c * 8; value.offset = this.u32(value.pointer); result.push(value);
        }
      }
    }
    return result;
  }
  private text(row: ResourceValue): string {
    const offset = this.tag(0, 'Restool 6.') ? row.offset + 12 : row.offset;
    if (offset + 2 > this.data.length) throw new Error('资源内容越界');
    const length = this.view.getUint16(offset, true);
    if (length > 65535 || offset + 2 + length > this.data.length) throw new Error('资源内容越界');
    return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(this.data.slice(offset + 2, offset + 2 + length)).replace(/\0+$/, '');
  }
  value(id: number): string {
    const row = this.values(id)[0]; return row ? this.text(row) : '';
  }
  private ids(): number[] {
    const ids = new Set<number>(); const keys = this.u32(132); let at = this.tag(0,'Restool 6.') ? 136 : 140;
    if(keys>256)throw new Error('资源配置超限');
    for(let k=0;k<keys;k++) {
      if(!this.tag(at,'KEYS') || this.u32(at+8)>64)throw new Error('资源配置无效');
      if(this.tag(0,'Restool 6.')) {
        const section=this.u32(at+4),count=this.u32(section+4);if(!this.tag(section,'IDSS')||count>10000)throw new Error('资源表无效');
        for(let n=0;n<count;n++)ids.add(this.u32(section+8+n*8));
      }
      at+=12+this.u32(at+8)*8;
    }
    if(!this.tag(0,'Restool 6.')) {
      if(!this.tag(0,'RestoolV2')||!this.tag(at,'IDSS'))throw new Error('资源表无效');
      const types=this.u32(at+8);if(types>256)throw new Error('资源类型超限');at+=16;
      for(let t=0;t<types;t++) {
        const count=this.u32(at+8);if(count>10000)throw new Error('资源数量超限');at+=12;
        for(let n=0;n<count;n++){ids.add(this.u32(at));at+=12+this.u32(at+8);if(at>this.data.length)throw new Error('资源表越界');}
      }
    }
    return Array.from(ids);
  }
  replace(values: Map<number, string>, previous: string = '', next: string = ''): Uint8Array {
    const original = this.data; const chunks: Uint8Array[] = []; let size = original.length;
    const patches: ResourceValue[] = []; const addresses: number[] = [];
    const compact = this.tag(0, 'Restool 6.');
    const ids=new Set<number>(values.keys());if(previous)for(const id of this.ids())ids.add(id);
    ids.forEach((id: number) => {
      const rows = this.values(id); if (!rows.length) throw new Error('安装包缺少可编辑资源：' + id);
      for (const row of rows) {
        const text=values.get(id) ?? BundleReferences.text(this.text(row),previous,next);
        if(!values.has(id)&&text===this.text(row))continue;
        const encoded = new util.TextEncoder().encodeInto(text);
        if (!text || encoded.length > 4096 || text.includes('\0')) throw new Error('资源内容无效');
        let bytes: Uint8Array;
        if (compact) {
          const total = this.u32(row.offset) + 4;
          if (total < 16 || row.offset + total > original.length) throw new Error('资源记录长度无效');
          const oldLength = this.view.getUint16(row.offset + 12, true), tail = row.offset + 14 + oldLength;
          if (tail > row.offset + total) throw new Error('资源记录内容无效');
          bytes = new Uint8Array(14 + encoded.length + 1 + row.offset + total - tail);
          bytes.set(original.slice(row.offset, row.offset + 12)); bytes.set(encoded, 14);
          bytes.set(original.slice(tail, row.offset + total), 15 + encoded.length);
          const view = new DataView(bytes.buffer); view.setUint32(0, bytes.length - 4, true); view.setUint16(12, encoded.length + 1, true);
        } else {
          bytes = new Uint8Array(encoded.length + 2); new DataView(bytes.buffer).setUint16(0, encoded.length, true); bytes.set(encoded, 2);
        }
        patches.push(row); addresses.push(size); chunks.push(bytes); size += bytes.length;
      }
    });
    if (size > 4 * 1024 * 1024) throw new Error('编辑后的资源索引超限');
    const output = new Uint8Array(size); output.set(original); let at = original.length;
    chunks.forEach((chunk: Uint8Array) => { output.set(chunk, at); at += chunk.length; });
    const view = new DataView(output.buffer); view.setUint32(128, output.length, true);
    patches.forEach((patch: ResourceValue, index: number) => view.setUint32(patch.pointer, addresses[index], true));
    return output;
  }
}
