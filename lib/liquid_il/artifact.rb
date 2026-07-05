# frozen_string_literal: true

require "zlib"

module LiquidIL
  # Raised when an artifact was produced by a different Ruby version/platform
  # (ISeq binaries are not portable). The caller owns the template source —
  # recompile from it and re-persist. NEVER feed a mismatched binary to
  # load_from_binary: it can crash the VM, not just raise.
  class StaleArtifactError < Error; end

  # Raised when an artifact is structurally invalid (truncated, digest
  # mismatch, missing segments). Treat like StaleArtifactError: recompile.
  class CorruptArtifactError < Error; end

  # The persisted compiled-template format — the string you put in
  # memcache/DB and load in a process that has never seen the template.
  #
  #   blob = template.to_artifact           # compile once, persist
  #   ...
  #   t = LiquidIL::Artifact.load(blob)     # different process: load
  #   t.render(assigns)
  #
  # Framed binary v1 (all integers little-endian):
  #
  #   "LQIL"                     4  magic
  #   version                    1  format version (1)
  #   stamp_len                  1
  #   ruby stamp        stamp_len   RUBY_VERSION "/" RUBY_PLATFORM
  #   crc32(iseq)                4  content digest — guards load_from_binary
  #   iseq byte length           4    against corrupted payloads (VM crash)
  #   segment count              1
  #   per segment:  type(1) len(4) bytes(len)
  #     type 1: raw ISeq binary  (always present)
  #     type 2: Marshal'd partial_constants (only when non-empty)
  #
  # Deliberately NOT included: template source. Error locations are
  # compile-time literals baked into the emitted code, so error output is
  # byte-identical without it, and the caller already owns the source
  # (filesystem/DB) if a recompile is ever needed.
  #
  # Legacy Marshal-hash payloads (pre-v1 cache_data dumps) are detected by
  # magic sniffing in .load and still work during the transition window.
  module Artifact
    MAGIC = "LQIL"
    VERSION = 1
    RUBY_STAMP = "#{RUBY_VERSION}/#{RUBY_PLATFORM}".freeze

    SEG_ISEQ = 1
    SEG_PARTIAL_CONSTANTS = 2
    # External partial references only ({name => {digest:, disposition: :external}}):
    # lets a loaded artifact report which per-file artifacts a host must
    # prefetch. Added ONLY when external partials exist, so artifacts compiled
    # without a partial_index (every existing user) stay byte-identical.
    SEG_PARTIAL_DEPS = 3

    class << self
      # Encode a compiled Template into the persistable artifact string.
      def encode(template)
        iseq = template.iseq_binary
        partial_constants = template.partial_constants
        ext_deps = external_deps(template.respond_to?(:partial_dependencies) ? template.partial_dependencies : nil)

        out = MAGIC.b
        out << VERSION.chr
        out << RUBY_STAMP.bytesize.chr << RUBY_STAMP
        out << [Zlib.crc32(iseq), iseq.bytesize].pack("VV")

        segments = [[SEG_ISEQ, iseq]]
        if partial_constants && !partial_constants.empty?
          segments << [SEG_PARTIAL_CONSTANTS, Marshal.dump(partial_constants)]
        end
        if ext_deps && !ext_deps.empty?
          segments << [SEG_PARTIAL_DEPS, Marshal.dump(ext_deps)]
        end
        out << segments.length.chr
        segments.each do |type, bytes|
          out << [type, bytes.bytesize].pack("CV") << bytes
        end
        out
      end

      # The external-only subset of a partial_dependencies hash (or nil).
      def external_deps(deps)
        return nil unless deps
        ext = deps.select { |_name, info| info[:disposition] == :external }
        ext.empty? ? nil : ext
      end

      # True if the blob is a framed artifact (vs a legacy Marshal payload).
      def artifact?(blob)
        blob.is_a?(String) && blob.byteslice(0, 4) == MAGIC
      end

      # Decode the envelope → [iseq_bytes, partial_constants].
      # Raises StaleArtifactError on version/Ruby-stamp mismatch and
      # CorruptArtifactError on structural damage.
      def decode_segments(blob)
        raise CorruptArtifactError, "not a LiquidIL artifact" unless artifact?(blob)

        pos = 4
        version = blob.getbyte(pos); pos += 1
        unless version == VERSION
          raise StaleArtifactError, "artifact format v#{version}, expected v#{VERSION} — recompile"
        end

        stamp_len = blob.getbyte(pos); pos += 1
        stamp = blob.byteslice(pos, stamp_len); pos += stamp_len
        unless stamp == RUBY_STAMP
          raise StaleArtifactError, "artifact built for Ruby #{stamp}, this is #{RUBY_STAMP} — recompile"
        end

        header = blob.byteslice(pos, 8)
        raise CorruptArtifactError, "truncated artifact" if header.nil? || header.bytesize < 8
        crc, iseq_len = header.unpack("VV")
        pos += 8

        seg_count = blob.getbyte(pos); pos += 1
        raise CorruptArtifactError, "truncated artifact" if seg_count.nil?

        iseq = nil
        partial_constants = nil
        partial_deps = nil
        seg_count.times do
          type = blob.getbyte(pos)
          len_bytes = blob.byteslice(pos + 1, 4)
          raise CorruptArtifactError, "truncated artifact" if type.nil? || len_bytes.nil? || len_bytes.bytesize < 4
          len = len_bytes.unpack1("V")
          pos += 5
          bytes = blob.byteslice(pos, len)
          raise CorruptArtifactError, "truncated artifact" if bytes.nil? || bytes.bytesize != len
          pos += len

          case type
          when SEG_ISEQ then iseq = bytes
          when SEG_PARTIAL_CONSTANTS then partial_constants = Marshal.load(bytes)
          when SEG_PARTIAL_DEPS then partial_deps = Marshal.load(bytes)
            # Unknown segment types are skipped (forward compatibility)
          end
        end

        raise CorruptArtifactError, "artifact has no ISeq segment" unless iseq
        unless iseq.bytesize == iseq_len && Zlib.crc32(iseq) == crc
          raise CorruptArtifactError, "artifact digest mismatch — refusing to load ISeq"
        end

        [iseq, partial_constants, crc, partial_deps]
      end

      # Load an artifact (or legacy Marshal payload) into a renderable Template.
      def load(blob)
        if artifact?(blob)
          iseq, partial_constants, = decode_segments(blob)
          Template.from_iseq_binary(iseq, partial_constants: partial_constants)
        else
          # Legacy Marshal-hash payload from the pre-v1 cache_data format
          Template.from_cache(**Marshal.load(blob))
        end
      end

      # Load an artifact into a CompiledArtifact — the leanest render path
      # (no Template wrapper, Scope built directly at render).
      def load_compiled(blob)
        # The digest is the WHOLE-blob CRC (identity for TemplateCache
        # staleness checks); the ISeq segment integrity check happens inside
        # decode_segments.
        if artifact?(blob)
          iseq, partial_constants, _crc, partial_deps = decode_segments(blob)
          compiled_proc = RubyVM::InstructionSequence.load_from_binary(iseq).eval
          CompiledArtifact.new(compiled_proc, partial_constants, blob.bytesize, Zlib.crc32(blob), partial_deps)
        else
          data = Marshal.load(blob)
          compiled_proc = RubyVM::InstructionSequence.load_from_binary(data[:iseq_binary]).eval
          CompiledArtifact.new(compiled_proc, data[:partial_constants], blob.bytesize, Zlib.crc32(blob))
        end
      end
    end
  end
end
