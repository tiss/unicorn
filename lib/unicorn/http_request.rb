require 'tempfile'
require 'stringio'

# compiled extension
require 'unicorn/http11'

module Unicorn
  #
  # The HttpRequest.initialize method will convert any request that is larger than
  # Const::MAX_BODY into a Tempfile and use that as the body.  Otherwise it uses 
  # a StringIO object.  To be safe, you should assume it works like a file.
  # 
  class HttpRequest

     # default parameters we merge into the request env for Rack handlers
     DEF_PARAMS = {
       "rack.errors" => $stderr,
       "rack.multiprocess" => true,
       "rack.multithread" => false,
       "rack.run_once" => false,
       "rack.version" => [0, 1].freeze,
       "SCRIPT_NAME" => "".freeze,

       # this is not in the Rack spec, but some apps may rely on it
       "SERVER_SOFTWARE" => "Unicorn #{Const::UNICORN_VERSION}".freeze
     }.freeze

    def initialize(logger)
      @logger = logger
      @body = nil
      @buffer = ' ' * Const::CHUNK_SIZE # initial size, may grow
      @parser = HttpParser.new
      @params = Hash.new
    end

    def reset
      @parser.reset
      @params.clear
      @body.close rescue nil
      @body.close! rescue nil
      @body = nil
    end

    # Does the majority of the IO processing.  It has been written in
    # Ruby using about 8 different IO processing strategies.
    #
    # It is currently carefully constructed to make sure that it gets
    # the best possible performance for the common case: GET requests
    # that are fully complete after a single read(2)
    #
    # Anyone who thinks they can make it faster is more than welcome to
    # take a crack at it.
    #
    # returns an environment hash suitable for Rack if successful
    # This does minimal exception trapping and it is up to the caller
    # to handle any socket errors (e.g. user aborted upload).
    def read(socket)
      # From http://www.ietf.org/rfc/rfc3875:
      # "Script authors should be aware that the REMOTE_ADDR and
      #  REMOTE_HOST meta-variables (see sections 4.1.8 and 4.1.9)
      #  may not identify the ultimate source of the request.  They
      #  identify the client for the immediate request to the server;
      #  that client may be a proxy, gateway, or other intermediary
      #  acting on behalf of the actual source client."
      @params[Const::REMOTE_ADDR] =
                    TCPSocket === socket ? socket.peeraddr.last : '127.0.0.1'

      # short circuit the common case with small GET requests first
      @parser.execute(@params, read_socket(socket)) and
          return handle_body(socket)

      data = @buffer.dup # read_socket will clobber @buffer

      # Parser is not done, queue up more data to read and continue parsing
      # an Exception thrown from the @parser will throw us out of the loop
      loop do
        data << read_socket(socket)
        @parser.execute(@params, data) and return handle_body(socket)
      end
      rescue HttpParserError => e
        @logger.error "HTTP parse error, malformed request " \
                      "(#{@params[Const::HTTP_X_FORWARDED_FOR] ||
                          @params[Const::REMOTE_ADDR]}): #{e.inspect}"
        @logger.error "REQUEST DATA: #{data.inspect}\n---\n" \
                      "PARAMS: #{@params.inspect}\n---\n"
        raise e
    end

    private

    # Handles dealing with the rest of the request
    # returns a Rack environment if successful, raises an exception if not
    def handle_body(socket)
      http_body = @params.delete(:http_body)
      content_length = @params[Const::CONTENT_LENGTH].to_i
      remain = content_length - http_body.length

      # must read more data to complete body
      @body = remain < Const::MAX_BODY ? StringIO.new : Tempfile.new('')
      @body.binmode
      @body.sync = true
      @body.syswrite(http_body)

      # Some clients (like FF1.0) report 0 for body and then send a body.
      # This will probably truncate them but at least the request goes through
      # usually.
      read_body(socket, remain) if remain > 0
      @body.rewind
      @body.sysseek(0) if @body.respond_to?(:sysseek)

      # in case read_body overread because the client tried to pipeline
      # another request, we'll truncate it.  Again, we don't do pipelining
      # or keepalive
      @body.truncate(content_length)
      rack_env(socket)
    end

    # Returns an environment which is rackable:
    # http://rack.rubyforge.org/doc/files/SPEC.html
    # Based on Rack's old Mongrel handler.
    def rack_env(socket)
      # I'm considering enabling "unicorn.client".  It gives
      # applications some rope to do some "interesting" things like
      # replacing a worker with another process that has full control
      # over the HTTP response.
      # @params["unicorn.client"] = socket

      @params[Const::RACK_INPUT] = @body
      @params.update(DEF_PARAMS)
    end

    # Does the heavy lifting of properly reading the larger body requests in
    # small chunks.  It expects @body to be an IO object, socket to be valid,
    # It also expects any initial part of the body that has been read to be in
    # the @body already.  It will return true if successful and false if not.
    def read_body(socket, remain)
      while remain > 0
        # writes always write the requested amount on a POSIX filesystem
        remain -= @body.syswrite(read_socket(socket))
      end
    rescue Object => e
      @logger.error "Error reading HTTP body: #{e.inspect}"

      # Any errors means we should delete the file, including if the file
      # is dumped.  Truncate it ASAP to help avoid page flushes to disk.
      @body.truncate(0) rescue nil
      reset
      raise e
    end

    # read(2) on "slow" devices like sockets can be interrupted by signals
    def read_socket(socket)
      begin
        socket.sysread(Const::CHUNK_SIZE, @buffer)
      rescue Errno::EINTR
        retry
      end
    end

  end
end
