import { Router, Response } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import multer from 'multer';
import path from 'path';
import fs from 'fs';
import { db } from '../db';
import { authenticate, generateToken, requireRole, AuthenticatedRequest } from './auth';

export const apiRouter = Router();

// Setup Multer for document upload storage
const uploadDir = path.join(process.cwd(), 'uploads');
if (!fs.existsSync(uploadDir)) {
  fs.mkdirSync(uploadDir, { recursive: true });
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, uploadDir),
  filename: (req, file, cb) => {
    const uniqueSuffix = Date.now() + '-' + Math.round(Math.random() * 1e9);
    const ext = path.extname(file.originalname) || '.png';
    cb(null, `${file.fieldname}-${uniqueSuffix}${ext}`);
  }
});
const upload = multer({ storage });

// Real-time SSE subscriber connections
const sseClients: Response[] = [];

export function broadcastSettlementEvent(data: any) {
  const payload = `data: ${JSON.stringify({ type: 'settlement_created', data })}\n\n`;
  sseClients.forEach(client => client.write(payload));
}

// -------------------------------------------------------------
// 1. CONFIG ENDPOINT - Authoritative Single Source of Truth for Fees
// -------------------------------------------------------------
apiRouter.get('/config', async (req, res) => {
  try {
    const rows = await db.query<{ key: string; value: string }>('SELECT key, value FROM platform_config');
    const configMap: Record<string, number> = {};
    rows.rows.forEach(r => {
      configMap[r.key] = parseFloat(r.value);
    });

    res.json({
      fee_pct: configMap['fee_pct'] ?? 0.05,
      factor_pct: configMap['factor_pct'] ?? 0.03,
      broker_comparison_pct: configMap['broker_comparison_pct'] ?? 0.20,
      fuel_rate_per_mile: configMap['fuel_rate_per_mile'] ?? 0.45
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// -------------------------------------------------------------
// 2. AUTH ENDPOINTS
// -------------------------------------------------------------
const signupSchema = z.object({
  email: z.string().email(),
  password: z.string().min(6),
  role: z.enum(['driver', 'shipper', 'admin']),
  phone: z.string().optional(),
  name: z.string().min(2),
  home_city: z.string().optional(),
  home_state: z.string().optional(),
  company_name: z.string().optional()
});

apiRouter.post('/auth/signup', async (req, res) => {
  try {
    const body = signupSchema.parse(req.body);
    const existing = await db.query('SELECT id FROM users WHERE email = $1', [body.email]);
    if (existing.rows.length > 0) {
      return res.status(400).json({ error: 'User with this email already exists' });
    }

    const userId = 'usr-' + Date.now() + '-' + Math.floor(Math.random() * 1000);
    const passwordHash = await bcrypt.hash(body.password, 10);

    await db.query(
      'INSERT INTO users (id, role, email, phone, password_hash) VALUES ($1, $2, $3, $4, $5)',
      [userId, body.role, body.email, body.phone || null, passwordHash]
    );

    let driverId: string | undefined;
    let shipperId: string | undefined;

    if (body.role === 'driver') {
      driverId = 'drv-' + Date.now();
      await db.query(`
        INSERT INTO driver_profiles (id, user_id, full_name, home_base_city, home_base_state, verification_status)
        VALUES ($1, $2, $3, $4, $5, 'verified')
      `, [driverId, userId, body.name, body.home_city || 'Dallas', body.home_state || 'TX']);

      await db.query(`
        INSERT INTO driver_equipment (id, driver_id, equipment_type, trailer_length_ft)
        VALUES ($1, $2, 'dry_van', 53)
      `, ['eq-' + driverId, driverId]);

      await db.query(`
        INSERT INTO driver_payment_accounts (id, driver_id, payment_processor, processor_account_id, same_day_funding_opt_in)
        VALUES ($1, $2, 'stripe_connect', $3, TRUE)
      `, ['pay-' + driverId, driverId, 'acct_token_' + Date.now()]);
    } else if (body.role === 'shipper') {
      shipperId = 'shp-' + Date.now();
      await db.query(`
        INSERT INTO shipper_profiles (id, user_id, company_name, billing_email)
        VALUES ($1, $2, $3, $4)
      `, [shipperId, userId, body.company_name || body.name, body.email]);
    }

    const token = generateToken({
      id: userId,
      email: body.email,
      role: body.role,
      driverId,
      shipperId
    });

    res.json({
      token,
      user: {
        id: userId,
        email: body.email,
        role: body.role,
        driverId,
        shipperId,
        name: body.name
      }
    });
  } catch (err: any) {
    res.status(400).json({ error: err.message });
  }
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string()
});

apiRouter.post('/auth/login', async (req, res) => {
  try {
    const { email, password } = loginSchema.parse(req.body);
    const userRes = await db.query<{
      id: string;
      role: 'driver' | 'shipper' | 'admin';
      email: string;
      password_hash: string;
    }>('SELECT * FROM users WHERE email = $1', [email]);

    if (userRes.rows.length === 0) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    const user = userRes.rows[0];
    const match = await bcrypt.compare(password, user.password_hash);
    if (!match) {
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    let driverId: string | undefined;
    let shipperId: string | undefined;

    if (user.role === 'driver') {
      const drv = await db.query<{ id: string }>('SELECT id FROM driver_profiles WHERE user_id = $1', [user.id]);
      driverId = drv.rows[0]?.id;
    } else if (user.role === 'shipper') {
      const shp = await db.query<{ id: string }>('SELECT id FROM shipper_profiles WHERE user_id = $1', [user.id]);
      shipperId = shp.rows[0]?.id;
    }

    const token = generateToken({
      id: user.id,
      email: user.email,
      role: user.role,
      driverId,
      shipperId
    });

    res.json({
      token,
      user: {
        id: user.id,
        email: user.email,
        role: user.role,
        driverId,
        shipperId
      }
    });
  } catch (err: any) {
    res.status(400).json({ error: err.message });
  }
});

apiRouter.get('/auth/me', authenticate, async (req: AuthenticatedRequest, res) => {
  if (!req.user) return res.status(401).json({ error: 'Not authenticated' });

  let profileData: any = {};
  if (req.user.role === 'driver' && req.user.driverId) {
    const drv = await db.query('SELECT * FROM driver_profiles WHERE id = $1', [req.user.driverId]);
    profileData = drv.rows[0] || {};
  } else if (req.user.role === 'shipper' && req.user.shipperId) {
    const shp = await db.query('SELECT * FROM shipper_profiles WHERE id = $1', [req.user.shipperId]);
    profileData = shp.rows[0] || {};
  }

  res.json({
    user: req.user,
    profile: profileData
  });
});

// -------------------------------------------------------------
// 3. LOADS ENDPOINTS
// -------------------------------------------------------------
apiRouter.get('/loads', async (req, res) => {
  try {
    const { origin, destination, equipment, minRate, status = 'open', page = '1', limit = '50' } = req.query;

    let query = `
      SELECT l.*, s.company_name as shipper_name
      FROM loads l
      JOIN shipper_profiles s ON l.shipper_id = s.id
      WHERE 1=1
    `;
    const params: any[] = [];

    if (status && status !== 'all') {
      params.push(status);
      query += ` AND l.status = $${params.length}`;
    }

    if (origin) {
      params.push(`%${origin}%`);
      query += ` AND (LOWER(l.origin_city) LIKE LOWER($${params.length}) OR LOWER(l.origin_state) LIKE LOWER($${params.length}))`;
    }

    if (destination) {
      params.push(`%${destination}%`);
      query += ` AND (LOWER(l.dest_city) LIKE LOWER($${params.length}) OR LOWER(l.dest_state) LIKE LOWER($${params.length}))`;
    }

    if (equipment && equipment !== 'Any') {
      params.push(equipment);
      query += ` AND l.equipment_type = $${params.length}`;
    }

    if (minRate) {
      params.push(parseFloat(minRate as string));
      query += ` AND l.rate_per_mile >= $${params.length}`;
    }

    query += ` ORDER BY l.created_at DESC`;

    const offset = (parseInt(page as string, 10) - 1) * parseInt(limit as string, 10);
    params.push(parseInt(limit as string, 10));
    query += ` LIMIT $${params.length}`;
    params.push(offset);
    query += ` OFFSET $${params.length}`;

    const result = await db.query(query, params);
    res.json({ loads: result.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

apiRouter.get('/loads/:id', async (req, res) => {
  try {
    const result = await db.query('SELECT * FROM loads WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Load not found' });
    res.json(result.rows[0]);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

const createLoadSchema = z.object({
  origin_city: z.string().min(1),
  origin_state: z.string().length(2),
  dest_city: z.string().min(1),
  dest_state: z.string().length(2),
  miles: z.number().positive(),
  rate_per_mile: z.number().positive(),
  equipment_type: z.enum(['dry_van', 'reefer', 'flatbed', 'step_deck', 'power_only']),
  pickup_date: z.string(),
  weight_lbs: z.number().optional(),
  notes: z.string().optional(),
  same_day_funding_offered: z.boolean().default(false)
});

apiRouter.post('/loads', authenticate, requireRole('shipper', 'admin'), async (req: AuthenticatedRequest, res) => {
  try {
    const body = createLoadSchema.parse(req.body);
    let shipperId = req.user?.shipperId;

    if (!shipperId) {
      const shp = await db.query<{ id: string }>('SELECT id FROM shipper_profiles WHERE user_id = $1', [req.user?.id]);
      shipperId = shp.rows[0]?.id;
    }

    if (!shipperId) {
      return res.status(400).json({ error: 'Shipper profile not found. Please complete shipper setup.' });
    }

    const loadId = 'LD-' + (1050 + Math.floor(Math.random() * 9000));
    await db.query(`
      INSERT INTO loads (
        id, shipper_id, origin_city, origin_state, dest_city, dest_state, miles, rate_per_mile,
        equipment_type, pickup_date, weight_lbs, notes, same_day_funding_offered, status
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, 'open')
    `, [
      loadId, shipperId, body.origin_city, body.origin_state, body.dest_city, body.dest_state,
      body.miles, body.rate_per_mile, body.equipment_type, body.pickup_date,
      body.weight_lbs || null, body.notes || null, body.same_day_funding_offered
    ]);

    const created = await db.query('SELECT * FROM loads WHERE id = $1', [loadId]);
    res.status(201).json(created.rows[0]);
  } catch (err: any) {
    res.status(400).json({ error: err.message });
  }
});

// -------------------------------------------------------------
// 4. BOOKINGS ENDPOINTS (TRANSACTIONAL LOCKING TO PREVENT DOUBLE BOOKING)
// -------------------------------------------------------------
apiRouter.post('/bookings', authenticate, requireRole('driver', 'admin'), async (req: AuthenticatedRequest, res) => {
  try {
    const { load_id } = req.body;
    if (!load_id) return res.status(400).json({ error: 'load_id is required' });

    let driverId = req.user?.driverId;
    if (!driverId) {
      const drv = await db.query<{ id: string }>('SELECT id FROM driver_profiles WHERE user_id = $1', [req.user?.id]);
      driverId = drv.rows[0]?.id;
    }
    if (!driverId) return res.status(400).json({ error: 'Driver profile required to book load' });

    // Begin Transaction
    await db.query('BEGIN');

    const loadRes = await db.query<{ status: string; id: string }>('SELECT * FROM loads WHERE id = $1 FOR UPDATE', [load_id]);
    if (loadRes.rows.length === 0) {
      await db.query('ROLLBACK');
      return res.status(404).json({ error: 'Load not found' });
    }

    const load = loadRes.rows[0];
    if (load.status !== 'open') {
      await db.query('ROLLBACK');
      return res.status(409).json({ error: 'Conflict: This load has already been booked or is no longer open.' });
    }

    // Check existing booking
    const existingBk = await db.query('SELECT id FROM bookings WHERE load_id = $1 AND status != \'cancelled\'', [load_id]);
    if (existingBk.rows.length > 0) {
      await db.query('ROLLBACK');
      return res.status(409).json({ error: 'Conflict: Load is already booked' });
    }

    const bookingId = 'BK-' + Date.now();
    await db.query(`
      INSERT INTO bookings (id, load_id, driver_id, status)
      VALUES ($1, $2, $3, 'active')
    `, [bookingId, load_id, driverId]);

    await db.query(`UPDATE loads SET status = 'booked' WHERE id = $1`, [load_id]);

    await db.query('COMMIT');

    const booking = await db.query('SELECT * FROM bookings WHERE id = $1', [bookingId]);
    res.status(201).json(booking.rows[0]);
  } catch (err: any) {
    await db.query('ROLLBACK');
    res.status(500).json({ error: err.message });
  }
});

apiRouter.patch('/bookings/:id/pod', authenticate, async (req: AuthenticatedRequest, res) => {
  try {
    const { pod_url } = req.body;
    if (!pod_url) return res.status(400).json({ error: 'pod_url is required' });

    await db.query('UPDATE bookings SET pod_url = $1 WHERE id = $2', [pod_url, req.params.id]);
    const updated = await db.query('SELECT * FROM bookings WHERE id = $1', [req.params.id]);
    res.json(updated.rows[0]);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// Complete Booking -> Authoritative Server-Side Settlement Trigger!
apiRouter.patch('/bookings/:id/complete', authenticate, async (req: AuthenticatedRequest, res) => {
  try {
    await db.query('BEGIN');

    const bkRes = await db.query<any>('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [req.params.id]);
    if (bkRes.rows.length === 0) {
      await db.query('ROLLBACK');
      return res.status(404).json({ error: 'Booking not found' });
    }

    const booking = bkRes.rows[0];
    if (booking.status === 'completed') {
      await db.query('ROLLBACK');
      return res.status(400).json({ error: 'Booking already completed' });
    }

    const loadRes = await db.query<any>('SELECT * FROM loads WHERE id = $1', [booking.load_id]);
    const load = loadRes.rows[0];

    // Read platform config values
    const cfgRes = await db.query<{ key: string; value: string }>('SELECT key, value FROM platform_config');
    const cfg: Record<string, number> = {};
    cfgRes.rows.forEach(r => cfg[r.key] = parseFloat(r.value));

    const feePct = cfg['fee_pct'] ?? 0.05;
    const factorPct = cfg['factor_pct'] ?? 0.03;
    const fuelRate = cfg['fuel_rate_per_mile'] ?? 0.45;

    // Check if driver opted into same-day funding
    const drvPayRes = await db.query<any>('SELECT same_day_funding_opt_in FROM driver_payment_accounts WHERE driver_id = $1', [booking.driver_id]);
    const factored = drvPayRes.rows[0]?.same_day_funding_opt_in ?? load.same_day_funding_offered;

    // AUTHORITATIVE SETTLEMENT CALCULATIONS
    const miles = parseFloat(load.miles);
    const ratePerMile = parseFloat(load.rate_per_mile);
    const grossAmount = miles * ratePerMile;
    const feeAmount = grossAmount * feePct;
    const fuelCost = miles * fuelRate;
    const factorCost = factored ? grossAmount * factorPct : 0;
    const netAmount = grossAmount - feeAmount - fuelCost - factorCost;

    const settlementId = 'STL-' + String(Date.now()).slice(-5);
    const settledAt = new Date().toISOString();

    await db.query(`
      INSERT INTO settlements (
        id, booking_id, load_id, miles, rate_per_mile, fuel_rate_per_mile,
        gross_amount, fee_amount, fee_pct_applied, fuel_cost, factor_cost, factored, net_amount, settled_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
    `, [
      settlementId, booking.id, load.id, miles, ratePerMile, fuelRate,
      grossAmount, feeAmount, feePct, fuelCost, factorCost, factored, netAmount, settledAt
    ]);

    await db.query('UPDATE bookings SET status = \'completed\', delivered_at = $1 WHERE id = $2', [settledAt, booking.id]);
    await db.query('UPDATE loads SET status = \'delivered\' WHERE id = $1', [load.id]);

    await db.query('COMMIT');

    const settlementRes = await db.query<Record<string, any>>('SELECT * FROM settlements WHERE id = $1', [settlementId]);
    const settlement = settlementRes.rows[0] || {};

    // Broadcast SSE to live Open Books subscribers
    broadcastSettlementEvent({
      ...settlement,
      origin_city: load.origin_city,
      origin_state: load.origin_state,
      dest_city: load.dest_city,
      dest_state: load.dest_state,
      equipment_type: load.equipment_type
    });

    res.json({
      message: 'Settlement created and load completed',
      settlement
    });
  } catch (err: any) {
    await db.query('ROLLBACK');
    res.status(500).json({ error: err.message });
  }
});

// -------------------------------------------------------------
// 5. SETTLEMENTS ENDPOINTS (OPEN BOOKS PUBLIC LEDGER)
// -------------------------------------------------------------
apiRouter.get('/settlements', async (req, res) => {
  try {
    const { limit = '50', page = '1' } = req.query;
    const l = parseInt(limit as string, 10);
    const offset = (parseInt(page as string, 10) - 1) * l;

    const rows = await db.query('SELECT * FROM public_ledger_view LIMIT $1 OFFSET $2', [l, offset]);
    res.json({ settlements: rows.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

apiRouter.get('/settlements/aggregate', async (req, res) => {
  try {
    const rows = await db.query<Record<string, any>>('SELECT * FROM settlement_totals_view');
    const totals: Record<string, any> = rows.rows[0] || { count: 0, miles: 0, gross: 0, fee: 0, fuel: 0, factor: 0, net: 0 };
    res.json({
      count: parseInt(String(totals.count || '0'), 10),
      miles: parseFloat(String(totals.miles || '0')),
      gross: parseFloat(String(totals.gross || '0')),
      fee: parseFloat(String(totals.fee || '0')),
      fuel: parseFloat(String(totals.fuel || '0')),
      factor: parseFloat(String(totals.factor || '0')),
      net: parseFloat(String(totals.net || '0'))
    });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// -------------------------------------------------------------
// 6. DRIVER ONBOARDING & DOCUMENTS
// -------------------------------------------------------------
const driverOnboardSchema = z.object({
  full_name: z.string().min(2),
  phone: z.string(),
  email: z.string().email(),
  home_base_city: z.string(),
  home_base_state: z.string(),
  cdl_number: z.string().optional(),
  cdl_class: z.enum(['A', 'B']).optional(),
  dot_number: z.string().optional(),
  mc_number: z.string().optional(),
  equipment_type: z.enum(['dry_van', 'reefer', 'flatbed', 'step_deck', 'power_only']),
  trailer_length_ft: z.number().optional().default(53),
  routing_number: z.string().optional(),
  account_number: z.string().optional(),
  same_day_funding_opt_in: z.boolean().default(false)
});

apiRouter.post('/drivers/onboard', async (req, res) => {
  try {
    const body = driverOnboardSchema.parse(req.body);

    // Find or create user
    let userRes = await db.query<{ id: string }>('SELECT id FROM users WHERE email = $1', [body.email]);
    let userId: string;
    if (userRes.rows.length === 0) {
      userId = 'usr-' + Date.now();
      const hash = await bcrypt.hash('temp_driver_password_123', 10);
      await db.query(
        'INSERT INTO users (id, role, email, phone, password_hash) VALUES ($1, \'driver\', $2, $3, $4)',
        [userId, body.email, body.phone, hash]
      );
    } else {
      userId = userRes.rows[0].id;
    }

    // Upsert driver_profile
    let drvRes = await db.query<{ id: string }>('SELECT id FROM driver_profiles WHERE user_id = $1', [userId]);
    let driverId: string;

    if (drvRes.rows.length === 0) {
      driverId = 'drv-' + Date.now();
      await db.query(`
        INSERT INTO driver_profiles (id, user_id, full_name, home_base_city, home_base_state, cdl_number, cdl_class, dot_number, mc_number, verification_status)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending')
      `, [driverId, userId, body.full_name, body.home_base_city, body.home_base_state, body.cdl_number || null, body.cdl_class || 'A', body.dot_number || null, body.mc_number || null]);
    } else {
      driverId = drvRes.rows[0].id;
      await db.query(`
        UPDATE driver_profiles
        SET full_name = $1, home_base_city = $2, home_base_state = $3, cdl_number = $4, cdl_class = $5, dot_number = $6, mc_number = $7
        WHERE id = $8
      `, [body.full_name, body.home_base_city, body.home_base_state, body.cdl_number || null, body.cdl_class || 'A', body.dot_number || null, body.mc_number || null, driverId]);
    }

    // Upsert equipment
    await db.query(`
      INSERT INTO driver_equipment (id, driver_id, equipment_type, trailer_length_ft)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (id) DO UPDATE SET equipment_type = EXCLUDED.equipment_type, trailer_length_ft = EXCLUDED.trailer_length_ft
    `, ['eq-' + driverId, driverId, body.equipment_type, body.trailer_length_ft]);

    // Tokenize payment account (Never store raw routing/account numbers!)
    const tokenizedProcessorAcct = 'acct_stripe_connect_' + Buffer.from(`${body.routing_number}-${body.account_number}`).toString('base64').slice(0, 16);
    await db.query(`
      INSERT INTO driver_payment_accounts (id, driver_id, payment_processor, processor_account_id, same_day_funding_opt_in)
      VALUES ($1, $2, 'stripe_connect', $3, $4)
      ON CONFLICT (driver_id) DO UPDATE SET processor_account_id = EXCLUDED.processor_account_id, same_day_funding_opt_in = EXCLUDED.same_day_funding_opt_in
    `, ['pay-' + driverId, driverId, tokenizedProcessorAcct, body.same_day_funding_opt_in]);

    const token = generateToken({
      id: userId,
      email: body.email,
      role: 'driver',
      driverId
    });

    res.status(200).json({
      message: 'Driver onboarded successfully',
      token,
      driverId
    });
  } catch (err: any) {
    res.status(400).json({ error: err.message });
  }
});

// File upload endpoint
apiRouter.post('/uploads/file', upload.single('file'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const fileUrl = `/uploads/${req.file.filename}`;
  res.json({
    file_url: fileUrl,
    filename: req.file.originalname,
    size: req.file.size
  });
});

// Mock S3 signed URL generator
apiRouter.get('/uploads/signed-url', (req, res) => {
  const { filename = 'document.pdf', doc_type = 'coi' } = req.query;
  const key = `uploads/${Date.now()}-${filename}`;
  res.json({
    upload_url: `/api/uploads/file`,
    file_url: `/${key}`,
    expires_in: 3600
  });
});

// -------------------------------------------------------------
// 7. ADMIN ENDPOINTS
// -------------------------------------------------------------
apiRouter.get('/admin/ledger', authenticate, requireRole('admin'), async (req, res) => {
  try {
    const rows = await db.query(`
      SELECT 
        s.*,
        l.origin_city, l.origin_state, l.dest_city, l.dest_state, l.equipment_type,
        d.full_name as driver_name, d.cdl_number,
        sp.company_name as shipper_name
      FROM settlements s
      JOIN loads l ON s.load_id = l.id
      JOIN bookings b ON s.booking_id = b.id
      JOIN driver_profiles d ON b.driver_id = d.id
      JOIN shipper_profiles sp ON l.shipper_id = sp.id
      ORDER BY s.settled_at DESC
    `);
    res.json({ ledger: rows.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

apiRouter.get('/admin/export', authenticate, requireRole('admin'), async (req, res) => {
  try {
    const rows = await db.query(`
      SELECT 
        s.id, s.booking_id, s.load_id,
        l.origin_city, l.origin_state, l.dest_city, l.dest_state, l.equipment_type,
        s.miles, s.rate_per_mile, s.fuel_rate_per_mile,
        s.gross_amount, s.fee_amount, s.fuel_cost, s.factor_cost, s.factored, s.net_amount, s.settled_at
      FROM settlements s
      JOIN loads l ON s.load_id = l.id
      ORDER BY s.settled_at DESC
    `);

    const headers = [
      'settlement_id', 'booking_id', 'load_id', 'origin', 'destination', 'equipment',
      'miles', 'rate_per_mile', 'fuel_rate_per_mile', 'gross_amount', 'fee_amount',
      'fuel_cost', 'factor_cost', 'factored', 'net_amount', 'settled_at'
    ];

    let csvContent = headers.join(',') + '\n';
    rows.rows.forEach((r: any) => {
      const line = [
        r.id, r.booking_id, r.load_id,
        `"${r.origin_city}, ${r.origin_state}"`, `"${r.dest_city}, ${r.dest_state}"`, r.equipment_type,
        r.miles, r.rate_per_mile, r.fuel_rate_per_mile,
        r.gross_amount, r.fee_amount, r.fuel_cost, r.factor_cost, r.factored, r.net_amount, r.settled_at
      ];
      csvContent += line.join(',') + '\n';
    });

    res.setHeader('Content-Type', 'text/csv');
    res.setHeader('Content-Disposition', 'attachment; filename="open-books-ledger-export.csv"');
    res.send(csvContent);
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

// -------------------------------------------------------------
// 8. REAL-TIME SSE STREAM ENDPOINT
// -------------------------------------------------------------
apiRouter.get('/realtime/stream', (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();

  sseClients.push(res);

  // Send welcome ping
  res.write(`data: ${JSON.stringify({ type: 'connected', message: 'Subscribed to Open Books real-time stream' })}\n\n`);

  // Heartbeat every 15s to keep container HTTP proxy alive
  const heartbeat = setInterval(() => {
    res.write(`:ping\n\n`);
  }, 15000);

  req.on('close', () => {
    clearInterval(heartbeat);
    const idx = sseClients.indexOf(res);
    if (idx !== -1) sseClients.splice(idx, 1);
  });
});
