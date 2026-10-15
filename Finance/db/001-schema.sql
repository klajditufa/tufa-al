-- =====================================================================
--  TUFA Finance — Skema e Databazës
--  Dialekti: PostgreSQL 13+ (funksionon pa ndryshime edhe në Supabase)
-- =====================================================================
--  TABELAT
--    1. businesses          Bizneset që përdorin platformën (tenant-ët)
--    2. users               Përdoruesit: pronarë, staf dhe llogaritarët e TUFA
--    3. business_users      Lidhja përdorues <-> biznes, me rol për çdo biznes
--    4. customers           Klientët e biznesit (blerësit në faturat e shitjes)
--    5. invoices            Faturat e shitjes          -> moduli "Të Ardhurat"
--    6. invoice_items       Rreshtat e çdo fature
--    7. expense_categories  Kategoritë e shpenzimeve (Karburant, Qira, ...)
--    8. expenses            Shpenzimet / Blerjet       -> moduli "Shpenzimet"
--    9. tax_declarations    Deklarimet tatimore dhe statusi i tyre
--   10. documents           Arkiva digjitale (NIPT, QKB, kontrata, fatura të skanuara)
--
--  KONVENTAT
--    * Çdo tabelë e të dhënave ka business_id -> ndarje e qartë mes bizneseve
--      dhe bazë e gatshme për Row Level Security (Supabase).
--    * Çelësat primarë janë UUID (gen_random_uuid() është i integruar në PG 13+).
--    * Shumat ruhen si numeric(14,2); monedha sipas ISO 4217 ('ALL' = LEK, 'EUR').
--    * Statuset ruhen si tekst me CHECK (më të lehta për t'u zgjeruar se ENUM)
--      dhe përputhen me vlerat që përdor ndërfaqja (dashboard.html, fatura-e-re.html).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Funksion ndihmës: mban kolonën updated_at gjithmonë të përditësuar
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;


-- =====================================================================
-- 1. BIZNESET
-- =====================================================================
CREATE TABLE businesses (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  name            varchar(200)  NOT NULL,                       -- Emri i biznesit (si në QKB)
  nipt            varchar(10)   NOT NULL UNIQUE,                -- NIPT / NUIS, p.sh. L21234567A
  legal_form      varchar(30),                                  -- 'Person Fizik', 'SHPK', 'SHA', ...
  address         varchar(300),
  city            varchar(100),
  email           varchar(150),
  phone           varchar(30),
  vat_registered  boolean       NOT NULL DEFAULT true,          -- A është subjekt i TVSH-së
  currency        char(3)       NOT NULL DEFAULT 'ALL',         -- Monedha bazë (ALL = LEK)
  is_active       boolean       NOT NULL DEFAULT true,
  created_at      timestamptz   NOT NULL DEFAULT now(),
  updated_at      timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT chk_businesses_nipt CHECK (nipt ~ '^[A-Z][0-9]{8}[A-Z]$')
);
COMMENT ON TABLE businesses IS 'Bizneset (klientët) që përdorin TUFA Finance';


-- =====================================================================
-- 2. PËRDORUESIT
-- =====================================================================
CREATE TABLE users (
  id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  full_name      varchar(150)  NOT NULL,
  email          varchar(150)  NOT NULL UNIQUE,
  password_hash  varchar(255)  NOT NULL,                        -- bcrypt / argon2; kurrë fjalëkalim i hapur
  phone          varchar(30),
  is_tufa_staff  boolean       NOT NULL DEFAULT false,          -- true për llogaritarët e TUFA Finance
  is_active      boolean       NOT NULL DEFAULT true,
  last_login_at  timestamptz,
  created_at     timestamptz   NOT NULL DEFAULT now(),
  updated_at     timestamptz   NOT NULL DEFAULT now()
);
COMMENT ON TABLE users IS 'Llogaritë e hyrjes. Me Supabase Auth: id REFERENCES auth.users(id) dhe hiqet password_hash';


-- =====================================================================
-- 3. PËRDORUES <-> BIZNES
--    Një pronar mund të ketë disa biznese; një llogaritar i TUFA shërben
--    shumë biznese. Roli vlen për çdo lidhje veç e veç.
-- =====================================================================
CREATE TABLE business_users (
  business_id  uuid         NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  user_id      uuid         NOT NULL REFERENCES users(id)      ON DELETE CASCADE,
  role         varchar(20)  NOT NULL DEFAULT 'owner',           -- owner | staff | accountant
  created_at   timestamptz  NOT NULL DEFAULT now(),
  PRIMARY KEY (business_id, user_id),
  CONSTRAINT chk_business_users_role CHECK (role IN ('owner', 'staff', 'accountant'))
);


-- =====================================================================
-- 4. KLIENTËT E BIZNESIT (blerësit që shfaqen në faturat e shitjes)
-- =====================================================================
CREATE TABLE customers (
  id           uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id  uuid          NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  name         varchar(200)  NOT NULL,
  nipt         varchar(10),
  address      varchar(300),
  email        varchar(150),
  phone        varchar(30),
  created_at   timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT uq_customers_nipt UNIQUE (business_id, nipt)
);


-- =====================================================================
-- 5. FATURAT E SHITJES (TË ARDHURAT)
--    Fushat e formës "Faturë e Re" (fatura-e-re.html) përputhen me kolonat:
--    customer_name, customer_nipt, description, currency, subtotal,
--    vat_amount, total, status. Shkalla e TVSH-së ruhet te rreshtat
--    (invoice_items.vat_rate), sepse një faturë mund të ketë shkallë të ndryshme.
-- =====================================================================
CREATE TABLE invoices (
  id                uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id       uuid          NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  customer_id       uuid          REFERENCES customers(id) ON DELETE SET NULL,
  invoice_number    varchar(30)   NOT NULL,                     -- p.sh. '2026/0001' (sekuencë për çdo biznes)
  invoice_date      date          NOT NULL DEFAULT CURRENT_DATE,
  due_date          date,
  customer_name     varchar(200)  NOT NULL,                     -- kopje e "ngrirë" e të dhënave të klientit:
  customer_nipt     varchar(10),                                -- fatura nuk ndryshon nëse ndryshon klienti
  customer_address  varchar(300),
  description       text,                                       -- Përshkrimi i shërbimit
  currency          char(3)       NOT NULL DEFAULT 'ALL',       -- 'ALL' (LEK) ose 'EUR'
  exchange_rate     numeric(12,6) NOT NULL DEFAULT 1,           -- kursi ndaj LEK (1 kur fatura është në LEK)
  subtotal          numeric(14,2) NOT NULL DEFAULT 0,           -- Vlera pa TVSH
  vat_amount        numeric(14,2) NOT NULL DEFAULT 0,           -- TVSH
  total             numeric(14,2) NOT NULL DEFAULT 0,           -- Vlera me TVSH
  status            varchar(20)   NOT NULL DEFAULT 'draft',     -- draft | issued | paid | cancelled
  nivf              varchar(60),                                -- Fiskalizimi: Numri Identifikues i Veçantë i Faturës
  nslf              varchar(60),                                -- Fiskalizimi: Numri i Sigurisë i Lëshuesit të Faturës
  paid_at           timestamptz,
  notes             text,
  created_by        uuid          REFERENCES users(id) ON DELETE SET NULL,
  created_at        timestamptz   NOT NULL DEFAULT now(),
  updated_at        timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT uq_invoices_number   UNIQUE (business_id, invoice_number),
  CONSTRAINT chk_invoices_status  CHECK (status IN ('draft', 'issued', 'paid', 'cancelled')),
  CONSTRAINT chk_invoices_amounts CHECK (subtotal >= 0 AND vat_amount >= 0 AND total >= 0)
);

-- Rreshtat e faturës: shumat e rreshtit llogariten automatikisht (kolona të gjeneruara)
CREATE TABLE invoice_items (
  id             uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id     uuid          NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  line_no        smallint      NOT NULL DEFAULT 1,
  description    varchar(500)  NOT NULL,
  quantity       numeric(12,3) NOT NULL DEFAULT 1,
  unit_price     numeric(14,2) NOT NULL DEFAULT 0,              -- çmimi për njësi, pa TVSH
  vat_rate       numeric(5,2)  NOT NULL DEFAULT 20.00,          -- 20 | 10 | 6 | 0  (%)
  line_subtotal  numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_price, 2)) STORED,
  line_vat       numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_price * vat_rate / 100, 2)) STORED,
  line_total     numeric(14,2) GENERATED ALWAYS AS (round(quantity * unit_price, 2) + round(quantity * unit_price * vat_rate / 100, 2)) STORED,
  CONSTRAINT chk_invoice_items_vat CHECK (vat_rate BETWEEN 0 AND 100),
  CONSTRAINT chk_invoice_items_qty CHECK (quantity > 0)
);


-- =====================================================================
-- 6. KATEGORITË E SHPENZIMEVE
-- =====================================================================
CREATE TABLE expense_categories (
  id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   uuid          REFERENCES businesses(id) ON DELETE CASCADE,   -- NULL = kategori standarde (për të gjithë)
  name          varchar(100)  NOT NULL,
  account_code  varchar(20),                                                -- llogaria kontabël sipas planit tuaj (opsionale)
  is_active     boolean       NOT NULL DEFAULT true,
  CONSTRAINT uq_expense_categories UNIQUE (business_id, name)
);
-- UNIQUE nuk i konsideron dublikatë rreshtat me business_id NULL, prandaj
-- kategoritë standarde mbrohen me një indeks të veçantë:
CREATE UNIQUE INDEX uq_expense_categories_global ON expense_categories (name) WHERE business_id IS NULL;

-- Kategoritë standarde (shfaqen në listën "Kategoria" të formës së shpenzimeve)
INSERT INTO expense_categories (name) VALUES
  ('Karburant'),
  ('Qira'),
  ('Blerje Materialesh'),
  ('Konsulencë'),
  ('Paga dhe Sigurime'),
  ('Energji, Ujë, Internet'),
  ('Marketing'),
  ('Transport'),
  ('Tjetër');


-- =====================================================================
-- 7. SHPENZIMET / BLERJET
--    Fushat e formës "Ngarko një Shpenzim të Ri": expense_date, amount_total,
--    currency, category_id, notes. Skedari (foto/PDF) ruhet te documents.
-- =====================================================================
CREATE TABLE expenses (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid          NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  category_id     uuid          REFERENCES expense_categories(id) ON DELETE SET NULL,
  expense_date    date          NOT NULL,                       -- Data e faturës
  supplier_name   varchar(200),                                 -- Furnitori
  supplier_nipt   varchar(10),
  invoice_number  varchar(60),                                  -- Nr. i faturës / kuponit tatimor
  description     varchar(500),
  currency        char(3)       NOT NULL DEFAULT 'ALL',         -- LEK ose EUR
  exchange_rate   numeric(12,6) NOT NULL DEFAULT 1,
  amount_net      numeric(14,2),                                -- Vlera pa TVSH (NULL kur nuk dihet, p.sh. kupon)
  vat_amount      numeric(14,2) NOT NULL DEFAULT 0,
  amount_total    numeric(14,2) NOT NULL,                       -- Vlera totale (fusha e formës)
  vat_deductible  boolean       NOT NULL DEFAULT true,          -- A njihet TVSH-ja e zbritshme
  payment_method  varchar(20)   NOT NULL DEFAULT 'cash',        -- cash | bank | card | other
  is_paid         boolean       NOT NULL DEFAULT true,
  notes           text,                                         -- Shënime opsionale
  status          varchar(20)   NOT NULL DEFAULT 'pending',     -- pending (ngarkuar nga klienti) | approved (kontrolluar nga llogaritari) | rejected
  created_by      uuid          REFERENCES users(id) ON DELETE SET NULL,
  created_at      timestamptz   NOT NULL DEFAULT now(),
  updated_at      timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT chk_expenses_amount  CHECK (amount_total >= 0),
  CONSTRAINT chk_expenses_payment CHECK (payment_method IN ('cash', 'bank', 'card', 'other')),
  CONSTRAINT chk_expenses_status  CHECK (status IN ('pending', 'approved', 'rejected'))
);


-- =====================================================================
-- 8. DEKLARIMET TATIMORE
--    Statuset e panelit: declared = E Deklaruar | in_process = Në Proces |
--    pending_client = Pezull (kërkohen dokumente/sqarime nga klienti)
-- =====================================================================
CREATE TABLE tax_declarations (
  id            uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id   uuid          NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  tax_type      varchar(30)   NOT NULL,                         -- vat | payroll | profit_tax | simplified_profit_tax | withholding_tax | local_tax | other
  period_year   smallint      NOT NULL,
  period_month  smallint,                                       -- NULL për deklarime tremujore / vjetore
  period_label  varchar(40),                                    -- p.sh. 'Shtator 2026', 'Tremujori IV 2026'
  due_date      date          NOT NULL,                         -- Afati ligjor (TVSH: 14-i, Listëpagesa: 20-i i muajit pasardhës)
  amount_due    numeric(14,2) NOT NULL DEFAULT 0,               -- Detyrimi për t'u paguar
  amount_paid   numeric(14,2) NOT NULL DEFAULT 0,
  status        varchar(20)   NOT NULL DEFAULT 'in_process',
  declared_at   timestamptz,                                    -- kur u mbyll nga llogaritari
  note          text,                                           -- p.sh. cilat dokumente mungojnë nga klienti
  handled_by    uuid          REFERENCES users(id) ON DELETE SET NULL,   -- llogaritari përgjegjës i TUFA
  created_at    timestamptz   NOT NULL DEFAULT now(),
  updated_at    timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT chk_declarations_type    CHECK (tax_type IN ('vat', 'payroll', 'profit_tax', 'simplified_profit_tax', 'withholding_tax', 'local_tax', 'other')),
  CONSTRAINT chk_declarations_status  CHECK (status IN ('declared', 'in_process', 'pending_client')),
  CONSTRAINT chk_declarations_month   CHECK (period_month IS NULL OR period_month BETWEEN 1 AND 12),
  CONSTRAINT chk_declarations_amounts CHECK (amount_due >= 0 AND amount_paid >= 0)
);


-- =====================================================================
-- 9. DOKUMENTET (ARKIVA DIGJITALE + bashkëngjitjet e shpenzimeve/faturave)
--    Vetë skedari ruhet në storage (S3 / Supabase Storage / disk);
--    këtu ruhen metadata-t dhe lidhja me regjistrimin përkatës.
-- =====================================================================
CREATE TABLE documents (
  id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
  business_id     uuid          NOT NULL REFERENCES businesses(id) ON DELETE CASCADE,
  doc_type        varchar(30)   NOT NULL DEFAULT 'other',       -- nipt | qkb | contract | financial_statement | tax_declaration | purchase_invoice | sales_invoice | other
  title           varchar(200)  NOT NULL,
  file_name       varchar(255)  NOT NULL,                       -- emri origjinal i skedarit
  storage_path    varchar(500)  NOT NULL,                       -- rruga në storage
  mime_type       varchar(100)  NOT NULL,                       -- image/jpeg | image/png | application/pdf
  file_size       bigint        NOT NULL,                       -- në byte
  expense_id      uuid          REFERENCES expenses(id)         ON DELETE CASCADE,    -- foto/PDF e një shpenzimi
  invoice_id      uuid          REFERENCES invoices(id)         ON DELETE SET NULL,   -- PDF i një fature shitjeje
  declaration_id  uuid          REFERENCES tax_declarations(id) ON DELETE SET NULL,   -- vërtetimi i deklarimit / pagesës
  uploaded_by     uuid          REFERENCES users(id) ON DELETE SET NULL,
  uploaded_at     timestamptz   NOT NULL DEFAULT now(),
  CONSTRAINT chk_documents_type CHECK (doc_type IN ('nipt', 'qkb', 'contract', 'financial_statement', 'tax_declaration', 'purchase_invoice', 'sales_invoice', 'other')),
  CONSTRAINT chk_documents_mime CHECK (mime_type IN ('image/jpeg', 'image/png', 'application/pdf')),
  CONSTRAINT chk_documents_size CHECK (file_size > 0 AND file_size <= 10 * 1024 * 1024)   -- maks. 10 MB (si në ndërfaqe)
);


-- =====================================================================
-- INDEKSET (për pyetjet e panelit dhe listat e filtruara sipas biznesit)
-- =====================================================================
CREATE INDEX idx_business_users_user     ON business_users (user_id);
CREATE INDEX idx_customers_business      ON customers (business_id);
CREATE INDEX idx_invoices_business_date  ON invoices (business_id, invoice_date DESC);
CREATE INDEX idx_invoices_status         ON invoices (business_id, status);
CREATE INDEX idx_invoice_items_invoice   ON invoice_items (invoice_id);
CREATE INDEX idx_expenses_business_date  ON expenses (business_id, expense_date DESC);
CREATE INDEX idx_expenses_category       ON expenses (category_id);
CREATE INDEX idx_declarations_due        ON tax_declarations (business_id, due_date);
CREATE INDEX idx_documents_business_type ON documents (business_id, doc_type);
CREATE INDEX idx_documents_expense       ON documents (expense_id);


-- =====================================================================
-- TRIGGER-AT
-- =====================================================================
-- updated_at automatik
CREATE TRIGGER trg_businesses_updated_at       BEFORE UPDATE ON businesses       FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_users_updated_at            BEFORE UPDATE ON users            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_invoices_updated_at         BEFORE UPDATE ON invoices         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_expenses_updated_at         BEFORE UPDATE ON expenses         FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_tax_declarations_updated_at BEFORE UPDATE ON tax_declarations FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Totalet e faturës rillogariten sa herë ndryshojnë rreshtat e saj,
-- kështu subtotal / vat_amount / total nuk mund të dalin kurrë të gabuara.
CREATE OR REPLACE FUNCTION recalc_invoice_totals()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_invoice_id uuid;
BEGIN
  IF TG_OP = 'DELETE' THEN
    v_invoice_id := OLD.invoice_id;
  ELSE
    v_invoice_id := NEW.invoice_id;
  END IF;

  UPDATE invoices i
     SET subtotal   = COALESCE(t.subtotal, 0),
         vat_amount = COALESCE(t.vat, 0),
         total      = COALESCE(t.total, 0)
    FROM (SELECT SUM(line_subtotal) AS subtotal,
                 SUM(line_vat)      AS vat,
                 SUM(line_total)    AS total
            FROM invoice_items
           WHERE invoice_id = v_invoice_id) t
   WHERE i.id = v_invoice_id;

  RETURN NULL;
END;
$$;

CREATE TRIGGER trg_invoice_items_totals
AFTER INSERT OR UPDATE OR DELETE ON invoice_items
FOR EACH ROW EXECUTE FUNCTION recalc_invoice_totals();


-- =====================================================================
-- PAMJET (VIEWS) PËR PANELIN KRYESOR
-- =====================================================================
-- Ecuria mujore: të ardhura / shpenzime / fitim për çdo biznes dhe muaj
-- (ushqen kartat "Të Ardhurat Mujore", "Shpenzimet Mujore" dhe grafikun)
CREATE OR REPLACE VIEW v_monthly_summary AS
WITH income_m AS (
  SELECT business_id,
         date_trunc('month', invoice_date)::date  AS month,
         round(SUM(subtotal * exchange_rate), 2)  AS income
    FROM invoices
   WHERE status IN ('issued', 'paid')
   GROUP BY business_id, date_trunc('month', invoice_date)
),
expense_m AS (
  SELECT business_id,
         date_trunc('month', expense_date)::date                           AS month,
         round(SUM(COALESCE(amount_net, amount_total) * exchange_rate), 2) AS expenses
    FROM expenses
   WHERE status <> 'rejected'
   GROUP BY business_id, date_trunc('month', expense_date)
)
SELECT COALESCE(i.business_id, e.business_id)        AS business_id,
       COALESCE(i.month, e.month)                    AS month,
       COALESCE(i.income, 0)                         AS income,
       COALESCE(e.expenses, 0)                       AS expenses,
       COALESCE(i.income, 0) - COALESCE(e.expenses, 0) AS profit
  FROM income_m i
  FULL OUTER JOIN expense_m e
    ON e.business_id = i.business_id AND e.month = i.month;

-- Detyrimet e papaguara (ushqen kartën "Detyrime të Papaguara")
CREATE OR REPLACE VIEW v_unpaid_obligations AS
SELECT business_id,
       COUNT(*)                      AS obligations_count,
       SUM(amount_due - amount_paid) AS amount_unpaid,
       MIN(due_date)                 AS next_due_date
  FROM tax_declarations
 WHERE amount_due > amount_paid
 GROUP BY business_id;
