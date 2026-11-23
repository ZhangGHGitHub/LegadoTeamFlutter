DROP TRIGGER IF EXISTS qa9b1_fail_delete;
CREATE TRIGGER qa9b1_fail_delete BEFORE DELETE ON searchBooks BEGIN SELECT RAISE(ABORT, 'QA9B1 injected delete failure'); END;
