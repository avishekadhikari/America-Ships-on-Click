'use strict';

/**
 * Render (and other hosts) often run `npm start` with no build step.
 * dist/server.cjs is not in git — produce it if the host skipped `npm run build`.
 */
const fs = require('fs');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const root = path.join(__dirname, '..');
const server = path.join(root, 'dist', 'server.cjs');

if (!fs.existsSync(server)) {
  console.log('[START] dist/server.cjs missing — running npm run build');
  const built = spawnSync('npm', ['run', 'build'], {
    cwd: root,
    stdio: 'inherit',
    env: process.env,
    shell: true
  });
  if (built.status !== 0) {
    process.exit(built.status ?? 1);
  }
}

const child = spawn(process.execPath, [server], {
  cwd: root,
  stdio: 'inherit',
  env: process.env
});

function forward(signal) {
  if (!child.killed) child.kill(signal);
}

process.on('SIGINT', () => forward('SIGINT'));
process.on('SIGTERM', () => forward('SIGTERM'));

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
});
