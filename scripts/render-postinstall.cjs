'use strict';

/**
 * Render's native Node service installs packages during the build phase, then
 * expects `npm start` to bind $PORT within seconds. Compiling Vite+esbuild in
 * start gets SIGTERM ("No open ports detected"). Build here instead, only on
 * Render, so local `npm install` stays fast.
 */
if (process.env.RENDER !== 'true') {
  process.exit(0);
}

const { spawnSync } = require('child_process');

console.log('[postinstall] RENDER=true — running npm run build');
const built = spawnSync('npm', ['run', 'build'], {
  stdio: 'inherit',
  env: process.env,
  shell: true
});
process.exit(built.status ?? 1);
