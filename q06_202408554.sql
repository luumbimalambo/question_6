-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Student: Luumbi Malambo | Student No: 202408554

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- (a) Tables ---------------------------------------------------------------
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
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT chk_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Joseph Banda',    8000.00, 1500.00, 1200.00, TRUE),
    ('Lucy Mwamba',     6500.00, 1000.00,  900.00, TRUE),
    ('Moses Chanda',    5000.00,  800.00,  700.00, TRUE),
    ('Nora Kasonde',    7000.00, 1200.00, 1000.00, TRUE),   -- becomes inactive later
    ('Oscar Zimba',     4500.00,  500.00,  600.00, FALSE);  -- already inactive

-- (b) Function -------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_net NUMERIC;
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) Procedure ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r     RECORD;
    v_net NUMERIC;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id
    LOOP
        v_net := fn_net_pay(r.employee_id);    -- raises -> the whole call fails and rolls back

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- (d) Trigger --------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW EXECUTE FUNCTION trg_salary_audit();

-- (a) continued: payroll data for at least two months
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '3 months')::date);
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);

-- Employee 4 leaves: their history must stay in the report
UPDATE employees SET active = FALSE WHERE employee_id = 4;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);

SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Tests
SELECT employee_id, fn_net_pay(employee_id) AS net_pay FROM employees ORDER BY 1;

-- rerunning an already processed month changes nothing
SELECT COUNT(*) AS rows_before FROM payroll;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);
SELECT COUNT(*) AS rows_after  FROM payroll;

-- salary change is audited, unchanged salary is not
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = 8500.00 WHERE employee_id = 1;   -- same value: no audit row
UPDATE employees SET allowance = 1600.00    WHERE employee_id = 2;   -- not a salary change
SELECT * FROM salary_audit;

DO $$
BEGIN
    BEGIN PERFORM fn_net_pay(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    BEGIN CALL pr_process_payroll(CURRENT_DATE + 3);   -- (not a month start unless the 1st)
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    -- bad employee data fails the WHOLE call: nothing is inserted for that month
    UPDATE employees SET deduction = 99999 WHERE employee_id = 3;
    BEGIN CALL pr_process_payroll((date_trunc('month', CURRENT_DATE))::date);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END;
    UPDATE employees SET deduction = 700 WHERE employee_id = 3;   -- restore
END $$;
SELECT COUNT(*) AS rows_for_current_month
FROM payroll WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;   -- 0

-- (e) View: joins history, including employees who later became inactive -----
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;   -- no filter on e.active

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index ----------------------------------------------------------------
-- UNIQUE (employee_id, pay_month) starts with employee_id, so it cannot serve a
-- search by pay_month alone. This single-column index does, and it is not a
-- duplicate of the unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;
SET enable_seqscan = off;   -- tiny table: force the plan to show the index
EXPLAIN
SELECT * FROM payroll WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date;
RESET enable_seqscan;

-- (g) Scheduled job: 02:00 on the 1st of every month, for the PREVIOUS month --
-- Scheduling with pg_cron. If pg_cron is not installed, this prints a notice instead
-- of failing, so the rest of the script is not rolled back.
DO $do$
BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('process_payroll_monthly', '0 2 1 * *',
        $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron not available, job not scheduled: %', SQLERRM;
END $do$;

-- Inspect the job (works only where pg_cron is installed):
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, runid, status, return_message, start_time, end_time
--   FROM cron.job_run_details ORDER BY start_time DESC LIMIT 20;
