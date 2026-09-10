import { Router, Request, Response } from 'express';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import multer from 'multer';
import path from 'path';
import fs from 'fs';
import { db, type SessionContext } from '../database';
import { authenticate, generateToken, requireRole, AuthenticatedRequest } from './auth';
import { accountLast4, clientIp, newId, sessionContextFor, tokenizeBankAccount } from './security';

export const apiRouter = Router();

/** Lets code inside a transaction or a middleware abort with a specific status. */
class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
    this.name = 'HttpError';
  }
}

// Setup Multer for document upload storage
const uploadDir = path.join(process.cwd(), 'uploads');
if (!fs.existsSync(uploadDir)) {
  fs.mkdirSync(uploadDir, { recursive: true });
}

// Uploaded documents are served back over HTTP, so the filename, the extension,
// and the content type are all attacker-controlled unless we constrain them.
const ALLOWED_UPLOAD_TYPES: Record<string, string> = {
  'image/png': '.png',
  'image/jpeg': '.jpg',
  'image/webp': '.webp',
  'application/pdf': '.pdf'
};

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, uploadDir),
  filename: (req, file, cb) => {
    // The stored name is generated, never derived from the client's filename:
    // that removes path traversal, extension smuggling, and name collisions.
    const ext = ALLOWED_UPLOAD_TYPES[file.mimetype] || '.bin';
    cb(null, `${newId('doc')}${ext}`);
  }
});

const upload = multer({
  storage,
  limits: { fileSize: 10 * 1024 * 1024, files: 1 },
  fileFilter: (req, file, cb) => {
    if (!ALLOWED_UPLOAD_TYPES[file.mimetype]) {
      cb(new HttpError(415, `Unsupported file type: ${file.mimetype}. Allowed: PNG, JPEG, WebP, PDF.`));
      return;
    }
    cb(null, true);
  }
});

// Real-time SSE subscriber connections
const sseClients: Response[] = [];

export function broadcastSettlementEvent(data: any) {
  const payload = `data: ${JSON.stringify({ type: 'settlement_created', data })}\n\n`;
  sseClients.forEach(client => client.write(payload));
}

/**
 * Database handle scoped to the caller's verified identity. Row-Level Security
 * policies decide what these statements may touch, so a mistake in a route
 * cannot reach another user's rows.
 */
function scoped(req: AuthenticatedRequest, override?: Partial<SessionContext>) {
  return db.as({ ...sessionContextFor(req), ...override });
}

/** Pre-authentication contexts: no identity exists yet, so scope is minimal. */
const AUTH_CONTEXT: SessionContext = { role: 'auth' };
const ENROLLMENT_CONTEXT: SessionContext = { role: 'enrollment' };

function sendError(res: Response, err: any): void {
  // A schema rejection means the client sent something wrong, so it must not be
  // reported as a server fault.
  const status = err instanceof HttpError ? err.status : err instanceof z.ZodError ? 400 : 500;
  if (status >= 500) console.error('[API] Unhandled error:', err);
  res.status(status).json({ error: err.message });
}

// -------------------------------------------------------------
// 1. CONFIG ENDPOINT - Authoritative Single Source of Truth for Fees
// -------------------------------------------------------------
apiRouter.get('/config', async (req, res) => {
  try {
    const rows = await db.as({ role: 'anon' }).query<{ key: string; value: string }>('SELECT key, value FROM platform_config');
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
// Public signup mints carrier and shipper accounts only.
//
// 'admin' is deliberately absent: this endpoint is unauthenticated, so
// accepting the role here would let anyone who can reach it grant themselves
// the ledger, every carrier identity, and the RLS bypass behind
// `app_is_admin()`. Administrators are provisioned out of band (seeding, or a
// direct write by an operator), and migration 0012 enforces the same rule at
// the database so a future edit to this enum cannot quietly reopen it.
const signupSchema = z.object({
  email: z.string().email(),
  password: z.string().min(6),
  role: z.enum(['driver', 'shipper']),
  phone: z.string().optional(),
  name: z.string().min(2),
  home_city: z.string().optional(),
  home_state: z.string().optional(),
  company_name: z.string().optional()
});

apiRouter.post('/auth/signup', async (req, res) => {
  try {
    const body = signupSchema.parse(req.body);
    const passwordHash = await bcrypt.hash(body.password, 10);

    // User row and its role profile are created together or not at all — a
    // half-created account would leave the user unable to sign up or sign in.
    const { userId, driverId, shipperId } = await db.transaction(async tx => {
      const existing = await tx.query('SELECT id FROM users WHERE email = $1', [body.email]);
      if (existing.rows.length > 0) {
        throw new HttpError(400, 'User with this email already exists');
      }

      const userId = newId('usr');

      await tx.query(
        'INSERT INTO users (id, role, email, phone, password_hash) VALUES ($1, $2, $3, $4, $5)',
        [userId, body.role, body.email, body.phone || null, passwordHash]
      );

      let driverId: string | undefined;
      let shipperId: string | undefined;

      if (body.role === 'driver') {
        driverId = newId('drv');
        await tx.query(`
          INSERT INTO driver_profiles (id, user_id, full_name, home_base_city, home_base_state, verification_status)
          VALUES ($1, $2, $3, $4, $5, 'verified')
        `, [driverId, userId, body.name, body.home_city || 'Dallas', body.home_state || 'TX']);

        await tx.query(`
          INSERT INTO driver_equipment (id, driver_id, equipment_type, trailer_length_ft)
          VALUES ($1, $2, 'dry_van', 53)
        `, ['eq-' + driverId, driverId]);

        await tx.query(`
          INSERT INTO driver_payment_accounts (id, driver_id, payment_processor, processor_account_id, same_day_funding_opt_in)
          VALUES ($1, $2, 'stripe_connect', $3, TRUE)
        `, ['pay-' + driverId, driverId, tokenizeBankAccount(driverId, newId('pending'))]);
      } else if (body.role === 'shipper') {
        shipperId = newId('shp');
        await tx.query(`
          INSERT INTO shipper_profiles (id, user_id, company_name, billing_email)
          VALUES ($1, $2, $3, $4)
        `, [shipperId, userId, body.company_name || body.name, body.email]);
      }

      return { userId, driverId, shipperId };
    }, ENROLLMENT_CONTEXT);

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
    // Validation failures and duplicate emails are client errors, not 500s.
    res.status(err instanceof HttpError ? err.status : 400).json({ error: err.message });
  }
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string()
});

// A real bcrypt digest of an unguessable value. Verifying against it for
// unknown accounts keeps failed-login timing identical either way.
const DUMMY_PASSWORD_HASH = '$2b$10$N9qo8uLOickgx2ZMRZoMyeIjZAgcfl7p92ldGxad68LJZdL17lhWy';

apiRouter.post('/auth/login', async (req, res) => {
  try {
    const { email, password } = loginSchema.parse(req.body);
    const authDb = db.as(AUTH_CONTEXT);
    const ip = clientIp(req);

    // Throttling lives in the database, so it holds across restarts and across
    // every server instance behind a load balancer.
    const lockRes = await authDb.query<{ seconds: string }>(
      'SELECT app_login_lockout_seconds($1) AS seconds', [email]
    );
    const lockedFor = parseInt(lockRes.rows[0]?.seconds ?? '0', 10);
    if (lockedFor > 0) {
      return res.status(429).json({
        error: `Too many failed sign-in attempts. Try again in ${Math.ceil(lockedFor / 60)} minute(s).`,
        retry_after_seconds: lockedFor
      });
    }

    const userRes = await authDb.query<{
      id: string;
      role: 'driver' | 'shipper' | 'admin';
      email: string;
      password_hash: string;
    }>('SELECT * FROM users WHERE email = $1', [email]);

    const user = userRes.rows[0];
    // Compare against a dummy hash when the account does not exist, so the
    // response time does not reveal which emails are registered.
    const storedHash = user?.password_hash ?? DUMMY_PASSWORD_HASH;
    const match = await bcrypt.compare(password, storedHash);

    if (!user || !match) {
      await authDb.query('SELECT app_record_login_attempt($1, $2, FALSE)', [email, ip]);
      return res.status(401).json({ error: 'Invalid email or password' });
    }

    await authDb.query('SELECT app_record_login_attempt($1, $2, TRUE)', [email, ip]);

    let driverId: string | undefined;
    let shipperId: string | undefined;

    if (user.role === 'driver') {
      const drv = await authDb.query<{ id: string }>('SELECT id FROM driver_profiles WHERE user_id = $1', [user.id]);
      driverId = drv.rows[0]?.id;
    } else if (user.role === 'shipper') {
      const shp = await authDb.query<{ id: string }>('SELECT id FROM shipper_profiles WHERE user_id = $1', [user.id]);
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
    const drv = await scoped(req).query('SELECT * FROM driver_profiles WHERE id = $1', [req.user.driverId]);
    profileData = drv.rows[0] || {};
  } else if (req.user.role === 'shipper' && req.user.shipperId) {
    const shp = await scoped(req).query('SELECT * FROM shipper_profiles WHERE id = $1', [req.user.shipperId]);
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

    // Joins the public projection, not shipper_profiles: the board is anonymous
    // traffic, and that table holds billing contacts behind RLS.
    let query = `
      SELECT l.*, s.company_name as shipper_name
      FROM loads l
      JOIN public_shipper_view s ON l.shipper_id = s.id
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

    const result = await db.as({ role: 'anon' }).query(query, params);
    res.json({ loads: result.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

apiRouter.get('/loads/:id', async (req, res) => {
  try {
    const result = await db.as({ role: 'anon' }).query('SELECT * FROM loads WHERE id = $1', [req.params.id]);
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
      const shp = await scoped(req).query<{ id: string }>('SELECT id FROM shipper_profiles WHERE user_id = $1', [req.user?.id]);
      shipperId = shp.rows[0]?.id;
    }

    if (!shipperId) {
      return res.status(400).json({ error: 'Shipper profile not found. Please complete shipper setup.' });
    }

    const loadId = newId('LD');
    // Written under the resolved shipper identity: RLS rejects any attempt to
    // post a load on another shipper's behalf.
    const shipperDb = scoped(req, { shipperId });
    await shipperDb.query(`
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

    const created = await shipperDb.query('SELECT * FROM loads WHERE id = $1', [loadId]);
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
      const drv = await scoped(req).query<{ id: string }>('SELECT id FROM driver_profiles WHERE user_id = $1', [req.user?.id]);
      driverId = drv.rows[0]?.id;
    }
    if (!driverId) return res.status(400).json({ error: 'Driver profile required to book load' });

    // Everything below runs on one pooled connection inside one transaction:
    // the FOR UPDATE lock is only held for statements on that same client.
    const booking = await scoped(req, { driverId }).transaction(async tx => {
      // Read first, so a missing load and a taken load stay distinguishable.
      // (A driver cannot see other drivers' bookings under RLS, so "is it
      // taken?" is answered by the load's own status, not by scanning bookings.)
      const loadRes = await tx.query<{ status: string; id: string }>('SELECT * FROM loads WHERE id = $1', [load_id]);
      if (loadRes.rows.length === 0) {
        throw new HttpError(404, 'Load not found');
      }

      const load = loadRes.rows[0];
      if (load.status !== 'open') {
        throw new HttpError(409, 'Conflict: This load has already been booked or is no longer open.');
      }

      // Claim it: this blocks behind any competing booking and then re-checks
      // the status, so exactly one driver can leave this line holding the row.
      const claimed = await tx.query(
        `SELECT id FROM loads WHERE id = $1 AND status = 'open' FOR UPDATE`, [load_id]
      );
      if (claimed.rows.length === 0) {
        throw new HttpError(409, 'Conflict: This load has already been booked or is no longer open.');
      }

      const bookingId = newId('BK');
      try {
        await tx.query(`
          INSERT INTO bookings (id, load_id, driver_id, status)
          VALUES ($1, $2, $3, 'active')
        `, [bookingId, load_id, driverId]);
      } catch (err: any) {
        // Partial unique index on (load_id) WHERE status <> 'cancelled'.
        if (err?.code === '23505') {
          throw new HttpError(409, 'Conflict: Load is already booked');
        }
        throw err;
      }

      await tx.query(`UPDATE loads SET status = 'booked' WHERE id = $1`, [load_id]);

      const created = await tx.query('SELECT * FROM bookings WHERE id = $1', [bookingId]);
      return created.rows[0];
    });

    res.status(201).json(booking);
  } catch (err: any) {
    sendError(res, err);
  }
});

apiRouter.patch('/bookings/:id/pod', authenticate, async (req: AuthenticatedRequest, res) => {
  try {
    const { pod_url } = req.body;
    if (!pod_url) return res.status(400).json({ error: 'pod_url is required' });

    // RLS restricts this UPDATE to the caller's own bookings, so an unmatched
    // row means the booking either does not exist or is not theirs — the same
    // answer either way, which avoids confirming other drivers' booking ids.
    const updated = await scoped(req).query(
      'UPDATE bookings SET pod_url = $1 WHERE id = $2 RETURNING *',
      [pod_url, req.params.id]
    );
    if (updated.rows.length === 0) {
      throw new HttpError(404, 'Booking not found');
    }
    res.json(updated.rows[0]);
  } catch (err: any) {
    sendError(res, err);
  }
});

// Complete Booking -> Authoritative Server-Side Settlement Trigger!
apiRouter.patch('/bookings/:id/complete', authenticate, async (req: AuthenticatedRequest, res) => {
  try {
    // The booking row is locked, the settlement is written, and both parent
    // rows are advanced in a single transaction: a settlement can never exist
    // for a booking that was not marked completed, or vice versa.
    const { settlement, load } = await scoped(req).transaction(async tx => {
      const bkRes = await tx.query<any>('SELECT * FROM bookings WHERE id = $1 FOR UPDATE', [req.params.id]);
      if (bkRes.rows.length === 0) {
        throw new HttpError(404, 'Booking not found');
      }

      const booking = bkRes.rows[0];

      // Completing a booking pays a carrier. Only the driver who hauled it, or
      // an admin, may trigger that — previously any signed-in account could
      // settle any booking.
      const isAdmin = req.user?.role === 'admin';
      if (!isAdmin && booking.driver_id !== req.user?.driverId) {
        throw new HttpError(403, 'Forbidden: only the booked driver can complete this load');
      }

      if (booking.status === 'completed') {
        throw new HttpError(400, 'Booking already completed');
      }

      const loadRes = await tx.query<any>('SELECT * FROM loads WHERE id = $1', [booking.load_id]);
      const load = loadRes.rows[0];
      if (!load) {
        throw new HttpError(404, 'Load not found for booking');
      }

      // Read platform config values
      const cfgRes = await tx.query<{ key: string; value: string }>('SELECT key, value FROM platform_config');
      const cfg: Record<string, number> = {};
      cfgRes.rows.forEach(r => cfg[r.key] = parseFloat(r.value));

      const feePct = cfg['fee_pct'] ?? 0.05;
      const factorPct = cfg['factor_pct'] ?? 0.03;
      const fuelRate = cfg['fuel_rate_per_mile'] ?? 0.45;

      // Check if driver opted into same-day funding
      const drvPayRes = await tx.query<any>('SELECT same_day_funding_opt_in FROM driver_payment_accounts WHERE driver_id = $1', [booking.driver_id]);
      const factored = drvPayRes.rows[0]?.same_day_funding_opt_in ?? load.same_day_funding_offered;

      // AUTHORITATIVE SETTLEMENT CALCULATIONS
      const miles = parseFloat(load.miles);
      const ratePerMile = parseFloat(load.rate_per_mile);
      const grossAmount = miles * ratePerMile;
      const feeAmount = grossAmount * feePct;
      const fuelCost = miles * fuelRate;
      const factorCost = factored ? grossAmount * factorPct : 0;
      const netAmount = grossAmount - feeAmount - fuelCost - factorCost;

      const settlementId = newId('STL');
      const settledAt = new Date().toISOString();

      await tx.query(`
        INSERT INTO settlements (
          id, booking_id, load_id, miles, rate_per_mile, fuel_rate_per_mile,
          gross_amount, fee_amount, fee_pct_applied, fuel_cost, factor_cost, factored, net_amount, settled_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
      `, [
        settlementId, booking.id, load.id, miles, ratePerMile, fuelRate,
        grossAmount, feeAmount, feePct, fuelCost, factorCost, factored, netAmount, settledAt
      ]);

      await tx.query('UPDATE bookings SET status = \'completed\', delivered_at = $1 WHERE id = $2', [settledAt, booking.id]);
      await tx.query('UPDATE loads SET status = \'delivered\' WHERE id = $1', [load.id]);

      const settlementRes = await tx.query<Record<string, any>>('SELECT * FROM settlements WHERE id = $1', [settlementId]);
      return { settlement: settlementRes.rows[0] || {}, load };
    });

    // Broadcast SSE to live Open Books subscribers (only after COMMIT).
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
    sendError(res, err);
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

    const rows = await db.as({ role: 'anon' }).query('SELECT * FROM public_ledger_view LIMIT $1 OFFSET $2', [l, offset]);
    res.json({ settlements: rows.rows });
  } catch (err: any) {
    res.status(500).json({ error: err.message });
  }
});

apiRouter.get('/settlements/aggregate', async (req, res) => {
  try {
    const rows = await db.as({ role: 'anon' }).query<Record<string, any>>('SELECT * FROM settlement_totals_view');
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
  // Contact phone is recorded on the users row at signup. `users` is granted
  // SELECT/INSERT only — deliberately, so the app can never rewrite a password
  // hash or a role — so onboarding does not attempt to change it here.
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

/**
 * Completes the signed-in driver's carrier profile.
 *
 * Identity comes from the verified token, never from the request body. An
 * earlier version accepted an email, looked the user up by it, and upserted
 * their payment account — which let anyone who knew a driver's address point
 * that driver's settlements at their own bank. There is deliberately no way to
 * name a subject here: the route can only ever write the caller's own rows, and
 * migration 0005 enforces the same rule underneath it.
 */
apiRouter.post('/drivers/onboard', authenticate, requireRole('driver', 'admin'), async (req: AuthenticatedRequest, res) => {
  try {
    const body = driverOnboardSchema.parse(req.body);
    const user = req.user!;

    // Bank details are optional here; when present, both halves are required to
    // derive a token, and the raw numbers never reach the database.
    const hasBankDetails = Boolean(body.routing_number && body.account_number);
    if ((body.routing_number || body.account_number) && !hasBankDetails) {
      throw new HttpError(400, 'Both routing number and account number are required to update payout details.');
    }
    const last4 = hasBankDetails ? accountLast4(body.account_number) : null;

    const { driverId } = await db.transaction(async tx => {
      // The profile is located by the caller's own user id. RLS scopes every
      // statement below to this driver regardless of what the body asked for.
      const drvRes = await tx.query<{ id: string }>(
        'SELECT id FROM driver_profiles WHERE user_id = $1',
        [user.id]
      );
      if (drvRes.rows.length === 0) {
        throw new HttpError(404, 'No driver profile for this account. Sign up as a driver first.');
      }
      const driverId = drvRes.rows[0].id;

      await tx.query(`
        UPDATE driver_profiles
        SET full_name = $1, home_base_city = $2, home_base_state = $3, cdl_number = $4,
            cdl_class = $5, dot_number = $6, mc_number = $7
        WHERE id = $8
      `, [body.full_name, body.home_base_city, body.home_base_state, body.cdl_number || null,
          body.cdl_class || 'A', body.dot_number || null, body.mc_number || null, driverId]);

      await tx.query(`
        INSERT INTO driver_equipment (id, driver_id, equipment_type, trailer_length_ft)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (id) DO UPDATE SET equipment_type = EXCLUDED.equipment_type, trailer_length_ft = EXCLUDED.trailer_length_ft
      `, ['eq-' + driverId, driverId, body.equipment_type, body.trailer_length_ft]);

      if (hasBankDetails) {
        // Tokenize before anything touches the database. This is an HMAC, not
        // an encoding: the raw routing/account numbers cannot be recovered from
        // what gets stored.
        const tokenizedProcessorAcct = tokenizeBankAccount(body.routing_number, body.account_number);
        await tx.query(`
          INSERT INTO driver_payment_accounts (id, driver_id, payment_processor, processor_account_id, same_day_funding_opt_in)
          VALUES ($1, $2, 'stripe_connect', $3, $4)
          ON CONFLICT (driver_id) DO UPDATE SET processor_account_id = EXCLUDED.processor_account_id, same_day_funding_opt_in = EXCLUDED.same_day_funding_opt_in
        `, ['pay-' + driverId, driverId, tokenizedProcessorAcct, body.same_day_funding_opt_in]);
      } else {
        await tx.query(
          'UPDATE driver_payment_accounts SET same_day_funding_opt_in = $1 WHERE driver_id = $2',
          [body.same_day_funding_opt_in, driverId]
        );
      }

      return { driverId };
    }, sessionContextFor(req));

    // Reissue so the token carries the driver id for subsequent booking calls.
    const token = generateToken({
      id: user.id,
      email: user.email,
      role: user.role,
      driverId
    });

    res.status(200).json({
      message: 'Driver onboarded successfully',
      token,
      driverId,
      payment_account_last4: last4
    });
  } catch (err: any) {
    sendError(res, err);
  }
});

// File upload endpoint.
//
// Authenticated: this writes attacker-controlled bytes to the server's disk, so
// leaving it open let anyone fill the volume 10MB at a time. Driver documents
// are uploaded after the account exists, so the wizard always holds a token by
// the time it reaches this route.
apiRouter.post('/uploads/file', authenticate, (req, res) => {
  upload.single('file')(req, res, (err: any) => {
    if (err) {
      const status = err instanceof HttpError ? err.status : err.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
      return res.status(status).json({ error: err.message });
    }
    handleUpload(req, res);
  });
});

function handleUpload(req: Request, res: Response): void {
  if (!req.file) {
    res.status(400).json({ error: 'No file uploaded' });
    return;
  }
  const fileUrl = `/uploads/${req.file.filename}`;
  res.json({
    file_url: fileUrl,
    filename: req.file.originalname,
    size: req.file.size
  });
}

// Mock S3 signed URL generator
apiRouter.get('/uploads/signed-url', authenticate, (req, res) => {
  const { filename = 'document.pdf', doc_type = 'coi' } = req.query;
  const key = `uploads/${newId('doc')}-${filename}`;
  res.json({
    upload_url: `/api/uploads/file`,
    file_url: `/${key}`,
    expires_in: 3600
  });
});

// -------------------------------------------------------------
// 7. ADMIN ENDPOINTS
// -------------------------------------------------------------
apiRouter.get('/admin/ledger', authenticate, requireRole('admin'), async (req: AuthenticatedRequest, res) => {
  try {
    const rows = await scoped(req).query(`
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

apiRouter.get('/admin/export', authenticate, requireRole('admin'), async (req: AuthenticatedRequest, res) => {
  try {
    const rows = await scoped(req).query(`
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
