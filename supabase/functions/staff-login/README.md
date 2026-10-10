# staff-login (Supabase Edge Function)

Owner-only. Actions: `create` (login ID = staff code, e.g. AKA1, shown to the teacher as "AKA1"), `reset` (new temporary password), `disable` / `enable` (block or allow sign-in; records are kept).
Staff codes belong to a person and are never reused. Source: `index.ts` (deployed as version 2).
