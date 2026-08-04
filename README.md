# America Ships On Click — Full-Stack Freight Load Board & Open Books Ledger

"America Ships On Click" is a direct no-broker freight load board with a public "Open Books" settlement ledger. Shippers post loads, motor carriers book and haul them direct, and every completed transaction publishes transparent financial reporting to the public ledger.

---

## 🚀 Architectural Highlights

- **Single Source of Truth for Platform Fees**: Platform fee (5%), quick pay / same-day funding cost (3%), and fuel rates live in the `platform_config` database table and are exposed via `GET /api/config`. The frontend dynamically fetches and applies these rates across the live calculator, load board take-home math, and booking confirmations.
- **Server-Authoritative Settlement Math**: All fee, gross, fuel, factor, and carrier net calculations are executed server-side upon booking completion. The frontend never computes numbers independently from backend agreement.
- **Real DB Aggregate View**: Headline stats (Loads Settled, Miles Hauled, Total Paid to Carriers) are computed directly via `settlement_totals_view` SQL query rather than incremented counters to ensure totals never drift from the underlying settlement rows.
- **Transactional Double-Booking Protection**: Booking an open load uses explicit row locking (`FOR UPDATE`) and partial unique index constraints (`WHERE status NOT IN ('cancelled')`) to guarantee atomic single-driver bookings.
- **Real-Time Live Ledger Push**: Connected via Server-Sent Events (SSE) at `/api/realtime/stream` pushing instant updates to Open Books and homepage ticker.
- **Tokenized Driver Payments**: Bank routing and account details are tokenized prior to persistence; raw banking details are never stored.

---

## 🛠 Tech Stack

- **Frontend**: React 19 + TypeScript + Vite + Tailwind CSS + TanStack Query + SSE Client
- **Backend**: Express + Node.js + TypeScript
- **Database**: PostgreSQL (PGlite embedded WASM engine in Node.js) with raw SQL migrations, enums, views, and indexes
- **Auth**: JWT Authentication with Driver, Shipper, and Admin RBAC

---

## ⚙️ Environment Variables & Config

Define environment variables in `.env`:

```env
# API Base URL for frontend client (defaults to /api if unassigned)
VITE_API_BASE_URL="/api"

# Secret key for signing JWT tokens
JWT_SECRET="americashipsonclick_secret_jwt_key_2026"
```

---

## 📡 API Endpoints

### 1. Public & Config
- `GET /api/config` — Fetches authoritative platform fee rates and settings
- `GET /api/health` — Server health check

### 2. Authentication
- `POST /api/auth/signup` — Driver, Shipper, or Admin account creation
- `POST /api/auth/login` — Account login, returns JWT token
- `GET /api/auth/me` — Authenticated user details & profile

### 3. Freight Loads
- `GET /api/loads` — Search & filter open loads (origin, destination, equipment, min rate)
- `GET /api/loads/:id` — Load details
- `POST /api/loads` — Shipper posts a new load

### 4. Bookings & Settlements
- `POST /api/bookings` — Driver books open load (transactionally locked)
- `PATCH /api/bookings/:id/pod` — Upload Proof of Delivery (POD)
- `PATCH /api/bookings/:id/complete` — Complete booking & trigger authoritative settlement calculation
- `GET /api/settlements` — Public Open Books ledger (paginated)
- `GET /api/settlements/aggregate` — DB aggregate totals query

### 5. Driver Onboarding & Uploads
- `POST /api/drivers/onboard` — 4-step onboarding wizard submission
- `POST /api/uploads/file` — Document file upload handler
- `GET /api/uploads/signed-url` — Signed URL metadata generator

### 6. Admin & Real-Time Stream
- `GET /api/admin/ledger` — Admin-gated detailed ledger view
- `GET /api/admin/export` — Download CSV export of all settlements
- `GET /api/realtime/stream` — SSE real-time settlement push channel

---

## 🗄 Database Schema & Migration Files

- Migration file: `/src/db/migrations/0001_initial_schema.sql`
- ERD Diagram: `/docs/ERD.mermaid` and `/docs/ERD.md`

### Main Tables:
- `users`, `driver_profiles`, `driver_documents`, `driver_equipment`, `driver_payment_accounts`, `shipper_profiles`, `loads`, `bookings`, `settlements`, `platform_config`

### Database Views:
- `public_ledger_view`: Joins settlements to loads while preserving driver/shipper anonymity.
- `settlement_totals_view`: Aggregate query computing total count, miles, gross, fee, fuel cost, factor cost, and carrier net.

---

## 🧪 Testing the App

1. **Preset Demo Logins**: Click "Sign In / Switch Role" in the top bar to instantly log in as a Driver (`john.smith@trucking.com`), Shipper (`logistics@apexlogistics.com`), or Admin (`admin@americashipsonclick.com`).
2. **Find Loads**: Search and view loads. Notice carrier take-home pay is computed using fee % fetched from `/api/config`.
3. **Open Books**: Watch live settlements stream in via SSE. Note the donut chart and rate/mile bar chart.
4. **Drive With Us**: Complete the 4-step wizard with file uploads. Progress persists across page refresh.
5. **Post a Load**: Test the live fee calculator as you enter miles and rate.
6. **Dashboard**: View the auth-gated owner dashboard and download CSV exports.
