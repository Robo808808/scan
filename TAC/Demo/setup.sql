CREATE TABLE demo_tac_ac (
  id    NUMBER PRIMARY KEY,
  note  VARCHAR2(200),
  ts    TIMESTAMP DEFAULT SYSTIMESTAMP
);

-- Idempotent upsert used by all clients
-- (Replaying the same (id,note) won’t create duplicates)
-- MERGE is deterministic for fixed bind values.
