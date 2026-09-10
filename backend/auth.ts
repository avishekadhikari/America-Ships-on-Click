import { Request, Response, NextFunction } from 'express';
import jwt from 'jsonwebtoken';
import { UserRole } from '../database/schema';

/**
 * Signing secret for JWTs.
 *
 * A hardcoded fallback in production means anyone who has read the source can
 * mint an admin token, so production must supply its own and it must be long
 * enough to resist offline brute force. Development keeps a fixed default so
 * the demo logins work out of the box.
 */
function resolveJwtSecret(): string {
  const secret = process.env.JWT_SECRET;

  if (process.env.NODE_ENV === 'production') {
    if (!secret) {
      throw new Error('JWT_SECRET must be set when NODE_ENV=production.');
    }
    if (secret.length < 32) {
      throw new Error('JWT_SECRET must be at least 32 characters.');
    }
    return secret;
  }

  if (!secret) {
    console.warn('[AUTH] JWT_SECRET not set — using an insecure development default.');
  }
  return secret || 'americashipsonclick_dev_only_insecure_secret';
}

const JWT_SECRET = resolveJwtSecret();

export interface AuthPayload {
  id: string;
  email: string;
  role: UserRole;
  driverId?: string;
  shipperId?: string;
}

export interface AuthenticatedRequest extends Request {
  user?: AuthPayload;
}

export function generateToken(payload: AuthPayload): string {
  return jwt.sign(payload, JWT_SECRET, { expiresIn: '7d', algorithm: 'HS256' });
}

export function verifyToken(token: string): AuthPayload | null {
  try {
    // Pinning the algorithm blocks "alg: none" and algorithm-confusion attacks,
    // where a forged token asks to be verified with a scheme we never issue.
    return jwt.verify(token, JWT_SECRET, { algorithms: ['HS256'] }) as AuthPayload;
  } catch {
    return null;
  }
}

export function authenticate(req: AuthenticatedRequest, res: Response, next: NextFunction) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized: missing or invalid token' });
  }

  const token = authHeader.split(' ')[1];
  const payload = verifyToken(token);
  if (!payload) {
    return res.status(401).json({ error: 'Unauthorized: invalid or expired token' });
  }

  req.user = payload;
  next();
}

export function requireRole(...roles: UserRole[]) {
  return (req: AuthenticatedRequest, res: Response, next: NextFunction) => {
    if (!req.user) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
    if (!roles.includes(req.user.role)) {
      return res.status(403).json({ error: `Forbidden: requires ${roles.join(' or ')} role` });
    }
    next();
  };
}
