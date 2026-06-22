-- reset.sql — restore the baseline between scenarios (Alice=1000, both on call)
UPDATE accounts SET balance = 1000 WHERE id = 1;
UPDATE oncall   SET is_oncall = true;
