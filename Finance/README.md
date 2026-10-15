# TUFA Finance

Kontabilitet online për bizneset shqiptare — paneli i klientit, moduli i faturimit, ngarkimi i
shpenzimeve/dokumenteve dhe Paneli i Ekonomistit (matrica e deklarimeve për të gjithë subjektet).

Publikohet automatikisht në **https://tufa.al/Finance/** (GitHub Pages, workflow-i `pages.yml`
i këtij repo-je) sa herë bëhet push në `main`.

## Struktura

| Rruga | Çfarë është |
|---|---|
| `index.html` | Faqja hyrëse publike (hero, veçoritë, pse ne, si funksionon) |
| `hyr.html` | Hyrja / Krijo llogari (demo – çon te paneli i klientit) |
| `app/dashboard.html` | Paneli i klientit: kartat, grafiku mujor (Chart.js), deklarimet me statuse |
| `app/fatura-e-re.html` | Moduli i faturimit: TVSH-ja dhe totali llogariten në çast |
| `app/ngarko-dokumente.html` | Drag & Drop për shpenzimet (foto/PDF) dhe arkivën digjitale |
| `admin/index.html` | Paneli i Ekonomistit: regjistri i subjekteve, matrica e deklarimeve, progress tracker, kredencialet e-Albania |
| `db/001-schema.sql` | Skema PostgreSQL (bizneset, përdoruesit, faturat, shpenzimet, deklarimet, dokumentet) |
| `db/002-portalet.sql` | Kredencialet e portaleve (Selfcare / C@TS), audit log, sync jobs |
| `server/vault.js` | Enkriptimi AES-256-GCM i fjalëkalimeve, rrugët API dhe worker-i i sinkronizimit |

Faqet janë HTML + Tailwind CSS (Play CDN) + JavaScript pa framework. Të dhënat janë mock
(JSON në JS) dhe ruhen në `localStorage`, që aplikacioni të duket funksional pa backend.

## Faqet live

- Faqja hyrëse: https://tufa.al/Finance/
- Paneli i klientit: https://tufa.al/Finance/app/dashboard.html
- Paneli i Ekonomistit: https://tufa.al/Finance/admin/

## Hapat e radhës

1. **Backend** (Node.js + PostgreSQL, p.sh. në VPS ose Supabase): ekzekuto `db/001-schema.sql`
   dhe `db/002-portalet.sql`; vendos `TUFA_VAULT_KEY` (`openssl rand -base64 32`) në `.env`.
2. **API**: pikat e lidhjes janë shënuar me komente `// Në prodhim: ...` në çdo faqe
   (`/api/invoices`, `/api/expenses`, `/api/documents`, `/api/subjects`, `/api/declarations`,
   `/api/subjects/:id/credentials`, `/api/sync-jobs`).
3. **Hyrja reale**: `hyr.html` → `/api/auth/login` (klient) dhe `admin/` vetëm për ekonomistët.
4. **Tailwind në prodhim**: zëvendëso Play CDN me build (Tailwind CLI) kur dizajni të stabilizohet.
5. **Portal client**: moduli i hyrjes në e-Albania që ushqen `runSyncJob()` në `server/vault.js`
   (Selfcare → faturat, C@TS → deklarimet).

## Siguria e kredencialeve

Fjalëkalimet e e-Albania të subjekteve nuk ruhen kurrë si tekst i hapur: në demo enkriptohen në
browser me një fjalëkalim kryesor (PBKDF2 + AES-256-GCM); në prodhim dërgohen një herë te serveri,
që i enkripton me çelësin e tij dhe i dekripton vetëm kur hyn në portal. Çdo përdorim regjistrohet
në `portal_access_log`.
