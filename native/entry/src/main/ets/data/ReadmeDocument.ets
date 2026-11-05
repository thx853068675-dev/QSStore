import { Palette } from '../theme/Palette';

/** No scripts, embedded frames, forms or local files are needed for repository documentation. */
export class ReadmeDocument {
  static build(body: string, dark: boolean): string {
    const p = Palette.forMode(dark);
    return '<!doctype html><html><head><meta charset="UTF-8">' +
      '<meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; ' +
      'img-src https:; style-src \'unsafe-inline\'; base-uri \'none\'; form-action \'none\'">' +
      '<style>html,body{margin:0;padding:0;background:transparent;color:' + p.textBody +
      ';font:14px/1.75 sans-serif;overflow-wrap:anywhere}*{box-sizing:border-box}' +
      'p,ul,ol,pre,blockquote,table,details{margin:0 0 16px}h1,h2,h3,h4,h5,h6{color:' + p.text +
      ';line-height:1.4;margin:22px 0 12px}h1{font-size:23px}h2{font-size:20px}h3{font-size:17px}' +
      'h4,h5,h6{font-size:15px}body>:first-child{margin-top:0}body>:last-child{margin-bottom:0}' +
      'a{color:' + p.accent + ';text-decoration:none}img{max-width:100%;height:auto;vertical-align:middle}' +
      'ul,ol{padding-left:24px}li>p{margin-bottom:8px}code,kbd,pre{font-family:monospace;font-size:12px}' +
      'code,kbd{padding:2px 4px;border-radius:4px;background:' + p.fill + '}' +
      'pre{padding:12px;border-radius:10px;background:' + p.fill + ';overflow:auto;white-space:pre}' +
      'pre code{padding:0;background:transparent}blockquote{margin-left:0;padding-left:12px;border-left:3px solid ' +
      p.border + ';color:' + p.textSecondary + '}table{display:block;overflow-x:auto;border-collapse:collapse;' +
      'max-width:100%}th,td{padding:7px 10px;border:1px solid ' + p.border + '}th{background:' + p.fill +
      '}hr{height:1px;border:0;background:' + p.border + ';margin:18px 0}summary{cursor:pointer}' +
      'input{pointer-events:none}</style></head><body>' + body + '</body></html>';
  }
}
