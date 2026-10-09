'use strict';
// Loads a QML `.pragma library` JS file for `node --test`. QML's JS engine treats
// `.pragma library` specially (module-scoped singleton state); plain V8 just needs
// that one line stripped before the source is otherwise valid ECMAScript. Every
// top-level `function name(...)` declaration is re-exported via `module.exports`, so
// tests can `require()` the same file the QML side loads with no separate build step.

const fs = require('node:fs');
const path = require('node:path');

function loadLib(relPath) {
  const full = path.join(__dirname, '..', '..', 'plugin', 'lib', relPath);
  const original = fs.readFileSync(full, 'utf8');
  const src = original.replace(/^\s*\.pragma\s+library\s*$/m, '');

  const names = [];
  const re = /^function\s+([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/gm;
  let m;
  while ((m = re.exec(src)) !== null) names.push(m[1]);

  // Built with `new Function(...)` (same realm as the caller, unlike vm.createContext,
  // which would make plain-object literals fail Node's cross-realm deepStrictEqual).
  const withExports = src + '\nmodule.exports = { ' + names.join(', ') + ' };\n';
  const factory = new Function('module', 'exports', withExports);
  const mod = { exports: {} };
  factory(mod, mod.exports);
  return mod.exports;
}

module.exports = { loadLib };
