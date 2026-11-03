# frozen_string_literal: true

require "async"
require_relative "app"

host = ENV.fetch("HOST", "127.0.0.1")
port = Integer(ENV.fetch("PORT", "3000"))
store = Store.new(ENV.fetch("SQLITE_PATH"))
app = App.new(store, ENV.fetch("JWT_SECRET"))
# Client connections as io_uring direct descriptors where the kernel allows it, else in epoll.
# CONNECTIONS=epoll forces the fallback.
server = begin
  raise LoadError, "CONNECTIONS=epoll" if ENV["CONNECTIONS"] == "epoll"

  require_relative "uring_server"
  UringServer.new(app, host, port)
rescue LoadError, SystemCallError => error
  $stderr.puts "io_uring connections unavailable (#{error.message}); using epoll"
  require_relative "epoll_server"
  EpollServer.new(app, host, port)
end

# Warm YJIT before listening: reads, a JWT verification and a body parse, 50 times each (the call
# threshold is 5). Nothing is written: the post body fails validation after it is parsed, and the
# like has an invalid id. The token is signed with libsodium, which is loaded anyway.
key = ENV.fetch("JWT_SECRET").b.ljust(32, "\0")
claims = [{ sub: "1", username: "warmup", exp: Time.now.to_i + 3600 }.to_json].pack("m0").tr("+/", "-_").delete("=")
signing_input = "#{App::HS256_HEADER}.#{claims}".b
mac = String.new("\0" * 32, encoding: Encoding::BINARY)
Sodium.hmac_sha256(mac, signing_input, signing_input.bytesize, key)
auth = "Authorization: Bearer #{signing_input}.#{[mac].pack("m0").tr("+/", "-_").delete("=")}\r\n"
server.warm([
  "GET /feed HTTP/1.1\r\nHost: x\r\n\r\n",
  "GET /posts/1 HTTP/1.1\r\nHost: x\r\n\r\n",
  "POST /posts HTTP/1.1\r\nHost: x\r\n#{auth}Content-Length: 11\r\n\r\n{\"body\":\"\"}",
  "POST /posts/0/like HTTP/1.1\r\nHost: x\r\n#{auth}\r\n"
], 50)

GC.compact
Process.warmup if Process.respond_to?(:warmup)
# No automatic full GCs while serving: little survives a request, and each full GC stops the
# reactor for tens of milliseconds. Without them old objects are never freed, so a full GC still
# runs if they grow past three times what the warm-up left.
GC.config(rgengc_allow_full_mark: false)
old_objects_cap = GC.stat(:old_objects) * 3

Async do |task|
  task.async do
    loop do
      sleep 10
      next if GC.stat(:old_objects) < old_objects_cap

      GC.start
      old_objects_cap = GC.stat(:old_objects) * 3
    end
  end
  task.async do
    loop do
      sleep 1
      store.checkpoint
    end
  end

  server.run(task)
  compiled = RubyVM::YJIT.enabled? ? "#{RubyVM::YJIT.runtime_stats[:compiled_iseq_count]} iseqs compiled" : "YJIT off"
  $stderr.puts "listening on #{host}:#{port} (#{server.class}, #{compiled})"
end
