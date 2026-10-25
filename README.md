# tufa.al

Ridrejton `tufa.al` (dhe `www.tufa.al`) te **https://apps.tufa.al** — faqja e aplikacioneve (repo `tufa-apps`).
Ruan rrugën: `tufa.al/flota/` → `apps.tufa.al/flota/`. `404.html` bën të njëjtën gjë për çdo rrugë tjetër.

**Përjashtim:** `tufa.al/Finance/` shërben drejtpërdrejt aplikacionin **TUFA Finance** (dosja `Finance/`,
shih `Finance/README.md`); `tufa.al/finance` (me shkronjë të vogël) ridrejton te `/Finance/`.

**Përjashtim 2:** `tufa.al/programe/` — programet për shkarkim me kod (dosja `programe/`).

## tufa.al/programe — si funksionon

- Lista dhe skedarët ruhen në Supabase (projekti `flota`): tabela `programe` + bucket privat `programe`.
- Kodi kontrollohet nga funksioni `programe` (Edge Function), që jep një link që skadon pas 5 minutash.
  Pas 8 provash të gabuara nga e njëjta IP, bllokohet për 15 minuta. Çdo provë/shkarkim ruhet te `programe_shkarkime`.
- **Kodi:** Supabase → Edge Functions → Secrets → `PROGRAME_KODI` (nuk dallon shkronjat e mëdha/vogla).
  Për ta ndryshuar, ndrysho vlerën aty — s'ka nevojë të preket faqja.

**Shto një program:**
1. Supabase → Storage → `programe` → ngarko skedarin, p.sh. `flota/Flota-Setup-1.3.4.exe`.
2. SQL Editor:
   ```sql
   insert into programe (emri, pershkrimi, platforma, versioni, skedari, madhesia_mb, renditja)
   values ('Flota', 'Për kompanitë rent-a-car', 'Windows', '1.3.4', 'flota/Flota-Setup-1.3.4.exe', 18, 10);
   ```
Për ta hequr nga faqja: `update programe set aktiv = false where emri = '...';`
Statistika: `select p.emri, count(*) from programe_shkarkime s join programe p on p.id = s.program_id where s.sukses group by 1;`
