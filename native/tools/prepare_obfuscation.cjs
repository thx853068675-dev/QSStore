/* Preserve names at external boundaries without keeping implementation classes.
 * Use the same ArkTS parser as the compiler; regex cannot reliably parse ETS.
 * All instance data fields are stable across upgrades (including non-exported
 * DTOs). Core classes, methods, locals, parameters and non-route paths obfuscate.
 */
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');

function loadParser() {
  const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
  return require(path.join(sdkRoot, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
}

function parserOptions() {
  const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
  const loader = path.join(sdkRoot, 'default/openharmony/ets/build-tools/ets-loader');
  const options = JSON.parse(fs.readFileSync(path.join(loader, 'tsconfig.json'), 'utf8')).compilerOptions;
  options.noTransformedKitInParser = true;
  options.ets.components = fs.readdirSync(path.join(loader, 'components')).filter(name => name.endsWith('.json'))
    .map(name => JSON.parse(fs.readFileSync(path.join(loader, 'components', name), 'utf8')).name).filter(Boolean);
  // The project also uses these Huawei navigation containers with ArkUI blocks.
  options.ets.components.push('HdsNavigation', 'HdsTabs');
  return options;
}

function collectContracts(ts, text, filename, names = new Set()) {
  const kind = filename.endsWith('.ets') ? ts.ScriptKind.ETS : ts.ScriptKind.TS;
  const options = parserOptions();
  const source = ts.createSourceFile(filename, text, ts.ScriptTarget.Latest, true, kind, options);
  if (source.parseDiagnostics.length) {
    throw new Error(`Cannot analyze obfuscation contracts in ${filename}: ` +
      source.parseDiagnostics.map(d => ts.flattenDiagnosticMessageText(d.messageText, ' ')).join('; '));
  }
  const add = node => {
    if (node && (ts.isIdentifier(node) || ts.isStringLiteral(node))) names.add(node.text);
  };
  const visit = node => {
    // JSON.stringify does not know ArkGuard's mapping. Keep legacy and future
    // serialized fields, including local DTOs and shorthand object properties.
    if (ts.isPropertyAssignment(node) || ts.isShorthandPropertyAssignment(node) ||
        ts.isPropertySignature(node) || ts.isMethodSignature(node)) add(node.name);
    if (ts.isPropertyDeclaration(node) &&
        !node.modifiers?.some(m => m.kind === ts.SyntaxKind.StaticKeyword)) add(node.name);
    if (ts.isMethodDeclaration(node) &&
        node.modifiers?.some(m => m.kind === ts.SyntaxKind.AbstractKeyword)) add(node.name);
    // Reflective string access, @Watch, defineProperty and string UI callbacks.
    if (ts.isElementAccessExpression(node) && ts.isStringLiteral(node.argumentExpression)) add(node.argumentExpression);
    if (ts.isDecorator(node) && ts.isCallExpression(node.expression) &&
        ts.isIdentifier(node.expression.expression) && node.expression.expression.text === 'Watch') {
      node.expression.arguments.forEach(add);
    }
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
        ['defineProperty', 'getOwnPropertyDescriptor'].includes(node.expression.name.text)) add(node.arguments[1]);
    ts.forEachChild(node, visit);
  };
  visit(source);
  return names;
}

function walk(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const filename = path.join(directory, entry.name);
    return entry.isDirectory() ? walk(filename) : /\.(ets|ts)$/.test(filename) ? [filename] : [];
  });
}

function prepare(project = root) {
  const ts = loadParser();
  const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
  const json5 = require(path.join(sdkRoot, 'default/openharmony/ets/build-tools/ets-loader/node_modules/json5'));
  const entry = path.join(project, 'entry');
  const names = new Set(['onCreate', 'onNewWant', 'onWindowStageCreate', 'onForeground',
    'onBackground', 'onWindowStageDestroy', 'onDestroy', 'onConfigurationUpdate', 'onMeasureSize', 'onPlaceChildren']);
  const sources = walk(path.join(entry, 'src/main/ets')).sort();
  for (const file of sources) collectContracts(ts, fs.readFileSync(file, 'utf8'), file, names);
  const napiFile = path.join(entry, 'src/main/cpp/types/libhap_core/index.d.ts');
  const napiText = fs.readFileSync(napiFile, 'utf8');
  collectContracts(ts, napiText, napiFile, names);
  const globals = new Set();
  const napiSource = ts.createSourceFile(napiFile, napiText, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  for (const statement of napiSource.statements) {
    if (ts.isVariableStatement(statement)) {
      for (const variable of statement.declarationList.declarations) {
        if (ts.isIdentifier(variable.name)) { globals.add(variable.name.text); names.add(variable.name.text); }
      }
    }
    if (ts.isFunctionDeclaration(statement) && statement.name) {
      globals.add(statement.name.text); names.add(statement.name.text);
    }
  }
  const module = json5.parse(fs.readFileSync(path.join(entry, 'src/main/module.json5'), 'utf8'));
  const pages = JSON.parse(fs.readFileSync(path.join(entry, 'src/main/resources/base/profile/main_pages.json'), 'utf8'));
  const filenames = new Set(['entry', 'libhap_core']);
  const paths = [module.module.srcEntry,
    ...(module.module.abilities || []).map(ability => ability.srcEntry),
    ...(module.module.extensionAbilities || []).map(ability => ability.srcEntry), ...pages.src];
  for (const filename of paths.filter(Boolean)) {
    for (const segment of filename.replace(/\.(ets|ts|js)$/, '').split('/')) {
      if (segment && segment !== '.') filenames.add(segment);
    }
  }
  const content = '# Generated by tools/prepare_obfuscation.cjs. Regenerate before every release.\n' +
    '# Stable JSON, persisted DTO, reflective callback and route contracts.\n' +
    '-keep-property-name\n' + [...names].sort().join('\n') + '\n\n' +
    '-keep-global-name\n' + [...globals].sort().join('\n') + '\n\n' +
    '-keep-file-name\n' + [...filenames].sort().join('\n') + '\n';
  const target = path.join(entry, 'obfuscation-contracts.txt');
  if (!fs.existsSync(target) || fs.readFileSync(target, 'utf8') !== content) fs.writeFileSync(target, content);
  return { files: sources.length, properties: names.size, routeSegments: filenames.size };
}

module.exports = { collectContracts, loadParser, prepare };
if (require.main === module) process.stdout.write(JSON.stringify(prepare()) + '\n');
