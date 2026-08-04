import express from 'express';
import path from 'path';
import fs from 'fs';
import { createServer as createViteServer } from 'vite';
import { initDb } from './src/db';
import { apiRouter } from './src/server/routes';

async function startServer() {
  const app = express();
  const PORT = 3000;

  // Body parsing middleware
  app.use(express.json());
  app.use(express.urlencoded({ extended: true }));

  // Initialize DB & Seed
  await initDb();

  // Serve static uploaded documents
  const uploadsPath = path.join(process.cwd(), 'uploads');
  if (!fs.existsSync(uploadsPath)) {
    fs.mkdirSync(uploadsPath, { recursive: true });
  }
  app.use('/uploads', express.static(uploadsPath));

  // Health check
  app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', service: 'America Ships On Click API' });
  });

  // Mount API Routes FIRST
  app.use('/api', apiRouter);

  // Development vs Production static/Vite serving
  if (process.env.NODE_ENV !== 'production') {
    const vite = await createViteServer({
      server: { middlewareMode: true },
      appType: 'spa'
    });
    app.use(vite.middlewares);
  } else {
    const distPath = path.join(process.cwd(), 'dist');
    app.use(express.static(distPath));
    app.get('*', (req, res) => {
      res.sendFile(path.join(distPath, 'index.html'));
    });
  }

  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[SERVER] America Ships On Click server running on http://0.0.0.0:${PORT}`);
  });
}

startServer().catch(err => {
  console.error('[SERVER] Fatal server error:', err);
});
