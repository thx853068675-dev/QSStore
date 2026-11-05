import { HapAsset } from './ReleaseInfo';
import { I18n } from './I18n';

/** Display only the device types declared by the selected package. */
export class DeviceSupportDisplay {
  static normalize(types: Object | undefined): string[] {
    return HapAsset.normalizeDeviceTypes(types);
  }

  static labels(types: string[]): string[] {
    return DeviceSupportDisplay.normalize(types).map((type: string) => {
      switch (type) {
        case 'phone': return I18n.t('手机');
        case 'tablet': return I18n.t('平板');
        case '2in1': return I18n.t('电脑');
        case 'wearable': return I18n.t('穿戴');
        case 'tv': return I18n.t('电视');
        case 'car': return I18n.t('车机');
        case 'default': return I18n.t('默认');
        default: return type;
      }
    });
  }

  /** An unspecified system type cannot establish compatibility or incompatibility. */
  static matches(types: string[], currentDeviceType: string): boolean | undefined {
    const declared = DeviceSupportDisplay.normalize(types);
    const current = DeviceSupportDisplay.normalize([currentDeviceType])[0]?.toLowerCase() ?? '';
    if (!declared.length || !current || current === 'default') return undefined;
    if (declared.some((type: string) => type.toLowerCase() === current)) return true;
    if (!DeviceSupportDisplay.official(current)) return undefined;
    return false;
  }

  private static official(type: string): boolean {
    // API 26 deviceInfo.DeviceTypes; "default" is not a wildcard or an alias of "phone".
    return ['default', 'phone', 'tablet', '2in1', 'wearable', 'tv', 'car'].includes(type);
  }
}
