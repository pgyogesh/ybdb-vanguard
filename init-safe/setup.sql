-- init-safe — Safe Node Takedown
-- One table, ONE tablet, lots of rows. With RF3 that single tablet has three
-- Raft peers (one per node); the large row count makes a lost replica slow to
-- rebuild — which is exactly what are_nodes_safe_to_take_down is there to catch.
DROP TABLE IF EXISTS big;
CREATE TABLE big (id int PRIMARY KEY, v text) SPLIT INTO 1 TABLETS;
INSERT INTO big SELECT g, repeat('x', 1000) FROM generate_series(1, 100000) g;
