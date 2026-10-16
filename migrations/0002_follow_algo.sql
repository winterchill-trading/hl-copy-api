-- The execution algorithm of a follow, in execution-algos' short form ("twap:1m:6",
-- "adaptive:20s", ...). NULL is the default, immediate execution, so rows written before
-- this column existed keep their meaning.
ALTER TABLE follows ADD COLUMN algo text;
