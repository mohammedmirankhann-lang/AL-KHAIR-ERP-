# Al Khair Academy ERP

Owner-run school ERP for Al Khair Academy, Indore (MP board, Nursery to 8th).

## How it is built
- **App:** one static file, `index.html` (plain JavaScript). Hosted on Vercel project `al-khair-erp-2`. Every push to `main` deploys automatically.
- **Database and login:** Supabase project `al-khair-erp` (Mumbai, `wwfjiatnolndvggbviub`). The app talks to it directly; access is controlled by row-level security. Only the owner role can change data.
- **Staff login:** Supabase Edge Function `staff-login` (owner only) creates teacher logins from a mobile number. Its notes are in `supabase/functions/staff-login/README.md`.
- **Database history:** every schema change is in `supabase/migrations/` in order (1 to 11).

## What it does today
Students, fees and receipts, documents checklist (PEN, APAAR, Aadhaar, Samagra), accounts (double entry, P&L, balance sheet), trends, staff and geofence attendance, payroll (calculation, holdback, HDFC bulk file, posting to books), academics (PT1, Term 1, PT2, Term 2 marks and results, student attendance, progress tracking), teacher logins (class teacher attendance and subject marks entry, scoped to the teacher's own assignments), reminders (fees and documents, WhatsApp links), backup to Excel.

## Rules built in
- Fees: 70% tuition, remaining 30% split equally into Exam, Activity, Computer.
- Salary: per day = salary / days in month. Sundays and holidays are paid. Leave and absence are unpaid. Half day cuts 3 hours. Holdback (10% for flagged staff) is kept every month and paid in April of the next session.
- Books: journal entries cannot be edited or deleted; corrections are made by reversal. Salary and rent are dated the last day of their month.

## Saving your work (three layers)
1. **Code:** this GitHub repository.
2. **Data:** Supabase database. Use the **Backup (Excel)** button on the Dashboard at least once a week, and keep the file in Google Drive. Supabase Pro adds daily automatic backups and is recommended.
3. **Notes and decisions:** this README and the project memory.

## Going live checklist
- Owner login works (alkhair.indore176@gmail.com). Keep the password safe; set up a second owner or recovery email.
- Supabase Auth: turn off public sign-ups, turn on leaked-password protection.
- Set the school location in Staff > Settings before teachers punch.
- Take a first Backup.
- Move to Supabase Pro.
- Optional: own web address (for example erp.alkhairacademy.in) in Vercel project settings > Domains.

## Teacher access
The owner assigns each teacher in Academics > Setup (class teacher, or subject teacher for a class) and creates the login in Staff > Staff list. Teachers never read tables directly: they use database functions that check their own assignments. Marks are locked when a teacher submits; only the owner can unlock (Academics > Progress).

## Not built yet
Report cards, grades, AI summaries, WhatsApp sending through the official API.


## Report cards
- Academics > Report cards: pick a class, print one student or the whole class (3 pages each: Progress Report with PT1, Term 1, PT2, Term 2 columns; Personal & Social Traits; Arabic & Islamiyat card). Use "Save as PDF" in the print window.
- Class teacher fills Report details (traits, remark, height, weight) per evaluation. Eval-I = first half of the exams, Eval-II = second half. Attendance: Eval-I counts up to 30 Sep, Eval-II is cumulative.
- Subjects can have a report heading and component (Setup > Add subject), e.g. LITERACY SKILLS / Written. Arabic and Islamiyat components are on the separate Deeniyat card.
- Grades come from the grading key: 91-100 A1, 81-90 A2, 71-80 B1, 61-70 B2, 51-60 C1, 41-50 C2, 33-40 D, below 33 E.


## Finance tab
- Tabs: Health (cash, runway, ratios, projected year), Cash flow (by month), Assets (register, depreciation posted to the books), Forecast (12-month cash with a range), FCFF and DCF (valuation with sensitivity), Assumptions (saved in the database, shared by owner and accountant).
- Everything is calculated from the books. The numbers are only as complete as the entries in Accounts: record all expenses (electricity, stationery, repairs...) or put a monthly estimate in Assumptions.
- Assets: add with Already owned (opening) for existing items, enter present value and remaining life. Post depreciation monthly (one entry per finished month).
- Database: migration 16 (fixed_assets, asset_dep_runs, finance_settings, fin_ledger, fin_cashflow, asset_add, asset_depreciation_run).

## Three workspaces, one link, three logins
One system and one database. The sign-in decides what each person sees.

| Login | Sees | Cannot see |
|---|---|---|
| **Owner** | Everything: dashboard, students, fees, accounts, Finance, academics, staff, **salary** | – |
| **Accounts and Administration** (`accountant`) | Dashboard, Students (master data lives here), Documents, Fees, Reminders, Accounts (receipts, expenses, cash, P&L, balance sheet), Import | Staff, salary, Finance tab, academics |
| **Coordinator** (`coordinator`) | Home, Classes (subjects, attendance, exams, marks, report cards), Teachers (daily attendance, teacher work, staff directory without salary), monthly **Attendance report** | Fees, accounts, student documents, salary and bank details |

* Student master data is edited only by Accounts and Administration (or the owner); every workspace reads the same record.
* Monthly staff attendance: the coordinator checks the month in **Teachers > Attendance report** and presses *Submit to owner*. The month is then locked (owner can *Reopen* it).
* Salary is owner-only. `payroll_generate` refuses to run until that month's attendance report is submitted.
* Logins are created by the owner in Staff > staff member > Login > Access (Teacher / Coordinator / Accounts and Administration). Access can be changed later with *Change access*.
* Migration `20261010000017_roles_workspaces.sql`; edge function `staff-login` accepts `role`.
