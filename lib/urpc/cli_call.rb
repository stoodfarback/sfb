# frozen_string_literal: true

module Urpc
  class CliCall
    class Error < StandardError; end

    KV_RE = /\A([a-zA-Z_]\w*)=(.*)\z/

    def self.run
      timeout = 5
      cast = false
      stream = false
      fmt = :inspect

      parser = OptionParser.new do |o|
        o.banner = "usage: urpc-call [options] <rpc_key> <method> [args...]"
        o.on("-t", "--timeout SECONDS", Float) {|v| timeout = v }
        o.on("-c", "--cast") { cast = true }
        o.on("-s", "--stream") { stream = true }
        o.on("-f", "--format FORMAT", %i[inspect json raw]) {|v| fmt = v }
      end
      parser.order!

      rpc_key, *rest = ARGV
      abort(parser.to_s) if !rpc_key || rest.empty?

      parsed = if rest.one? && rest.first.include?("(")
        parse_ruby(rest.first)
      else
        parse_cli(rest)
      end

      abort("--cast and --stream are mutually exclusive") if cast && stream

      client = Client.new(rpc_key, timeout: timeout)

      if cast
        client.cast(parsed[:name], *parsed[:args], **parsed[:kargs])
        exit(0)
      end

      if stream
        es = client.stream(parsed[:name], *parsed[:args], **parsed[:kargs])
        es.each_event do |event|
          puts(format_output(fmt, event.type, event.data))
          $stdout.flush
        end
        exit(es.error_value ? 1 : 0)
      end

      result = client.call(parsed[:name], *parsed[:args], **parsed[:kargs])
      puts(format_output(fmt, nil, result))
    rescue => e
      $stderr.puts("Error: #{e.message}")
      exit(1)
    end

    def self.format_output(fmt, type, data)
      case fmt
      when :inspect then type ? "#{type}: #{data.inspect}" : data.inspect
      when :json    then JSON.generate(type ? { type: type.to_s, data: data } : data)
      when :raw     then data.to_s
      end
    end

    def self.parse_cli(args)
      method_name = args.shift
      raise(Error, "no method name given") if !method_name

      positional = []
      kargs = {}

      args.each do |arg|
        if (kw = parse_kv(arg))
          kargs[kw[0]] = kw[1]
        else
          positional << auto_type(arg)
        end
      end

      { name: method_name.to_sym, args: positional, kargs: kargs }
    end

    def self.parse_ruby(expr)
      result = Prism.parse(expr)
      unless result.success?
        diag = result.errors.first
        raise(Error, "syntax error at offset #{diag.location.start_offset}: #{diag.message}")
      end

      node = result.value.statements.body.first
      unless node.is_a?(Prism::CallNode) && node.receiver.nil?
        raise(Error, "expected method call, got: #{node.class}")
      end

      raw_args = node.arguments&.arguments || []
      kargs = {}

      if raw_args.last.is_a?(Prism::KeywordHashNode)
        kargs = prism_node_to_literal(raw_args.pop)
      end

      positional = raw_args.map {|a| prism_node_to_literal(a) }

      { name: node.name, args: positional, kargs: kargs }
    end

    def self.parse_kv(arg)
      m = KV_RE.match(arg)
      return nil if !m
      [m[1].to_sym, auto_type(m[2])]
    end

    def self.auto_type(val)
      return true if val == "true"
      return false if val == "false"
      return if val == "nil"
      if (ret = Integer(val, exception: false))
        return(ret)
      end
      if (ret = Float(val, exception: false))
        return(ret)
      end
      val
    end

    def self.prism_node_to_literal(node)
      case node
      when Prism::IntegerNode then node.value
      when Prism::FloatNode then node.value
      when Prism::StringNode then node.unescaped
      when Prism::SymbolNode then node.unescaped.to_sym
      when Prism::TrueNode then true
      when Prism::FalseNode then false
      when Prism::NilNode then nil
      when Prism::ArrayNode then node.elements.map {|e| prism_node_to_literal(e) }
      when Prism::HashNode then prism_hash_to_literal(node.elements)
      when Prism::KeywordHashNode then prism_hash_to_literal(node.elements)
      else
        raise(Error, "unsupported expression: #{node.slice.inspect} (#{node.class})")
      end
    end

    def self.prism_hash_to_literal(pairs)
      pairs.each.with_object({}) do |pair, h|
        h[prism_node_to_literal(pair.key)] = prism_node_to_literal(pair.value)
      end
    end
  end
end
