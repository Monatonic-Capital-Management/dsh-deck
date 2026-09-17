'use strict';
const fs = require('fs');
const path = require('path');
function readLauncherSource(root = path.resolve(__dirname, '..')) {
  const files = [path.join(root, 'dsh.ps1')];
  const directory = path.join(root, 'launcher');
  if (fs.existsSync(directory)) files.push(...fs.readdirSync(directory).filter(name => name.endsWith('.ps1')).sort().map(name => path.join(directory, name)));
  return files.map(file => fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n')).join('\n');
}
module.exports = { readLauncherSource };
