DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path TO q3_library, public;

CREATE TABLE books(book_id SERIAL PRIMARY KEY,title VARCHAR(150) NOT NULL);
CREATE TABLE loans(
 loan_id SERIAL PRIMARY KEY,book_id INTEGER NOT NULL REFERENCES books(book_id),
 borrower_name VARCHAR(120) NOT NULL,borrowed_on DATE NOT NULL,due_on DATE NOT NULL,
 returned_on DATE,fine_amount NUMERIC(12,2) NOT NULL DEFAULT 0,
 CHECK(due_on>=borrowed_on),CHECK(returned_on IS NULL OR returned_on>=borrowed_on),
 CHECK(fine_amount>=0)
);
CREATE TABLE loan_audit(
 audit_id SERIAL PRIMARY KEY,loan_id INTEGER NOT NULL REFERENCES loans(loan_id),
 old_returned_on DATE,new_returned_on DATE,changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE overdue_summary(snapshot_date DATE PRIMARY KEY,overdue_count INTEGER NOT NULL,total_fine NUMERIC(12,2) NOT NULL);

CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER,p_as_of DATE)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_return DATE; v_end DATE; v_fine NUMERIC(12,2);
BEGIN
 SELECT due_on,returned_on INTO v_due,v_return FROM loans WHERE loan_id=p_loan_id;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan'; END IF;
 IF p_as_of IS NULL THEN RAISE EXCEPTION 'As-of date cannot be NULL'; END IF;
 v_end:=LEAST(p_as_of,COALESCE(v_return,p_as_of));
 v_fine:=GREATEST(v_end-v_due,0)*2.00;
 RETURN v_fine;
END; $$;

CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER,p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_borrowed DATE; v_due DATE;
BEGIN
 SELECT borrowed_on,due_on INTO v_borrowed,v_due FROM loans WHERE loan_id=p_loan_id FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown loan'; END IF;
 IF (SELECT returned_on FROM loans WHERE loan_id=p_loan_id) IS NOT NULL THEN RAISE EXCEPTION 'Loan already returned'; END IF;
 IF p_returned_on IS NULL OR p_returned_on<v_borrowed THEN RAISE EXCEPTION 'Invalid return date'; END IF;
 UPDATE loans SET returned_on=p_returned_on,
 fine_amount=GREATEST(p_returned_on-due_on,0)*2.00 WHERE loan_id=p_loan_id;
END; $$;

CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
 IF OLD.returned_on IS DISTINCT FROM NEW.returned_on THEN
  INSERT INTO loan_audit(loan_id,old_returned_on,new_returned_on)
  VALUES(NEW.loan_id,OLD.returned_on,NEW.returned_on);
 END IF;
 RETURN NEW;
END; $$;
CREATE TRIGGER trg_loan_audit AFTER UPDATE ON loans
FOR EACH ROW EXECUTE FUNCTION trg_fn_loan_audit();

INSERT INTO books(title) VALUES('Database Systems'),('Computer Networks'),('Operating Systems');
INSERT INTO loans(book_id,borrower_name,borrowed_on,due_on,returned_on,fine_amount) VALUES
(1,'Alice',CURRENT_DATE-20,CURRENT_DATE-10,NULL,0),
(2,'Brian',CURRENT_DATE-8,CURRENT_DATE-2,CURRENT_DATE-2,0),
(3,'Chanda',CURRENT_DATE-15,CURRENT_DATE-7,CURRENT_DATE-4,6),
(1,'David',CURRENT_DATE-5,CURRENT_DATE+2,NULL,0),
(2,'Esther',CURRENT_DATE-12,CURRENT_DATE-5,NULL,0),
(3,'Frank',CURRENT_DATE-9,CURRENT_DATE-1,CURRENT_DATE-1,0);

CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,b.title,l.borrower_name,l.due_on,fn_loan_fine(l.loan_id,CURRENT_DATE) AS fine_as_of_today
FROM loans l JOIN books b ON b.book_id=l.book_id
WHERE l.returned_on IS NULL AND l.due_on<CURRENT_DATE;

CREATE INDEX idx_loans_book_open ON loans(book_id) WHERE returned_on IS NULL;
EXPLAIN SELECT * FROM loans WHERE book_id=1 AND returned_on IS NULL;

CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
 IF p_as_of IS NULL THEN RAISE EXCEPTION 'Date cannot be NULL'; END IF;
 INSERT INTO overdue_summary(snapshot_date,overdue_count,total_fine)
 SELECT p_as_of,COUNT(*)::INTEGER,COALESCE(SUM(GREATEST(p_as_of-due_on,0)*2.00),0)
 FROM loans WHERE returned_on IS NULL AND due_on<p_as_of
 ON CONFLICT(snapshot_date) DO UPDATE SET overdue_count=EXCLUDED.overdue_count,total_fine=EXCLUDED.total_fine;
END; $$;
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM v_overdue_loans;
SELECT * FROM loan_audit;
SELECT * FROM overdue_summary;

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q3-overdue-snapshot','10 0 * * *',
 'CALL q3_library.pr_refresh_overdue(CURRENT_DATE)');
