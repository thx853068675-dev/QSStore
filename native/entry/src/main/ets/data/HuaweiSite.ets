export type HuaweiSite = 'CN' | 'SG' | 'DE' | 'RU';

export const HUAWEI_SITES: HuaweiSite[] = ['CN', 'SG', 'DE', 'RU'];

export function parseHuaweiSite(value: string): HuaweiSite | undefined {
  switch (value.trim().toUpperCase()) {
    case '1': case 'CN': return 'CN';
    case '5': case 'SG': return 'SG';
    case '7': case 'EU': case 'DE': return 'DE';
    case '8': case 'RU': return 'RU';
    default: return undefined;
  }
}

export function huaweiAuthBase(site?: HuaweiSite): string {
  switch (site) {
    case 'SG': return 'https://sg.devecostudio.huawei.com';
    case 'DE': return 'https://de.devecostudio.huawei.com';
    case 'RU': return 'https://ru.devecostudio.huawei.com';
    default: return 'https://cn.devecostudio.huawei.com';
  }
}

export function huaweiAgcBase(site?: HuaweiSite): string {
  switch (site) {
    case 'SG': return 'https://connect-api-dra.cloud.huawei.com/api';
    case 'DE': return 'https://connect-api-dre.cloud.huawei.com/api';
    case 'RU': return 'https://connect-api-drru.cloud.huawei.com/api';
    default: return 'https://connect-api.cloud.huawei.com/api';
  }
}

export function suggestedHuaweiSite(country: string): HuaweiSite {
  const region = country.trim().toUpperCase();
  if (region === 'CN' || !/^[A-Z]{2}$/.test(region)) return 'CN';
  if (region === 'RU') return 'RU';
  if (' AD AL AT BA BE BG BY CH CY CZ DE DK EE ES FI FR GB GR HR HU IE IS IT LI LT LU LV MC MD ME MK MT NL NO PL PT RO RS SE SI SK SM TR UA VA '
    .includes(' ' + region + ' ')) return 'DE';
  return 'SG';
}

export function loginParameter(form: string, name: string): string {
  for (const part of form.split('&')) {
    const index = part.indexOf('=');
    if (index >= 0 && part.substring(0, index) === name) return decodeURIComponent(part.substring(index + 1));
  }
  return '';
}
