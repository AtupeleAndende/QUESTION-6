-- ============================================================
-- Q6: MONTHLY PAYROLL PROCESSING
-- ============================================================

-- ---------- (a) DATABASE: TABLES ----------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);



CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INT NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------- (b) FUNCTION ----------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END $$;

-- ---------- (c) PROCEDURE ----------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD; v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active LOOP
        v_net := fn_net_pay(r.employee_id);   -- raises on a bad calculation -> whole call fails
        INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;     -- existing rows unchanged
    END LOOP;
END $$;

-- ---------- (d) TRIGGER ----------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit(employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END $$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------- (a) SEED DATA ----------
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Mary Phiri',  5000, 500, 300, TRUE),
 ('John Banda',  4000, 400, 250, TRUE),
 ('Grace Zulu',  6000, 600, 500, TRUE),
 ('Peter Tembo', 3500, 300, 200, TRUE);

CALL pr_process_payroll('2026-09-01');                           -- everyone active

UPDATE employees SET active = FALSE WHERE employee_id = 4;       -- later becomes inactive
UPDATE employees SET basic_salary = 5200 WHERE employee_id = 1;  -- audited

CALL pr_process_payroll('2026-10-01');
CALL pr_process_payroll('2026-10-01');                           -- rerun: nothing changes

-- ---------- (e) VIEW ----------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no active filter: history is kept

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- ---------- (f) INDEX ----------
-- The unique index (employee_id, pay_month) leads with employee_id, so it cannot
-- serve a filter on pay_month alone. This index leads with pay_month and does not
-- duplicate the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll(pay_month);

-- SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = '2026-10-01';

-- ---------- (g) SCHEDULED JOB ----------
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('process_payroll', '0 2 1 * *',
  $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job
SELECT jobid, jobname, schedule, command, active FROM cron.job;

-- Inspect the run history
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'process_payroll')
ORDER BY start_time DESC;