-- =====================================================================
--  TUFA Finance — Migrimi 002: Kredencialet e portaleve tatimore
--  Ekzekutohet PAS 001-schema.sql (PostgreSQL 13+ / Supabase)
-- =====================================================================
--  Ekonomisti hyn në emër të subjektit me llogarinë e tij e-Albania
--  (përdoruesi = NIPT-i) për të marrë të dhëna nga:
--    * Selfcare (fiskalizimi, faturat): https://efiskalizimi-app.tatime.gov.al/self-care/#/dashboard
--    * C@TS     (deklarimet tatimore):   https://efiling.tatime.gov.al/cats_public/
--
--  RREGULLAT E SIGURISË
--    * Fjalëkalimi ruhet VETËM i enkriptuar (AES-256-GCM) me çelësin e serverit
--      TUFA_VAULT_KEY, që qëndron jashtë databazës (.env). Databaza e vetme,
--      edhe e vjedhur, nuk e zbulon dot.
--    * Dekriptimi bëhet vetëm në server/worker, në momentin e hyrjes
--      (shih server/vault.js). Browser-it nuk i kthehet kurrë, përveç një
--      "reveal" të qëllimshëm, që regjistrohet në portal_access_log.
--    * Në Supabase: për portal_credentials aktivizo RLS pa asnjë policy
--      (vetëm service_role e lexon) – tabela nuk duhet të dalë kurrë në API.
-- =====================================================================


-- =====================================================================
-- 11. KREDENCIALET E PORTALEVE (një llogari e-Albania për subjekt)
-- =====================================================================
CREATE TABLE portal_credentials (
  id                   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id          uuid        NOT NULL UNIQUE REFERENCES businesses(id) ON DELETE CASCADE,
  username             varchar(50) NOT NULL,                       -- NIPT-i (emri i përdoruesit në e-Albania)
  password_cipher      bytea       NOT NULL,                       -- AES-256-GCM: teksti i shifruar + auth tag (16 byte në fund)
  password_iv          bytea       NOT NULL,                       -- 12 byte, i ri për çdo enkriptim
  key_version          smallint    NOT NULL DEFAULT 1,             -- për rotacionin e TUFA_VAULT_KEY
  uses_selfcare        boolean     NOT NULL DEFAULT true,
  uses_cats            boolean     NOT NULL DEFAULT true,
  requires_otp         boolean     NOT NULL DEFAULT false,         -- llogaria ka verifikim me dy hapa (kërkon kod)
  status               varchar(20) NOT NULL DEFAULT 'unverified',  -- unverified | ok | invalid | locked
  last_verified_at     timestamptz,                                -- hyrja e fundit e suksesshme
  last_error           text,
  consent_document_id  uuid        REFERENCES documents(id) ON DELETE SET NULL,   -- autorizimi i nënshkruar nga klienti
  consent_at           timestamptz,
  updated_by           uuid        REFERENCES users(id) ON DELETE SET NULL,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_portal_credentials_status CHECK (status IN ('unverified', 'ok', 'invalid', 'locked')),
  CONSTRAINT chk_portal_credentials_iv     CHECK (octet_length(password_iv) = 12),
  CONSTRAINT chk_portal_credentials_cipher CHECK (octet_length(password_cipher) > 16)
);
CREATE TRIGGER trg_portal_credentials_updated_at
BEFORE UPDATE ON portal_credentials FOR EACH ROW EXECUTE FUNCTION set_updated_at();

COMMENT ON TABLE  portal_credentials IS 'Llogaria e-Albania e subjektit (Selfcare + C@TS), e enkriptuar; dekriptohet vetëm në server';
COMMENT ON COLUMN portal_credentials.password_cipher IS 'Asnjëherë tekst i hapur. Enkriptim/dekriptim: server/vault.js';


-- =====================================================================
-- 12. REGJISTRI I AKSESIT (audit: kush, kur, çfarë bëri me kredencialet)
-- =====================================================================
CREATE TABLE portal_access_log (
  id           bigserial   PRIMARY KEY,
  business_id  uuid        REFERENCES businesses(id) ON DELETE SET NULL,
  user_id      uuid        REFERENCES users(id) ON DELETE SET NULL,   -- NULL = veprim automatik i sistemit (worker)
  action       varchar(30) NOT NULL,     -- credential_set | credential_removed | credential_reveal | login | sync
  portal       varchar(20),              -- ealbania | selfcare | cats
  success      boolean     NOT NULL DEFAULT true,
  detail       text,                     -- p.sh. "42 fatura blerjeje" ose mesazhi i gabimit
  ip_address   inet,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_portal_access_action CHECK (action IN ('credential_set', 'credential_removed', 'credential_reveal', 'login', 'sync')),
  CONSTRAINT chk_portal_access_portal CHECK (portal IS NULL OR portal IN ('ealbania', 'selfcare', 'cats'))
);
CREATE INDEX idx_portal_access_log_business ON portal_access_log (business_id, created_at DESC);
CREATE INDEX idx_portal_access_log_user     ON portal_access_log (user_id, created_at DESC);


-- =====================================================================
-- 13. SINKRONIZIMET ("Sinkronizo" nga paneli → worker-i në server)
-- =====================================================================
CREATE TABLE portal_sync_jobs (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   uuid        NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  portal        varchar(20) NOT NULL,                       -- selfcare | cats
  job_type      varchar(30) NOT NULL,                       -- purchase_invoices | sales_invoices | declarations | balance
  period_from   date,
  period_to     date,
  status        varchar(20) NOT NULL DEFAULT 'queued',      -- queued | running | done | failed
  requested_by  uuid        REFERENCES users(id) ON DELETE SET NULL,
  started_at    timestamptz,
  finished_at   timestamptz,
  result        jsonb,                                      -- p.sh. {"invoices": 42, "pdfs": 42}
  error         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT chk_sync_jobs_portal CHECK (portal IN ('selfcare', 'cats')),
  CONSTRAINT chk_sync_jobs_type   CHECK (job_type IN ('purchase_invoices', 'sales_invoices', 'declarations', 'balance')),
  CONSTRAINT chk_sync_jobs_status CHECK (status IN ('queued', 'running', 'done', 'failed'))
);
CREATE INDEX idx_sync_jobs_queue    ON portal_sync_jobs (status, created_at);
CREATE INDEX idx_sync_jobs_business ON portal_sync_jobs (business_id, created_at DESC);


-- =====================================================================
-- PAMJE PA ASNJË KOLONË SEKRETE – kjo lexohet nga "Regjistri i Subjekteve"
-- =====================================================================
CREATE OR REPLACE VIEW v_portal_status AS
SELECT b.id                       AS business_id,
       b.name,
       b.nipt,
       c.id IS NOT NULL           AS has_credentials,
       c.username,
       c.uses_selfcare,
       c.uses_cats,
       c.requires_otp,
       c.status                   AS credential_status,
       c.last_verified_at,
       c.updated_at               AS credentials_updated_at,
       (SELECT max(created_at) FROM portal_sync_jobs j
         WHERE j.business_id = b.id AND j.status = 'done') AS last_sync_at
  FROM businesses b
  LEFT JOIN portal_credentials c ON c.business_id = b.id;
