# frozen_string_literal: true

# Profile-guided optimization workload for the Lite extension, run by build.sh against an instrumented
# build: builds a synthetic database with the challenge schema, then drives the server's Store (B-tree
# reads, group-committed writes, checkpoints) in roughly the load test's mix. Not part of the server.
#
#   bundle exec ruby train.rb <scratch.db>

require_relative "app"

path = ARGV.fetch(0)
Dir["#{path}*"].each { |file| File.delete(file) }
db = Lite::DB.new(path)
db.exec(<<~SQL)
  PRAGMA journal_mode=WAL;
  CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
  CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id),
    body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
  CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
  CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
  CREATE INDEX posts_user_id_idx ON posts (user_id);
  CREATE INDEX likes_post_id_idx ON likes (post_id);
  BEGIN;
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<5000)
    INSERT INTO users(id,username) SELECT i,'user_'||i FROM n;
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<50000)
    INSERT INTO posts(id,user_id,body,created_at) SELECT i,1+i%5000,
      'post body number '||i||' with some "quoted" text'||char(10)||'and a second line',
      strftime('%Y-%m-%dT%H:%M:%fZ','2025-01-01','+'||i||' seconds') FROM n;
  WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<200000)
    INSERT OR IGNORE INTO likes(user_id,post_id) SELECT 1+(i*7)%5000,1+(i*13)%50000 FROM n;
  COMMIT;
  ANALYZE;
SQL
db.close

store = Store.new(path)
seed = 12_345
Async do
  20_000.times do |i|
    seed = (seed * 1_103_515_245 + 12_345) & 0xffffffff
    store.feed
    store.post(1 + seed % 50_000)
    if i % 7 == 0
      store.like(1 + seed % 5000, 1 + (seed >> 8) % 50_000)
      store.create(1 + seed % 5000, "user_#{1 + seed % 5000}", "a freshly written post body") if i % 49 == 0
    end
    store.checkpoint if i % 1000 == 0
  end
end
Dir["#{path}*"].each { |file| File.delete(file) }
