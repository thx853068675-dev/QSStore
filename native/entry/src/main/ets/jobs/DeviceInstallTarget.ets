import { I18n } from '../data/I18n';
export class DeviceInstallTarget {
  /** Set from the system device type before target preferences are restored. */
  static localKind:string='phone';
  static localModel:string='';
  static localMarketName:string='';
  key: string = 'local';
  name: string = I18n.t('本机');
  kind: string = DeviceInstallTarget.localKind;
  host: string = '';
  port: number = 0;
  udid: string = '';
  model:string=DeviceInstallTarget.localModel;
  marketName:string=DeviceInstallTarget.localMarketName;

  static displayFact(value:Object|undefined):string {
    return typeof value==='string'&&value.length<=120&&!/[\u0000-\u001f]/.test(value)?value.trim():'';
  }

  static privateHost(host: string): boolean {
    const parts = host.split('.');
    if (parts.length !== 4 || parts.some((part: string) => !/^(0|[1-9]\d{0,2})$/.test(part) || Number(part) > 255)) return false;
    const numbers = parts.map((part: string) => Number(part));
    return (numbers[0] === 10 || (numbers[0] === 172 && numbers[1] >= 16 && numbers[1] <= 31) ||
      (numbers[0] === 192 && numbers[1] === 168)) && numbers[3] > 0 && numbers[3] < 255;
  }
  static validPort(port: number): boolean { return Number.isInteger(port) && port >= 10000 && port <= 65535; }
  static kind(value: string): string {
    const type = value.trim().toLowerCase();
    if (type === 'phone') return 'phone';
    if (type === 'tablet') return 'tablet';
    if (type === 'pc' || type === '2in1') return 'pc';
    return '';
  }
  static parse(value: string): DeviceInstallTarget {
    if (!value) return new DeviceInstallTarget();
    const row = JSON.parse(value) as DeviceInstallTarget;
    if (!DeviceInstallTarget.privateHost(row.host) || !DeviceInstallTarget.validPort(row.port) ||
      !/^[0-9a-fA-F]{40,128}$/.test(row.udid) || !['phone', 'tablet', 'pc'].includes(row.kind) ||
      row.key !== row.udid.toLowerCase() || !row.name || row.name.length > 80 || /[\r\n]/.test(row.name)) {
      throw new Error(I18n.t('目标设备记录无效，请重新连接'));
    }
    // Art metadata is optional; older records remain usable and invalid art never breaks installation.
    row.model=DeviceInstallTarget.displayFact(row.model);
    row.marketName=DeviceInstallTarget.displayFact(row.marketName)||row.name;
    return row;
  }
  static selectedSnapshot(): string { return DeviceInstallTarget.snapshotProvider(); }
  static snapshotProvider: () => string = () => '';
  static snapshot(row: DeviceInstallTarget): string {
    if (row.key === 'local') return '';
    const text = JSON.stringify(row);
    DeviceInstallTarget.parse(text);
    return text;
  }
  static endpoint(row: DeviceInstallTarget): string { return row.host + ':' + row.port; }
}
