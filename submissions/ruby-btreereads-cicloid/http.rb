# frozen_string_literal: true

require "socket"

# A small HTTP/1.1 server on the Async reactor (io-event: io_uring or epoll), specialised for this API:
# it parses the request line and the four headers the API needs, and writes each response with one
# write. Requests are handled in order per connection (pipelining works); bodies use Content-Length.
#
# This class is the HTTP side; the connection layer is a subclass. UringServer (uring_server.rb)
# keeps clients as io_uring direct descriptors, outside the process descriptor table; EpollServer
# (epoll_server.rb) keeps them as sockets in an epoll set, and is the fallback where io_uring is
# unavailable. In both, idle connections own no fiber: a pool of worker fibers serves the
# connections that have new bytes. A fiber per connection would keep the stack pages each one
# touched while serving (deep SQLite calls), which costs ~70 KB per idle connection.
class HTTPServer
  MAX_HEAD = 16 * 1024
  MAX_BODY = 1024 * 1024
  WORKERS = 256
  MAX_WORKERS = 4096 # the pool grows past WORKERS only if every worker is busy

  REASONS = {
    200 => "OK", 201 => "Created", 400 => "Bad Request", 401 => "Unauthorized", 404 => "Not Found",
    411 => "Length Required", 413 => "Content Too Large", 431 => "Request Header Fields Too Large",
    500 => "Internal Server Error", 503 => "Service Unavailable"
  }.freeze
  # Response heads up to "content-length: "; the length, a blank line and the body follow.
  def self.heads(extra)
    REASONS.to_h { |code, reason| [code, "HTTP/1.1 #{code} #{reason}\r\n#{extra}content-type: application/json\r\ncontent-length: ".freeze] }.freeze
  end
  KEEP = heads("")
  KEEP_10 = heads("connection: keep-alive\r\n") # HTTP/1.0 clients that asked for keep-alive
  CLOSE = heads("connection: close\r\n")
  END_HEAD = "\r\n\r\n"
  CRLF = "\r\n"
  # The only request headers the API needs. Names are told apart by length. The value is taken
  # greedily and trailing blanks are trimmed afterwards: a lazy `[^\r\n]*?` with a lookahead
  # backtracks along a 200-byte bearer token and took 5.7 µs on a POST head, against 2.9 µs now.
  HEADER = /\r\n(content-length|transfer-encoding|connection|authorization)[ \t]*:[ \t]*([^\r\n]*)/i
  TRAILING_BLANKS = /[ \t]+\z/
  DIGITS = /\A[0-9]+\z/
  CLOSE_TOKEN = /\bclose\b/i
  KEEP_ALIVE_TOKEN = /\bkeep-alive\b/i
  EMPTY = ""
  FEED = "/feed"
  GET = "GET"
  POST = "POST"
  # Checked in place (`match?` at an offset allocates nothing), so the common request line costs no
  # strings: only a path other than the feed is sliced out.
  HTTP_11_AT = %r{\GHTTP/1\.1\r\n}
  HTTP_10_AT = %r{\GHTTP/1\.0\r\n}
  GET_AT = /\GGET /
  POST_AT = /\GPOST /
  FEED_AT = %r{\G/feed[ ?]}

  # `capacity` is how many connections the subclass can hold at once.
  def initialize(app, host, port, capacity)
    @app = app
    @server = TCPServer.new(host, port)
    @server.listen(65_535) # the kernel caps this at net.core.somaxconn
    # Accepted sockets inherit TCP_NODELAY from the listener on Linux: no setsockopt per connection.
    @server.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    # Close to capacity, responses carry `Connection: close` so idle clients give their slot back.
    # Past @budget only responses other than the feed close: a client that just read the feed opens
    # a post seconds later, while after a post it thinks longest, so each close frees a slot for
    # longer and fewer reconnects are needed. Past @hard_budget every response closes, which keeps
    # the connections below capacity so `accept` never fails and new clients never wait on it.
    @hard_budget = [capacity - 256, capacity * 9 / 10].max
    @budget = @hard_budget - 1024
    @open = 0
    @workers = @waiting = 0
  end

  attr_reader :open

  # Runs each request through the parser and the app `times` times over a socket pair, before the
  # reactor starts, so YJIT has compiled the whole request path when the first client arrives.
  def warm(requests, times)
    near, far = UNIXSocket.pair
    times.times do
      requests.each do |request|
        drain(near, request.b)
        far.read_nonblock(1 << 20, exception: false)
      end
    end
    near.close
    far.close
  end

  private

  def add_worker
    @workers += 1
    @task.async { work }
  end

  # --- HTTP/1.1 ---------------------------------------------------------------------------

  # Answers every complete request in `buffer`, in order. Returns the unconsumed tail (possibly
  # empty), or nil when the connection must be closed.
  def drain(socket, buffer)
    position = 0
    size = buffer.bytesize
    while position < size
      head_end = buffer.byteindex(END_HEAD, position)
      unless head_end
        return reject(socket, 431) if size - position > MAX_HEAD

        break
      end

      line_end = buffer.byteindex(CRLF, position)
      space = buffer.byteindex(" ", position)
      space2 = space && buffer.byteindex(" ", space + 1)
      return reject(socket, 400) unless space2 && space > position && space2 < line_end

      version_length = line_end - space2 - 1
      http10 = version_length == 8 && buffer.match?(HTTP_10_AT, space2 + 1)
      return reject(socket, 400) unless http10 || (version_length == 8 && buffer.match?(HTTP_11_AT, space2 + 1))

      method = if space - position == 3 && buffer.match?(GET_AT, position) then GET
               elsif space - position == 4 && buffer.match?(POST_AT, position) then POST
               else buffer.byteslice(position, space - position)
               end
      path = if buffer.match?(FEED_AT, space + 1) then FEED
             else
               query = buffer.byteindex("?", space + 1)
               path_end = query && query < space2 ? query : space2
               buffer.byteslice(space + 1, path_end - space - 1)
             end

      length = 0
      authorization = nil
      close = http10
      # Searched in place: a head without any of these headers allocates nothing. A match past
      # head_end belongs to the body or the next request.
      at = line_end
      while (at = buffer.byteindex(HEADER, at)) && at < head_end
        name = Regexp.last_match(1)
        value = Regexp.last_match(2)
        at += 2
        value = value.sub(TRAILING_BLANKS, "") if value.end_with?(" ", "\t")
        case name.bytesize
        when 14 # content-length
          return reject(socket, 400) unless DIGITS.match?(value)

          length = value.to_i
        when 17 # transfer-encoding: request bodies must use Content-Length
          return reject(socket, 411)
        when 10 # connection
          if CLOSE_TOKEN.match?(value) then close = true
          elsif http10 && KEEP_ALIVE_TOKEN.match?(value) then close = false
          end
        else # authorization
          authorization = value
        end
      end
      return reject(socket, 413) if length > MAX_BODY

      body_start = head_end + 4
      break if size < body_start + length # the body hasn't fully arrived yet

      body = buffer.byteslice(body_start, length) if length.positive?
      status, document = @app.call(method, path, authorization, body)
      close ||= @open > @budget && (path != FEED || @open > @hard_budget)
      respond(socket, close ? CLOSE : (http10 ? KEEP_10 : KEEP), status, document)
      return nil if close

      position = body_start + length
    end

    if position.zero? then buffer
    elsif position >= size then EMPTY
    else buffer.byteslice(position, size - position)
    end
  end

  def reject(socket, status)
    respond(socket, CLOSE, status, %({"error":"#{REASONS[status].downcase}"}))
    nil
  end

  def respond(socket, heads, status, document)
    head = heads[status] || heads[500]
    write_response(socket, head, document.bytesize.to_s, document)
  end

  # Writes head, length, a blank line and the document. The connection layer may copy the parts
  # straight to where they are sent from instead.
  def write_response(socket, head, length, document)
    out = String.new(head, capacity: head.bytesize + length.bytesize + 4 + document.bytesize)
    out << length << END_HEAD << document
    write(socket, out)
  end
end
