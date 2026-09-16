// A fake nodejs.org/dist/<version>/ for the remote provisioning test.
//
// check-remote-node.ps1 extracts the bash the launcher runs on a host and runs it
// against this, so the checksum verification is exercised for real: a matching
// tarball must install, a tampered one must not, and one the checksum list does
// not mention must not either.
//
// Without a local server the only way to test any of that is to tamper with a
// real download from nodejs.org - which is not a test, it is an incident.
const http = require('http');
const fs = require('fs');
const path = require('path');

const root = process.argv[2];
if (!root) { console.error('usage: fake-nodejs-server.js <dir>'); process.exit(2); }

const server = http.createServer((req, res) => {
  // Only the two files the provisioning script asks for, by exact name.
  const name = path.basename(decodeURIComponent(req.url.split('?')[0]));
  if (!/^(node-v[\d.]+-linux-[a-z0-9_]+\.tar\.xz|SHASUMS256\.txt)$/.test(name)) {
    res.writeHead(404); res.end('not found'); return;
  }
  const file = path.join(root, name);
  if (!fs.existsSync(file)) { res.writeHead(404); res.end('not found'); return; }
  res.writeHead(200, { 'Content-Type': 'application/octet-stream', 'Content-Length': fs.statSync(file).size });
  const stream = fs.createReadStream(file);
  // The script aborts with `set -e` as soon as a mismatch is seen, which closes
  // the connection mid-body. An unhandled stream error would take the server
  // down and turn a passing test into a confusing failure.
  stream.on('error', () => { try { res.destroy(); } catch (_) {} });
  res.on('close', () => { try { stream.destroy(); } catch (_) {} });
  stream.pipe(res);
});

server.listen(0, '127.0.0.1', () => {
  console.log('LISTENING ' + server.address().port);
});
