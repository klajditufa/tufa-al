// =====================================================================
//  TUFA Finance — server/vault.js
//  Kasaforta e kredencialeve të portaleve tatimore (Node.js 18+, ESM, pg)
// ---------------------------------------------------------------------
//  Fjalëkalimi i e-Albania i një subjekti:
//    1. vjen një herë nga paneli (PUT /api/subjects/:id/credentials, mbi HTTPS)
//    2. enkriptohet këtu me AES-256-GCM dhe ruhet në portal_credentials
//    3. dekriptohet vetëm kur worker-i hyn në Selfcare / C@TS (withCredentials)
//    4. çdo përdorim regjistrohet në portal_access_log
//
//  Çelësi: TUFA_VAULT_KEY = 32 byte në base64, i gjeneruar me
//      openssl rand -base64 32
//  dhe i vendosur në .env (asnjëherë në git, asnjëherë në databazë).
//  Rotacioni: shto TUFA_VAULT_KEY_V2, rienkripto rreshtat dhe rrit key_version.
// =====================================================================
import crypto from 'node:crypto';

const KEYS = {
  1: keyFromEnv('TUFA_VAULT_KEY'),
  // 2: keyFromEnv('TUFA_VAULT_KEY_V2'),   // aktivizohet gjatë rotacionit
};

function keyFromEnv(name) {
  const raw = process.env[name];
  if (!raw) throw new Error(`${name} mungon në mjedis (.env)`);
  const key = Buffer.from(raw, 'base64');
  if (key.length !== 32) throw new Error(`${name} duhet të jetë 32 byte në base64 (openssl rand -base64 32)`);
  return key;
}

/* ---------------------------------------------------------------------
   Enkriptimi / dekriptimi
   --------------------------------------------------------------------- */
export function encryptSecret(plain, keyVersion = 1) {
  const key = KEYS[keyVersion];
  if (!key) throw new Error(`Çelësi me version ${keyVersion} nuk ekziston`);
  const iv = crypto.randomBytes(12);                                  // IV i ri për çdo enkriptim
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plain, 'utf8'), cipher.final(), cipher.getAuthTag()]);
  return { cipher: ct, iv, keyVersion };                              // ct = shifra + auth tag (16 byte)
}

export function decryptSecret({ cipher, iv, keyVersion = 1 }) {
  const key = KEYS[keyVersion];
  if (!key) throw new Error(`Çelësi me version ${keyVersion} nuk ekziston`);
  const tag  = cipher.subarray(cipher.length - 16);
  const data = cipher.subarray(0, cipher.length - 16);
  const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
  d.setAuthTag(tag);                                                  // dështon nëse shifra është ndryshuar
  return Buffer.concat([d.update(data), d.final()]).toString('utf8');
}

/* ---------------------------------------------------------------------
   Ruajtja / heqja e kredencialeve (db = pg.Pool ose pg.Client)
   --------------------------------------------------------------------- */
export async function saveCredentials(db, { businessId, password, usesSelfcare = true, usesCats = true, requiresOtp = false, userId = null, ip = null }) {
  if (!password) throw new Error('Fjalëkalimi mungon');
  const { rows: [b] } = await db.query('SELECT nipt FROM businesses WHERE id = $1', [businessId]);
  if (!b) throw new Error('Subjekti nuk u gjet');

  const { cipher, iv, keyVersion } = encryptSecret(password);
  await db.query(
    `INSERT INTO portal_credentials
       (business_id, username, password_cipher, password_iv, key_version, uses_selfcare, uses_cats, requires_otp, status, updated_by)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'unverified', $9)
     ON CONFLICT (business_id) DO UPDATE SET
       username        = EXCLUDED.username,
       password_cipher = EXCLUDED.password_cipher,
       password_iv     = EXCLUDED.password_iv,
       key_version     = EXCLUDED.key_version,
       uses_selfcare   = EXCLUDED.uses_selfcare,
       uses_cats       = EXCLUDED.uses_cats,
       requires_otp    = EXCLUDED.requires_otp,
       status          = 'unverified',
       last_error      = NULL,
       updated_by      = EXCLUDED.updated_by`,
    [businessId, b.nipt, cipher, iv, keyVersion, usesSelfcare, usesCats, requiresOtp, userId]);

  await logAccess(db, { businessId, userId, action: 'credential_set', portal: 'ealbania', ip });
}

export async function removeCredentials(db, { businessId, userId = null, ip = null }) {
  await db.query('DELETE FROM portal_credentials WHERE business_id = $1', [businessId]);
  await logAccess(db, { businessId, userId, action: 'credential_removed', portal: 'ealbania', ip });
}

/* ---------------------------------------------------------------------
   Përdorimi i kredencialeve: dekriptohen, i jepen fn(), dhe harrohen.
   fn merr { username, password } dhe kthen rezultatin e punës.
   --------------------------------------------------------------------- */
export async function withCredentials(db, businessId, fn, { userId = null, portal = 'ealbania', action = 'login' } = {}) {
  const { rows: [c] } = await db.query(
    'SELECT username, password_cipher, password_iv, key_version FROM portal_credentials WHERE business_id = $1',
    [businessId]);
  if (!c) throw new Error('Nuk ka kredenciale të ruajtura për këtë subjekt');

  const password = decryptSecret({ cipher: c.password_cipher, iv: c.password_iv, keyVersion: c.key_version });
  try {
    const result = await fn({ username: c.username, password });
    await db.query(
      `UPDATE portal_credentials SET status = 'ok', last_verified_at = now(), last_error = NULL WHERE business_id = $1`,
      [businessId]);
    await logAccess(db, { businessId, userId, action, portal, success: true });
    return result;
  } catch (err) {
    const invalid = /kredencial|fjal[eë]kalim|password|credential|unauthori[sz]ed|401/i.test(String(err.message));
    await db.query(
      `UPDATE portal_credentials SET status = $2, last_error = $3 WHERE business_id = $1`,
      [businessId, invalid ? 'invalid' : 'unverified', String(err.message).slice(0, 500)]);
    await logAccess(db, { businessId, userId, action, portal, success: false, detail: String(err.message).slice(0, 500) });
    throw err;
  }
}

export async function logAccess(db, { businessId, userId = null, action, portal = null, success = true, detail = null, ip = null }) {
  await db.query(
    `INSERT INTO portal_access_log (business_id, user_id, action, portal, success, detail, ip_address)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [businessId, userId, action, portal, success, detail, ip]);
}

/* ---------------------------------------------------------------------
   Rrugët e API-së (Express). requireAuth vendos req.user = { id, ... }
   --------------------------------------------------------------------- */
export function registerCredentialRoutes(app, db, requireAuth) {
  // Paneli: ruaj / zëvendëso fjalëkalimin (trupi: { password, usesSelfcare, usesCats, requiresOtp })
  app.put('/api/subjects/:id/credentials', requireAuth, async (req, res, next) => {
    try {
      await saveCredentials(db, { businessId: req.params.id, ...req.body, userId: req.user.id, ip: req.ip });
      res.json({ ok: true });                                         // fjalëkalimi nuk kthehet kurrë
    } catch (err) { next(err); }
  });

  app.delete('/api/subjects/:id/credentials', requireAuth, async (req, res, next) => {
    try { await removeCredentials(db, { businessId: req.params.id, userId: req.user.id, ip: req.ip }); res.json({ ok: true }); }
    catch (err) { next(err); }
  });

  // Regjistri i subjekteve lexon statusin, pa asnjë sekret
  app.get('/api/subjects/portal-status', requireAuth, async (req, res, next) => {
    try { const { rows } = await db.query('SELECT * FROM v_portal_status ORDER BY name'); res.json(rows); }
    catch (err) { next(err); }
  });

  // "Shfaq": vetëm pas ri-autentikimit të ekonomistit (req.body.myPassword), gjithmonë i regjistruar
  app.post('/api/subjects/:id/credentials/reveal', requireAuth, async (req, res, next) => {
    try {
      if (!(await req.verifyOwnPassword(req.body.myPassword))) return res.status(403).json({ error: 'Fjalëkalimi juaj është i gabuar' });
      const out = await withCredentials(db, req.params.id, async ({ username, password }) => ({ username, password }),
                                        { userId: req.user.id, action: 'credential_reveal' });
      res.set('Cache-Control', 'no-store').json(out);
    } catch (err) { next(err); }
  });

  // "Sinkronizo": krijon një job që e kryen worker-i (shih runSyncJob)
  app.post('/api/subjects/:id/sync', requireAuth, async (req, res, next) => {
    try {
      const { portal = 'selfcare', jobType = 'purchase_invoices', periodFrom = null, periodTo = null } = req.body;
      const { rows: [job] } = await db.query(
        `INSERT INTO portal_sync_jobs (business_id, portal, job_type, period_from, period_to, requested_by)
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, status`,
        [req.params.id, portal, jobType, periodFrom, periodTo, req.user.id]);
      res.status(202).json(job);
    } catch (err) { next(err); }
  });
}

/* ---------------------------------------------------------------------
   Worker-i: merr job-et "queued" dhe hyn në portal me kredencialet.
   portalClient është moduli juaj i hyrjes në e-Albania (API-ja e portalit):
     portalClient.login(username, password)            -> session
     portalClient.selfcare.fetchInvoices(session, job)  -> { invoices, pdfs }
     portalClient.cats.fetchDeclarations(session, job)  -> { declarations }
   --------------------------------------------------------------------- */
export async function runSyncJob(db, job, portalClient) {
  await db.query(`UPDATE portal_sync_jobs SET status = 'running', started_at = now() WHERE id = $1`, [job.id]);
  try {
    const result = await withCredentials(db, job.business_id, async ({ username, password }) => {
      const session = await portalClient.login(username, password);
      return job.portal === 'selfcare'
        ? portalClient.selfcare.fetchInvoices(session, job)
        : portalClient.cats.fetchDeclarations(session, job);
    }, { portal: job.portal, action: 'sync' });

    await db.query(`UPDATE portal_sync_jobs SET status = 'done', finished_at = now(), result = $2 WHERE id = $1`,
                   [job.id, JSON.stringify(result)]);
    return result;
  } catch (err) {
    await db.query(`UPDATE portal_sync_jobs SET status = 'failed', finished_at = now(), error = $2 WHERE id = $1`,
                   [job.id, String(err.message).slice(0, 500)]);
    throw err;
  }
}

export async function runQueuedJobs(db, portalClient, limit = 5) {
  const { rows: jobs } = await db.query(
    `SELECT * FROM portal_sync_jobs WHERE status = 'queued' ORDER BY created_at LIMIT $1`, [limit]);
  for (const job of jobs) {
    try { await runSyncJob(db, job, portalClient); } catch (e) { /* u regjistrua te job.error dhe portal_access_log */ }
  }
  return jobs.length;
}
