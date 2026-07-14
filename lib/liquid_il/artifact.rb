# frozen_string_literal: true

require "json"
require "zlib"

module LiquidIL
  # Raised when an artifact was produced by a different Ruby version/platform
  # or LiquidIL runtime/compiler ABI. The caller owns the source and should
  # recompile. Never pass a mismatched binary to load_from_binary: it can crash
  # the VM rather than raising a normal Ruby exception.
  class StaleArtifactError < Error; end

  # Raised when an artifact is structurally invalid or fails its payload checksum.
  class CorruptArtifactError < Error; end

  # Persisted compiled-template format used in memcache/DB.
  #
  # Framed binary v2 (all integers little-endian):
  #
  #   "LQIL"                         4  magic
  #   format version                  1
  #   ruby stamp length               1
  #   ruby stamp              stamp_len  RUBY_VERSION/RUBY_PATCHLEVEL/platform
  #   ABI stamp length                1
  #   ABI stamp                  abi_len  compiler/runtime generated-code ABI
  #   CRC32(payload)                   4  fastest stable full-payload corruption guard
  #   ISeq byte length                4  redundant structural guard
  #   payload byte length             4
  #   payload:
  #     segment count                 1
  #     per segment: type(1), len(4), bytes(len)
  #       type 1: raw ISeq binary (always present)
  #       type 2: JSON partial constants (only when non-empty)
  #       type 3: JSON external partial dependencies (only when non-empty)
  #       type 4: packed literal pool (count + encoding-tagged strings)
  #       type 5: JSON template metadata captured during compilation
  #       type 6: Marshal host-tag compile products (trusted artifacts only)
  #
  # Portable metadata uses JSON. Host-tag compile products are deliberately
  # opaque Ruby objects and use Marshal; this does not introduce a new trust
  # boundary because the same artifact already carries executable Ruby ISeq.
  # Artifacts must be authenticated if their cache can be written by an
  # untrusted party.
  module Artifact
    MAGIC = "LQIL".b.freeze
    VERSION = 2
    RUNTIME_ABI = 1
    COMPILER_ABI = 10
    RUBY_STAMP = "#{RUBY_VERSION}.#{RUBY_PATCHLEVEL}/#{RUBY_PLATFORM}".freeze
    ABI_STAMP = "runtime-#{RUNTIME_ABI}/compiler-#{COMPILER_ABI}".freeze

    SEG_ISEQ = 1
    SEG_PARTIAL_CONSTANTS = 2
    SEG_PARTIAL_DEPS = 3
    SEG_LITERAL_POOL = 4
    SEG_TEMPLATE_METADATA = 5
    SEG_HOST_TAG_METADATA = 6

    MAX_SEGMENTS = 32
    MAX_ARTIFACT_BYTES = 256 * 1024 * 1024

    class << self
      def encode(template)
        iseq = template.iseq_binary
        partial_constants = template.partial_constants
        ext_deps = external_deps(template.respond_to?(:partial_dependencies) ? template.partial_dependencies : nil)
        template_metadata = template.respond_to?(:template_metadata) ? template.template_metadata : nil
        host_tag_metadata = template.respond_to?(:host_tag_metadata) ? template.host_tag_metadata : nil

        segments = [[SEG_ISEQ, iseq]]
        if partial_constants && !partial_constants.empty?
          if partial_constants.is_a?(Array) && partial_constants.all? { |value| value.is_a?(String) }
            segments << [SEG_LITERAL_POOL, encode_literal_pool(partial_constants)]
          else
            segments << [SEG_PARTIAL_CONSTANTS, encode_json(partial_constants)]
          end
        end
        if ext_deps && !ext_deps.empty?
          segments << [SEG_PARTIAL_DEPS, encode_json(ext_deps)]
        end
        if template_metadata && !template_metadata.empty?
          segments << [SEG_TEMPLATE_METADATA, encode_json(template_metadata)]
        end
        if host_tag_metadata && !host_tag_metadata.empty?
          segments << [SEG_HOST_TAG_METADATA, Marshal.dump(host_tag_metadata)]
        end

        payload = String.new(capacity: 1 + segments.sum { |_type, bytes| 5 + bytes.bytesize }, encoding: Encoding::BINARY)
        payload << segments.length.chr
        segments.each { |type, bytes| payload << [type, bytes.bytesize].pack("CV") << bytes }

        out = String.new(capacity: 4 + 1 + 1 + RUBY_STAMP.bytesize + 1 + ABI_STAMP.bytesize + 12 + payload.bytesize,
                         encoding: Encoding::BINARY)
        out << MAGIC << VERSION.chr
        out << RUBY_STAMP.bytesize.chr << RUBY_STAMP
        out << ABI_STAMP.bytesize.chr << ABI_STAMP
        out << [Zlib.crc32(payload)].pack("V")
        out << [iseq.bytesize, payload.bytesize].pack("VV")
        out << payload
        out
      end

      def external_deps(deps)
        return nil unless deps
        ext = deps.select { |_name, info| info[:disposition] == :external }
        ext.empty? ? nil : ext
      end

      def artifact?(blob)
        blob.is_a?(String) && blob.byteslice(0, 4) == MAGIC
      end

      # Cheap stable identity for an already-validated artifact. For v2 this is
      # the validated payload checksum embedded in the header, so cache-hit
      # checks do not hash the full blob a second time. Full verification still
      # happens on every cache miss before the ISeq is loaded.
      def identity(blob)
        return Zlib.crc32(blob) unless artifact?(blob)
        pos = 4
        return Zlib.crc32(blob) unless blob.getbyte(pos) == VERSION
        pos += 1
        stamp_len = read_byte(blob, pos); pos += 1
        stamp = read_exact(blob, pos, stamp_len); pos += stamp_len
        return Zlib.crc32(blob) unless stamp == RUBY_STAMP
        abi_len = read_byte(blob, pos); pos += 1
        abi = read_exact(blob, pos, abi_len); pos += abi_len
        return Zlib.crc32(blob) unless abi == ABI_STAMP
        read_exact(blob, pos, 4).unpack1("V")
      rescue CorruptArtifactError
        Zlib.crc32(blob)
      end

      # Decode the envelope into:
      #   [iseq_bytes, partial_constants, payload_digest, partial_deps,
      #    literal_pool, template_metadata, host_tag_metadata]
      def decode_segments(blob)
        raise CorruptArtifactError, "not a LiquidIL artifact" unless artifact?(blob)
        raise CorruptArtifactError, "artifact exceeds maximum size" if blob.bytesize > MAX_ARTIFACT_BYTES

        pos = 4
        version = read_byte(blob, pos); pos += 1
        unless version == VERSION
          raise StaleArtifactError, "artifact format v#{version}, expected v#{VERSION} — recompile"
        end

        stamp_len = read_byte(blob, pos); pos += 1
        stamp = read_exact(blob, pos, stamp_len); pos += stamp_len
        unless stamp == RUBY_STAMP
          raise StaleArtifactError, "artifact built for Ruby #{stamp}, this is #{RUBY_STAMP} — recompile"
        end

        abi_len = read_byte(blob, pos); pos += 1
        abi = read_exact(blob, pos, abi_len); pos += abi_len
        unless abi == ABI_STAMP
          raise StaleArtifactError, "artifact ABI #{abi}, expected #{ABI_STAMP} — recompile"
        end

        expected_digest = read_exact(blob, pos, 4).unpack1("V"); pos += 4
        lengths = read_exact(blob, pos, 8); pos += 8
        iseq_len, payload_len = lengths.unpack("VV")
        payload = read_exact(blob, pos, payload_len); pos += payload_len
        raise CorruptArtifactError, "trailing bytes after artifact payload" unless pos == blob.bytesize
        unless Zlib.crc32(payload) == expected_digest
          raise CorruptArtifactError, "artifact digest mismatch — refusing to decode payload"
        end

        payload_pos = 0
        seg_count = read_byte(payload, payload_pos); payload_pos += 1
        raise CorruptArtifactError, "too many artifact segments" if seg_count > MAX_SEGMENTS

        iseq = nil
        partial_constants = nil
        partial_deps = nil
        literal_pool = nil
        template_metadata = nil
        host_tag_metadata = nil
        seen = {}

        seg_count.times do
          type = read_byte(payload, payload_pos)
          len_bytes = read_exact(payload, payload_pos + 1, 4)
          len = len_bytes.unpack1("V")
          payload_pos += 5
          bytes = read_exact(payload, payload_pos, len)
          payload_pos += len

          if type.between?(SEG_ISEQ, SEG_HOST_TAG_METADATA)
            raise CorruptArtifactError, "duplicate artifact segment type #{type}" if seen[type]
            seen[type] = true
          end

          case type
          when SEG_ISEQ
            iseq = bytes.freeze
          when SEG_PARTIAL_CONSTANTS
            partial_constants = deep_freeze(JSON.parse(bytes, create_additions: false))
          when SEG_PARTIAL_DEPS
            partial_deps = normalize_partial_deps(JSON.parse(bytes, create_additions: false))
          when SEG_LITERAL_POOL
            literal_pool = decode_literal_pool(bytes)
          when SEG_TEMPLATE_METADATA
            value = JSON.parse(bytes, create_additions: false)
            raise CorruptArtifactError, "template metadata must be an object" unless value.is_a?(Hash)
            template_metadata = deep_freeze(value)
          when SEG_HOST_TAG_METADATA
            value = Marshal.load(bytes)
            raise CorruptArtifactError, "host tag metadata must be an object" unless value.is_a?(Hash)
            host_tag_metadata = value
          end
          # Unknown segment types are skipped for forward-compatible readers.
        rescue JSON::ParserError => e
          raise CorruptArtifactError, "invalid artifact metadata: #{e.message}"
        end

        raise CorruptArtifactError, "trailing bytes inside artifact payload" unless payload_pos == payload.bytesize
        raise CorruptArtifactError, "artifact has no ISeq segment" unless iseq
        raise CorruptArtifactError, "artifact ISeq length mismatch" unless iseq.bytesize == iseq_len

        partial_constants ||= literal_pool
        [iseq, partial_constants, expected_digest, partial_deps, literal_pool,
         template_metadata, host_tag_metadata]
      rescue CorruptArtifactError, StaleArtifactError
        raise
      rescue StandardError => e
        raise CorruptArtifactError, "invalid artifact structure: #{e.message}"
      end

      def load(blob)
        if artifact?(blob)
          iseq, partial_constants, _digest, _partial_deps, _literal_pool,
            template_metadata, host_tag_metadata = decode_segments(blob)
          Template.from_iseq_binary(
            iseq,
            partial_constants: partial_constants,
            template_metadata: template_metadata,
            host_tag_metadata: host_tag_metadata,
          )
        else
          # Trusted transition-only compatibility path for pre-v1 Marshal hash payloads.
          Template.from_cache(**Marshal.load(blob))
        end
      end

      def load_compiled(blob)
        if artifact?(blob)
          iseq, partial_constants, payload_digest, partial_deps, _literal_pool,
            template_metadata, host_tag_metadata = decode_segments(blob)
          compiled_proc = RubyVM::InstructionSequence.load_from_binary(iseq).eval
          CompiledArtifact.new(compiled_proc, partial_constants, blob.bytesize,
            payload_digest, partial_deps, template_metadata, host_tag_metadata)
        else
          data = Marshal.load(blob)
          compiled_proc = RubyVM::InstructionSequence.load_from_binary(data[:iseq_binary]).eval
          CompiledArtifact.new(compiled_proc, data[:partial_constants], blob.bytesize,
            Zlib.crc32(blob))
        end
      end

      private

      def encode_literal_pool(strings)
        capacity = 4 + strings.sum { |value| 1 + value.encoding.name.bytesize + 4 + value.bytesize }
        out = String.new(capacity: capacity, encoding: Encoding::BINARY)
        out << [strings.length].pack("V")
        strings.each do |value|
          encoding_name = value.encoding.name
          raise ArgumentError, "literal encoding name is too long" if encoding_name.bytesize > 255
          out << encoding_name.bytesize.chr << encoding_name
          out << [value.bytesize].pack("V") << value.b
        end
        out
      end

      def decode_literal_pool(bytes)
        count = read_exact(bytes, 0, 4).unpack1("V")
        raise CorruptArtifactError, "too many literal-pool entries" if count > 1_000_000
        pos = 4
        values = Array.new(count)
        count.times do |index|
          encoding_length = read_byte(bytes, pos); pos += 1
          encoding_name = read_exact(bytes, pos, encoding_length); pos += encoding_length
          encoding = Encoding.find(encoding_name)
          length = read_exact(bytes, pos, 4).unpack1("V"); pos += 4
          value = read_exact(bytes, pos, length); pos += length
          values[index] = value.dup.force_encoding(encoding).freeze
        end
        raise CorruptArtifactError, "trailing bytes in literal pool" unless pos == bytes.bytesize
        values.freeze
      end

      def encode_json(value)
        JSON.generate(value).b
      rescue JSON::GeneratorError, TypeError => e
        raise ArgumentError, "artifact metadata must contain JSON-safe values: #{e.message}"
      end

      def read_byte(bytes, pos)
        bytes.getbyte(pos) || raise(CorruptArtifactError, "truncated artifact")
      end

      def read_exact(bytes, pos, length)
        value = bytes.byteslice(pos, length)
        if value.nil? || value.bytesize != length
          raise CorruptArtifactError, "truncated artifact"
        end
        value
      end

      def normalize_partial_deps(value)
        raise CorruptArtifactError, "partial dependencies must be an object" unless value.is_a?(Hash)
        value.each_value do |info|
          raise CorruptArtifactError, "partial dependency must be an object" unless info.is_a?(Hash)
          disposition = info.delete("disposition") || info.delete(:disposition)
          normalized = {}
          info.each { |key, item| normalized[key.to_sym] = deep_freeze(item) }
          normalized[:disposition] = disposition.to_sym if disposition
          info.replace(normalized.freeze)
        end
        deep_freeze(value)
      end

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, item| deep_freeze(key); deep_freeze(item) }
        when Array
          value.each { |item| deep_freeze(item) }
        end
        value.freeze
      end
    end
  end
end
