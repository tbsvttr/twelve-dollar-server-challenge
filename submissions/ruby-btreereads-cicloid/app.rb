# frozen_string_literal: true

require "async"
require "async/promise"
require_relative "ext/lite"
require "json"
require "rbnacl"
require_relative "reads"

# libsodium's one-shot HMAC-SHA256 and constant-time compare, bound through rbnacl's FFI layer.
module Sodium
  extend RbNaCl::Sodium

  sodium_function :hmac_sha256, :crypto_auth_hmacsha256, %i[pointer pointer ulong_long pointer]
  sodium_function :verify32, :crypto_verify_32, %i[pointer pointer]
end

# One SQLite connection, owned by the single reactor thread. Reads go through SQLite's B-tree cursors
# (reads.rb); writes, the health check and checkpoints are SQL. SQLite renders the documents a write
# returns; Ruby renders the read documents.
#
# Group commit: the first write in a reactor pass opens BEGIN IMMEDIATE and schedules one COMMIT
# for the next pass. Every write in between joins that transaction, and every response waits for
# the COMMIT. Reads that run while a batch is open may have seen its rows, so they wait too.
class Store
  POST_JSON = "json_object('id',p.id,'body',p.body,'created_at',p.created_at,'author',u.username," \
              "'like_count',(SELECT count(*) FROM likes l WHERE l.post_id=p.id))"
  # group_concat keeps the subquery's order.
  FEED = "SELECT '{\"posts\":['||coalesce(group_concat(#{POST_JSON},','),'')||']}' " \
         "FROM (SELECT id,user_id,body,created_at FROM posts ORDER BY created_at DESC,id DESC LIMIT 20) p " \
         "JOIN users u ON u.id=p.user_id"
  # `+?`, not `?`: with the join, SQLite's constant propagation makes the plan depend on the bound
  # id, so every new id would recompile the statement (twice the cost of running it).
  POST = "SELECT '{\"post\":'||#{POST_JSON}||'}' FROM posts p JOIN users u ON u.id=p.user_id WHERE p.id=+?"
  CREATE = "INSERT INTO posts(user_id,body) VALUES(?1,?2) RETURNING '{\"post\":'||json_object('id',id," \
           "'body',body,'created_at',created_at,'author',?3,'like_count',0)||'}'"
  LIKE = "INSERT INTO likes(user_id,post_id) SELECT ?1,?2 WHERE EXISTS(SELECT 1 FROM posts WHERE id=?2) " \
         "ON CONFLICT(user_id,post_id) DO NOTHING"
  EXISTS = "SELECT 1 FROM posts WHERE id=?"

  def initialize(path)
    @db = Lite::DB.new(path)
    # locking_mode=EXCLUSIVE first, so the WAL index lives in heap memory rather than the -shm file.
    @db.exec("PRAGMA locking_mode=EXCLUSIVE")
    @db.exec("PRAGMA journal_mode=WAL")
    @db.exec("PRAGMA synchronous=NORMAL")
    @db.exec("PRAGMA foreign_keys=ON")
    @db.exec("PRAGMA wal_autocheckpoint=0") # checkpoints run on a timer, off the commit path
    @db.exec("PRAGMA mmap_size=1073741824")
    @db.exec("PRAGMA cache_size=-65536")
    @db.exec("PRAGMA temp_store=MEMORY")
    @feed = @db.prepare(FEED)
    @post = @db.prepare(POST)
    @create = @db.prepare(CREATE)
    @like = @db.prepare(LIKE)
    @exists = @db.prepare(EXISTS)
    @ping = @db.prepare("SELECT 1")
    @reads = Reads.new(@db)
    @batch = nil
    @checkpoint_due = false
  end

  def feed
    document = begin
      @reads.feed
    rescue Lite::Fallback => error
      fell_back(error)
      return sql_read(@feed)
    end
    @batch&.wait
    document
  end

  def post(id)
    document = begin
      @reads.post_document(id)
    rescue Lite::Fallback => error
      fell_back(error)
      return sql_read(@post.bind_int(1, id))
    end
    @batch&.wait
    document
  end

  def create(user_id, username, body)
    batch = begin_batch
    document = row(@create.bind_int(1, user_id).bind_text(2, body).bind_text(3, username))
    batch.wait
    document
  end

  # Returns :liked, :already_liked or :missing.
  def like(user_id, post_id)
    batch = begin_batch
    @like.bind_int(1, user_id).bind_int(2, post_id)
    begin
      @like.step
    ensure
      @like.reset
    end
    outcome = if @db.changes == 1 then :liked
              elsif row(@exists.bind_int(1, post_id)) then :already_liked
              else :missing
              end
    batch.wait
    outcome
  end

  def ping
    @reads.close
    row(@ping)
  end

  # While a write batch is open, reads wait for its COMMIT.
  def writing?
    !@batch.nil?
  end

  # Called every second. A checkpoint can't run inside a write batch, so then it runs right after
  # that batch commits.
  def checkpoint
    if @batch
      @checkpoint_due = true
    else
      checkpoint!
    end
  end

  private

  # Logs the first read that falls back to SQL: the answer is still right, only slower, so nothing
  # else would show it.
  def fell_back(error)
    return if @fell_back

    @fell_back = true
    warn "a B-tree read fell back to SQL (#{error.class} at #{error.backtrace&.first}); later ones are not logged"
  end

  # The first column of the statement's first row, or nil. Every statement is reset as soon as its
  # row is taken: a statement left mid-step keeps its read transaction open, and while it is open no
  # checkpoint can run.
  def row(statement)
    statement.step ? statement.text(0) : nil
  ensure
    statement.reset
  end

  # A read through SQL. Outside a batch the B-tree read transaction ends first: SQL statements run in
  # autocommit and would end it under the open cursors.
  def sql_read(statement)
    @reads.close unless @batch
    document = row(statement)
    @batch&.wait
    document
  end

  # Synchronous, so nothing else runs between BEGIN and joining the batch.
  def begin_batch
    return @batch if @batch

    @reads.close
    @db.exec("BEGIN IMMEDIATE")
    batch = @batch = Async::Promise.new
    Async do |task|
      task.yield # let every request that is ready in this pass join the batch
      commit(batch)
    end
    batch
  end

  def commit(batch)
    @batch = nil
    @reads.close # cursors in the write transaction close before it ends
    begin
      @db.exec("COMMIT")
    rescue Lite::Error => error
      @db.exec("ROLLBACK") if @db.in_transaction?
      return batch.reject(error)
    end
    batch.resolve(true)
    checkpoint! if @checkpoint_due
  end

  def checkpoint!
    @checkpoint_due = false
    @reads.close
    @db.exec("PRAGMA wal_checkpoint(PASSIVE)")
  rescue Lite::Error => error
    warn "checkpoint failed: #{error.message}" # retried on the next tick
  end
end

# The API: routes a parsed request and returns [status, json_document]. Transport-free.
class App
  HS256_HEADER = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9" # {"alg":"HS256","typ":"JWT"}
  BASE64URL = /\A[A-Za-z0-9_-]+\z/
  POSTS_PREFIX = "/posts/"
  LIKE_SUFFIX = "/like"
  POSITIVE_ID = /\A[0-9]+\z/
  MAX_ID = 9_223_372_036_854_775_807
  # JavaScript's String#trim set, so trimming matches the reference implementations.
  SPACE = "\u0009-\u000d    -     　﻿"
  TRIM = /\A[#{SPACE}]+|[#{SPACE}]+\z/

  NOT_FOUND = '{"error":"not found"}'
  INVALID_ID = '{"error":"invalid post id"}'
  POST_NOT_FOUND = '{"error":"post not found"}'
  MISSING_TOKEN = '{"error":"missing bearer token"}'
  INVALID_TOKEN = '{"error":"invalid or expired token"}'
  INVALID_PAYLOAD = '{"error":"invalid token payload"}'
  MALFORMED = '{"error":"malformed JSON body"}'
  BODY_REQUIRED = '{"error":"body is required"}'
  BODY_TOO_LONG = '{"error":"body must be at most 500 characters"}'
  INTERNAL = '{"error":"internal server error"}'
  # Parser options are resolved once here, not on every parse.
  CODER = JSON::Coder.new
  EMPTY = ""

  # Thrown with [status, document] to answer early.
  class Halt < StandardError
    attr_reader :status, :document

    def initialize(status, document)
      super()
      @status = status
      @document = document
    end
  end

  def initialize(store, secret)
    @store = store
    @key = secret.b.ljust(32, "\0") # HMAC zero-pads keys up to the block size: same MAC
    raise ArgumentError, "JWT_SECRET longer than 32 bytes is not supported" if @key.bytesize > 32

    @mac = String.new("\0" * 32, encoding: Encoding::BINARY)
    @started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # True while reads would wait for a write batch to commit; otherwise a GET never suspends its fiber.
  def writing?
    @store.writing?
  end

  # `path` excludes the query string; `authorization` is the raw header value or nil.
  def call(method, path, authorization, body)
    if method == "GET"
      return [200, @store.feed] if path == "/feed"
      return health if path == "/health"
    elsif method == "POST" && path == "/posts"
      return create(authorization, body)
    end

    # /posts/:id and /posts/:id/like
    if path.start_with?(POSTS_PREFIX)
      liking = path.bytesize >= POSTS_PREFIX.bytesize + LIKE_SUFFIX.bytesize && path.end_with?(LIKE_SUFFIX)
      last = liking ? path.bytesize - LIKE_SUFFIX.bytesize : path.bytesize
      unless path.index("/", POSTS_PREFIX.bytesize)&.< last
        if method == "GET" && !liking
          id = post_id(path.byteslice(POSTS_PREFIX.bytesize, last - POSTS_PREFIX.bytesize))
          document = @store.post(id) or raise Halt.new(404, POST_NOT_FOUND)
          return [200, document]
        elsif method == "POST" && liking
          user_id, = authenticate(authorization)
          return like(user_id, post_id(path.byteslice(POSTS_PREFIX.bytesize, last - POSTS_PREFIX.bytesize)))
        end
      end
    end
    [404, NOT_FOUND]
  rescue Halt => halt
    [halt.status, halt.document]
  rescue StandardError => error
    Console.error(self, error)
    [500, INTERNAL]
  end

  private

  def health
    @store.ping
    uptime = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started).to_i
    [200, %({"status":"ok","db":"ok","uptime_s":#{uptime}})]
  rescue Lite::Error => error
    [503, JSON.generate({ status: "degraded", db: "unreachable", error: error.message })]
  end

  def create(authorization, raw)
    user_id, username = authenticate(authorization)
    raw = raw ? raw.force_encoding(Encoding::UTF_8) : EMPTY
    raise Halt.new(400, MALFORMED) unless raw.valid_encoding? # the parser does not check UTF-8 itself

    payload = begin
      CODER.load(raw)
    rescue JSON::ParserError
      raise Halt.new(400, MALFORMED)
    end
    body = payload["body"] if payload.is_a?(Hash)
    raise Halt.new(400, BODY_REQUIRED) unless body.is_a?(String)

    body = body.gsub(TRIM, "")
    raise Halt.new(400, BODY_REQUIRED) if body.empty?
    raise Halt.new(400, BODY_TOO_LONG) if body.length > 500

    [201, @store.create(user_id, username, body)]
  end

  def like(user_id, id)
    case @store.like(user_id, id)
    when :liked then [201, %({"liked":true,"already_liked":false,"post_id":#{id}})]
    when :already_liked then [200, %({"liked":true,"already_liked":true,"post_id":#{id}})]
    else [404, POST_NOT_FOUND]
    end
  end

  def post_id(text)
    raise Halt.new(400, INVALID_ID) unless POSITIVE_ID.match?(text)

    id = text.to_i
    raise Halt.new(400, INVALID_ID) if id.zero?
    raise Halt.new(404, POST_NOT_FOUND) if id > MAX_ID

    id
  end

  # Verifies the HS256 signature and expiry on every request. Returns [user_id, username].
  def authenticate(header)
    raise Halt.new(401, MISSING_TOKEN) unless header&.start_with?("Bearer ")

    token = header.byteslice(7, header.bytesize - 7)
    first = token.index(".")
    last = token.rindex(".")
    raise Halt.new(401, INVALID_TOKEN) unless first && first != last

    head = token.byteslice(0, first)
    payload = token.byteslice(first + 1, last - first - 1)
    signature = token.byteslice(last + 1, token.bytesize - last - 1)
    raise Halt.new(401, INVALID_TOKEN) unless signature.bytesize == 43 && BASE64URL.match?(signature)

    signing_input = token.byteslice(0, last).b
    Sodium.hmac_sha256(@mac, signing_input, signing_input.bytesize, @key)
    raise Halt.new(401, INVALID_TOKEN) unless Sodium.verify32(@mac, decode64(signature))

    unless head == HS256_HEADER
      fields = parse_segment(head)
      raise Halt.new(401, INVALID_TOKEN) unless fields.is_a?(Hash) && fields["alg"] == "HS256"
    end

    claims = parse_segment(payload)
    raise Halt.new(401, INVALID_TOKEN) unless claims.is_a?(Hash)

    now = Time.now.to_f
    exp = claims["exp"]
    raise Halt.new(401, INVALID_TOKEN) unless exp.is_a?(Numeric) && exp > now

    nbf = claims["nbf"]
    raise Halt.new(401, INVALID_TOKEN) if nbf && !(nbf.is_a?(Numeric) && nbf <= now)

    sub = claims["sub"]
    username = claims["username"]
    unless sub.is_a?(String) && POSITIVE_ID.match?(sub) && username.is_a?(String) &&
           (user_id = sub.to_i).positive? && user_id <= MAX_ID
      raise Halt.new(401, INVALID_PAYLOAD)
    end

    [user_id, username]
  end

  def parse_segment(segment)
    raise Halt.new(401, INVALID_TOKEN) unless BASE64URL.match?(segment) && segment.bytesize % 4 != 1

    CODER.load(decode64(segment)) # a BINARY source is read as UTF-8
  rescue JSON::ParserError, ArgumentError, EncodingError
    raise Halt.new(401, INVALID_TOKEN)
  end

  def decode64(segment)
    padded = segment.tr("-_", "+/")
    padded << ("=" * (-segment.bytesize % 4))
    padded.unpack1("m0")
  rescue ArgumentError
    raise Halt.new(401, INVALID_TOKEN)
  end
end
