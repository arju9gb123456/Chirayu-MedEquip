# Chirayu MedEquip

Biomedical Equipment Management System for **Chirayu Medical College & Hospital, Bhopal**.

QR-based equipment verification, public complaint portal, TAT tracking, technician assignment, reminders, printable reports and QR labels — in a single `index.html`.

## Features
- **Public:** equipment lookup by 6-digit ID or QR scan, complaint registration, complaint tracking by mobile number
- **Admin:** dashboard, equipment register (with photos), complaints (assign / edit / TAT / close / reopen), complaint history, separate Technicians & Admins management (minimum 3 admins), QR label printing, Excel export, section-wise printing, settings
- **Technician:** login with mobile number + PIN, assigned jobs, work notes
- **Reminders:** pop-ups for overdue TAT, unassigned complaints, PM / calibration / contract due dates
- Mobile-friendly, works offline in demo mode

## Go live
1. **Supabase:** open SQL Editor → paste `supabase/setup.sql` → Run (safe to re-run; tables use the `meq_` prefix).
2. In `index.html`, fill `SUPABASE_URL` and `SUPABASE_ANON_KEY` in `MEQ_CONFIG` at the top.
3. Deploy this repo on **Vercel** (framework: *Other*, no build command).
4. Log in → **Settings → QR & Public Link** → paste the Vercel URL → print QR labels.
5. **Change the default admin PINs immediately:** `admin1 / Chirayu@1`, `admin2 / Chirayu@2`, `admin3 / Chirayu@3`.

Without Supabase keys the app runs in **demo mode** (data stored in the browser only).

## Security
All tables have Row Level Security enabled with no public policies; every read/write goes through `SECURITY DEFINER` RPC functions that validate a session token. PINs are bcrypt-hashed; 5 wrong attempts lock an account for 10 minutes.

---
Made by Arjun Ahirwar
