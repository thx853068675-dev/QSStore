import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { execFileSync } from 'node:child_process';
import { join } from 'node:path';

// Cover IDE/direct Hvigor builds as well as the formal artifact script.
execFileSync(process.execPath, [join(__dirname, 'tools/prepare_store_config.cjs')]);
execFileSync(process.execPath, [join(__dirname, 'tools/prepare_acl_policy.cjs')]);
execFileSync(process.execPath, [join(__dirname, 'tools/prepare_obfuscation.cjs')]);

export default {
  system: appTasks,
  plugins: []
}
