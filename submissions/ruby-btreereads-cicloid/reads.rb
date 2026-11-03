# frozen_string_literal: true

# GET /feed and GET /posts/:id through SQLite's B-tree cursors instead of SQL statements. The documents
# are rendered in ext/lite.c (Lite.feed, Lite.post); this class decides which transaction the cursors
# read in. Pages still come through SQLite's pager, WAL and page cache; only the SQL compiler and
# bytecode engine are skipped.
#
# Outside a write batch the cursors read in their own read transaction, which stays open across
# requests until the store runs SQL (a write batch, a checkpoint, the health check) and calls #close
# first. Inside a batch they read in the batch's write transaction, so they see its rows (and the
# read waits for the COMMIT, like any read in a batch); the store closes them before the COMMIT. All
# writes go through the same connection, so a read never misses a committed write.
#
# A record shaped other than the schema says raises Lite::Fallback, and the store answers with SQL.
class Reads
  def initialize(db)
    @db = db
    @posts = Lite::Cursor.new(db, root("posts"), 0, false)
    @users = Lite::Cursor.new(db, root("users"), 0, false)
    @likes = Lite::Cursor.new(db, root("likes_post_id_idx"), 1, false)       # (post_id, rowid)
    @recent = Lite::Cursor.new(db, root("posts_created_at_id_idx"), 2, true) # (created_at DESC, id DESC)
    @cursors = [@posts, @users, @likes, @recent]
    @open = false
  end

  def close
    return unless @open

    @cursors.each(&:close)
    @db.end_read if @open == :read
    @open = false
  end

  def feed
    open unless @open
    Lite.feed(@recent, @likes, @posts, @users)
  end

  # The post document, or nil if there is no such post.
  def post_document(id)
    open unless @open
    Lite.post(@posts, @likes, @users, id)
  end

  private

  # In a write transaction the cursors join it; otherwise they get a read transaction of their own.
  def open
    if @db.in_transaction?
      @open = :write
    else
      @db.begin_read
      @open = :read
    end
    @cursors.each(&:open)
  end

  def root(name)
    statement = @db.prepare("SELECT rootpage FROM sqlite_schema WHERE name=?1")
    statement.bind_text(1, name)
    raise Lite::Error, "no #{name} in the schema" unless statement.step

    statement.int(0)
  ensure
    statement.reset # a statement left mid-step would hold its own read transaction open
  end
end
