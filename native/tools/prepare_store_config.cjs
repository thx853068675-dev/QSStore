/** Inject local deployment configuration; never print addresses or TLS material. */
const fs = require('node:fs');
const path = require('node:path');

function endpoint(value, configFile) {
  let url;
  try { url = new URL(value.baseUrl); }
  catch (_) { throw Error('Store configuration contains an invalid HTTPS origin'); }
  if (url.protocol !== 'https:' || url.username || url.password || url.search || url.hash ||
      url.pathname !== '/') throw Error('Store configuration requires an HTTPS origin without credentials');
  if (!/^[A-Za-z0-9+/]{43}=$/.test(value.publicKeySha256 || '')) {
    throw Error('Store configuration requires a base64 SHA-256 public-key pin');
  }
  if (typeof value.caFile !== 'string' || !value.caFile) throw Error('Store configuration requires a CA file');
  const caData = fs.readFileSync(path.resolve(path.dirname(configFile), value.caFile), 'utf8');
  if (!caData.includes('-----BEGIN CERTIFICATE-----') || /PRIVATE KEY/.test(caData)) {
    throw Error('Store CA file must contain only public certificates');
  }
  return { baseUrl: url.origin, publicKeySha256: value.publicKeySha256, caData };
}

function configuration(configFile) {
  const directOnly = { overseasBaseUrl: '', overseasPublicKeySha256: '', overseasCaData: '' };
  if (!fs.existsSync(configFile)) return {
    configured: false, baseUrl: 'https://store.example.invalid', publicKeySha256: '', caData: '', ...directOnly
  };
  let value;
  try { value = JSON.parse(fs.readFileSync(configFile, 'utf8')); }
  catch (_) { throw Error('Unable to read local store configuration'); }
  if (value.fallbacks !== undefined && (!Array.isArray(value.fallbacks) || value.fallbacks.length !== 0)) {
    throw Error('Store configuration no longer accepts fallback endpoints; use the explicit overseas endpoint');
  }
  const primary = endpoint(value, configFile);
  if (value.overseas === undefined) return { configured: true, ...primary, ...directOnly };
  const overseas = endpoint(value.overseas, configFile);
  if (overseas.baseUrl === primary.baseUrl) throw Error('The overseas origin must differ from the primary origin');
  return { configured: true, ...primary, overseasBaseUrl: overseas.baseUrl,
    overseasPublicKeySha256: overseas.publicKeySha256, overseasCaData: overseas.caData };
}

function prepare(root = path.resolve(__dirname, '..'), env = process.env) {
  const configFile = env.QINGQI_STORE_CONFIG ? path.resolve(env.QINGQI_STORE_CONFIG) : path.join(root, 'store.local.json');
  if (env.QINGQI_STORE_CONFIG && !fs.existsSync(configFile)) throw Error('Configured store configuration file does not exist');
  const config = configuration(configFile);
  const source = '// Generated from local configuration. Never commit this file.\nexport class StoreBuildConfig {\n' +
    Object.entries(config).map(([key, value]) => '  static readonly ' + key + ': ' + typeof value + ' = ' + JSON.stringify(value) + ';').join('\n') + '\n}\n';
  const output = path.join(root, 'entry/src/main/ets/data/StoreBuildConfig.ets');
  fs.mkdirSync(path.dirname(output), { recursive: true });
  if (!fs.existsSync(output) || fs.readFileSync(output, 'utf8') !== source) fs.writeFileSync(output, source, { mode: 0o600 });
  return config.configured;
}

if (require.main === module) prepare();
module.exports = { configuration, prepare };
