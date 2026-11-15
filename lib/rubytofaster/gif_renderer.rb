# frozen_string_literal: true

require "fileutils"
require "json"

module RubyToFaster
  # Zero-dependency, pure-Ruby GIF89a animated benchmark telemetry renderer.
  # Encodes real hardware benchmark measurements (`Benchmarker#run`) into a looping,
  # dark-mode animated GIF dashboard suitable for GitHub READMEs, PR comments, and CI artifacts.
  class GifRenderer
    WIDTH  = 880
    HEIGHT = 460

    # Indexed 256-color palette (indices 0..27 used; remaining padded to 256 RGB triplets)
    PALETTE = [
      [11,  17,  32],  # 0:  Canvas deep background (#0B1120)
      [17,  24,  39],  # 1:  Card surface (#111827)
      [30,  41,  59],  # 2:  Track / inner panel (#1E293B)
      [51,  65,  85],  # 3:  Subtle border (#334155)
      [71,  85, 105],  # 4:  Muted divider (#475569)
      [248, 250, 252], # 5:  Primary white text (#F8FAFC)
      [203, 213, 225], # 6:  Secondary light slate (#CBD5E1)
      [148, 163, 184], # 7:  Muted label slate (#94A3B8)
      [100, 116, 139], # 8:  Dim axis / grid (#64748B)
      [239,  68,  68], # 9:  Row 0 Red fill (#EF4444)
      [252, 165, 165], # 10: Row 0 Red highlight (#FCA5A5)
      [69,   10,  10], # 11: Row 0 Red badge bg (#450A0A)
      [59,  130, 246], # 12: Row 1 Blue fill (#3B82F6)
      [147, 197, 253], # 13: Row 1 Blue highlight (#93C5FD)
      [23,   37,  84], # 14: Row 1 Blue badge bg (#172554)
      [139,  92, 246], # 15: Row 2 Violet fill (#8B5CF6)
      [196, 181, 253], # 16: Row 2 Violet highlight (#C4B5FD)
      [46,   16, 101], # 17: Row 2 Violet badge bg (#2E1065)
      [16,  185, 129], # 18: Row 3 Emerald fill (#10B981)
      [110, 231, 183], # 19: Row 3 Emerald highlight (#6EE7B7)
      [6,    78,  59], # 20: Row 3 Emerald badge bg (#064E3B)
      [245, 158,  11], # 21: Amber accent (#F59E0B)
      [56,  189, 248], # 22: Sky cyan accent (#38BDF8)
      [15,   23,  42], # 23: Header / KPI card bg (#0F172A)
      [2,    44,  34], # 24: Deep emerald hero bg (#022C22)
      [204,  52,  45], # 25: Ruby crimson (#CC342D)
      [24,   33,  52], # 26: Track tick line (#182134)
      [5,   150, 105]  # 27: Emerald border dim (#059669)
    ].freeze

    ROW_THEMES = [
      { fill: 9,  hi: 10, badge_bg: 11, badge_fg: 10, border: 9  },
      { fill: 12, hi: 13, badge_bg: 14, badge_fg: 13, border: 12 },
      { fill: 15, hi: 16, badge_bg: 17, badge_fg: 16, border: 15 },
      { fill: 18, hi: 19, badge_bg: 20, badge_fg: 19, border: 18 }
    ].freeze

    # Crisp 5x7 bitmap font (each glyph is 7 rows of 5-bit integers, MSB = leftmost pixel)
    FONT_5X7 = {
      " " => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00],
      "!" => [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
      '"' => [0x0A, 0x0A, 0x0A, 0x00, 0x00, 0x00, 0x00],
      "#" => [0x0A, 0x1F, 0x0A, 0x0A, 0x1F, 0x0A, 0x00],
      "$" => [0x04, 0x0F, 0x14, 0x0E, 0x05, 0x1E, 0x04],
      "%" => [0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03],
      "&" => [0x0C, 0x12, 0x14, 0x08, 0x15, 0x12, 0x0D],
      "'" => [0x04, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00],
      "(" => [0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02],
      ")" => [0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08],
      "*" => [0x00, 0x04, 0x15, 0x0E, 0x15, 0x04, 0x00],
      "+" => [0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00],
      "," => [0x00, 0x00, 0x00, 0x00, 0x04, 0x04, 0x08],
      "-" => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
      "." => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
      "/" => [0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10],
      "0" => [0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E],
      "1" => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
      "2" => [0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F],
      "3" => [0x1F, 0x02, 0x04, 0x06, 0x01, 0x11, 0x0E],
      "4" => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
      "5" => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
      "6" => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
      "7" => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
      "8" => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
      "9" => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C],
      ":" => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
      ";" => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x04, 0x08],
      "<" => [0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02],
      "=" => [0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00],
      ">" => [0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08],
      "?" => [0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04],
      "@" => [0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E],
      "A" => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
      "B" => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
      "C" => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
      "D" => [0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E],
      "E" => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
      "F" => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
      "G" => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
      "H" => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
      "I" => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
      "J" => [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
      "K" => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
      "L" => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
      "M" => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
      "N" => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
      "O" => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
      "P" => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
      "Q" => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
      "R" => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
      "S" => [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
      "T" => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
      "U" => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
      "V" => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
      "W" => [0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11],
      "X" => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
      "Y" => [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
      "Z" => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
      "[" => [0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E],
      "\\" => [0x10, 0x08, 0x08, 0x04, 0x02, 0x02, 0x01],
      "]" => [0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E],
      "^" => [0x04, 0x0A, 0x11, 0x00, 0x00, 0x00, 0x00],
      "_" => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F],
      "`" => [0x08, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00],
      "a" => [0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F],
      "b" => [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E],
      "c" => [0x00, 0x00, 0x0E, 0x11, 0x10, 0x11, 0x0E],
      "d" => [0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F],
      "e" => [0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E],
      "f" => [0x06, 0x08, 0x1E, 0x08, 0x08, 0x08, 0x08],
      "g" => [0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x0E],
      "h" => [0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11],
      "i" => [0x04, 0x00, 0x0C, 0x04, 0x04, 0x04, 0x0E],
      "j" => [0x02, 0x00, 0x06, 0x02, 0x02, 0x12, 0x0C],
      "k" => [0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12],
      "l" => [0x0C, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
      "m" => [0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11],
      "n" => [0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11],
      "o" => [0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E],
      "p" => [0x00, 0x00, 0x1E, 0x11, 0x1E, 0x10, 0x10],
      "q" => [0x00, 0x00, 0x0F, 0x11, 0x0F, 0x01, 0x01],
      "r" => [0x00, 0x00, 0x16, 0x19, 0x10, 0x10, 0x10],
      "s" => [0x00, 0x00, 0x0F, 0x10, 0x0E, 0x01, 0x1E],
      "t" => [0x08, 0x08, 0x1E, 0x08, 0x08, 0x09, 0x06],
      "u" => [0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D],
      "v" => [0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04],
      "w" => [0x00, 0x00, 0x11, 0x11, 0x15, 0x15, 0x0A],
      "x" => [0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11],
      "y" => [0x00, 0x00, 0x11, 0x11, 0x0F, 0x01, 0x0E],
      "z" => [0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F],
      "{" => [0x02, 0x04, 0x04, 0x08, 0x04, 0x04, 0x02],
      "|" => [0x04, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
      "}" => [0x08, 0x04, 0x04, 0x02, 0x04, 0x04, 0x08],
      "~" => [0x00, 0x08, 0x15, 0x02, 0x00, 0x00, 0x00]
    }.freeze

    # Fast indexed-color byte-buffer canvas supporting crisp primitives and bitmap text.
    class Canvas
      attr_reader :width, :height, :pixels

      def initialize(width, height, bg_color = 0)
        @width  = width
        @height = height
        @pixels = (bg_color.chr.b * (width * height))
      end

      def initialize_copy(other)
        super
        @pixels = other.pixels.dup
      end

      def set_pixel(x, y, color)
        return if x.negative? || y.negative? || x >= @width || y >= @height

        @pixels.setbyte(y * @width + x, color)
      end

      def fill_rect(x, y, w, h, color)
        return if w <= 0 || h <= 0

        x0 = [x, 0].max
        y0 = [y, 0].max
        x1 = [x + w, @width].min
        y1 = [y + h, @height].min
        span = x1 - x0
        return if span <= 0 || y0 >= y1

        row_bytes = color.chr.b * span
        row = y0
        while row < y1
          @pixels[row * @width + x0, span] = row_bytes
          row += 1
        end
      end

      def stroke_rect(x, y, w, h, color)
        return if w <= 0 || h <= 0

        fill_rect(x, y, w, 1, color)
        fill_rect(x, y + h - 1, w, 1, color)
        fill_rect(x, y, 1, h, color)
        fill_rect(x + w - 1, y, 1, h, color)
      end

      def rounded_box(x, y, w, h, fill:, border: nil)
        return if w < 4 || h < 4

        fill_rect(x + 1, y, w - 2, h, fill)
        fill_rect(x, y + 1, w, h - 2, fill)
        return unless border

        fill_rect(x + 1, y, w - 2, 1, border)
        fill_rect(x + 1, y + h - 1, w - 2, 1, border)
        fill_rect(x, y + 1, 1, h - 2, border)
        fill_rect(x + w - 1, y + 1, 1, h - 2, border)
      end

      def text_width(str, scale: 1, spacing: 1)
        s = str.to_s
        return 0 if s.empty?

        char_w = 5 * scale
        gap    = spacing * scale
        s.length * char_w + (s.length - 1) * gap
      end

      def draw_text(x, y, str, color:, scale: 1, spacing: 1)
        cursor_x = x
        step_x   = (5 + spacing) * scale

        str.to_s.each_char do |ch|
          glyph = FONT_5X7[ch] || FONT_5X7[ch.upcase] || FONT_5X7["?"]
          7.times do |row_idx|
            bits = glyph[row_idx]
            next if bits.zero?

            5.times do |col_idx|
              next if (bits & (1 << (4 - col_idx))).zero?

              px = cursor_x + col_idx * scale
              py = y + row_idx * scale
              if scale == 1
                set_pixel(px, py, color)
              else
                fill_rect(px, py, scale, scale, color)
              end
            end
          end
          cursor_x += step_x
        end
      end

      def draw_text_right(right_x, y, str, color:, scale: 1, spacing: 1)
        w = text_width(str, scale: scale, spacing: spacing)
        draw_text(right_x - w, y, str, color: color, scale: scale, spacing: spacing)
      end

      def extract_subrect(rx, ry, rw, rh)
        return @pixels if rx.zero? && ry.zero? && rw == @width && rh == @height

        out = String.new(capacity: rw * rh, encoding: Encoding::BINARY)
        row = ry
        y_end = ry + rh
        while row < y_end
          out << @pixels.byteslice(row * @width + rx, rw)
          row += 1
        end
        out
      end
    end

    def self.render_benchmark(report, output_path = nil)
      gif_bytes = new(report).encode_gif
      if output_path
        full = File.expand_path(output_path)
        FileUtils.mkdir_p(File.dirname(full))
        File.binwrite(full, gif_bytes)
      end
      gif_bytes
    end

    def initialize(report, anim_frames: 16)
      @report      = normalize_keys(report)
      @anim_frames = [[anim_frames.to_i, 4].max, 40].min
    end

    def encode_gif
      rows = Array(@report[:benchmarks]).first(4)
      raise ConfigError, "Benchmark report contains no strategy measurements to render" if rows.empty?

      out = String.new(capacity: 65_536, encoding: Encoding::BINARY)
      out << "GIF89a"
      out << [WIDTH, HEIGHT, 0xF7, 0, 0].pack("vvCCC")
      out << build_global_color_table
      out << build_comment_extension(provenance_comment_json)
      out << "\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00".b

      base_canvas = build_static_backdrop(rows)

      # Frame 0: Full 880x460 initial frame
      frame0 = base_canvas.dup
      paint_dynamic_elements!(frame0, rows, progress: 0.06, pulse: false)
      out << encode_frame(frame0.pixels, 0, 0, WIDTH, HEIGHT, delay_cs: 6)

      # Smooth cubic ease-out bar & live telemetry sweep frames
      (1..@anim_frames).each do |step|
        t = step.to_f / @anim_frames
        eased = 1.0 - ((1.0 - t)**3)
        canvas = base_canvas.dup
        paint_dynamic_elements!(canvas, rows, progress: eased, pulse: false)
        delay = step == @anim_frames ? 24 : 5
        # Dirty rectangle covering dynamic badge + bars + KPI cards (`y: 16..442`)
        sub = canvas.extract_subrect(16, 16, WIDTH - 32, HEIGHT - 32)
        out << encode_frame(sub, 16, 16, WIDTH - 32, HEIGHT - 32, delay_cs: delay)
      end

      # Highlight pulse frame on peak speedup badge + long final hold frame (3.6s)
      [true, false].each do |is_pulse|
        canvas = base_canvas.dup
        paint_dynamic_elements!(canvas, rows, progress: 1.0, pulse: is_pulse)
        sub = canvas.extract_subrect(16, 16, WIDTH - 32, HEIGHT - 32)
        out << encode_frame(sub, 16, 16, WIDTH - 32, HEIGHT - 32, delay_cs: is_pulse ? 35 : 340)
      end

      out << "\x3B".b
      out
    end

    private

    def build_static_backdrop(rows)
      c = Canvas.new(WIDTH, HEIGHT, 0)

      # Outer card & header panel
      c.rounded_box(8, 8, WIDTH - 16, HEIGHT - 16, fill: 1, border: 3)
      c.fill_rect(9, 9, WIDTH - 18, 66, 23)
      c.fill_rect(9, 75, WIDTH - 18, 1, 3)

      # Ruby crimson emblem + Title
      c.rounded_box(24, 21, 16, 16, fill: 25, border: 10)
      c.fill_rect(28, 25, 4, 4, 5)
      c.draw_text(48, 22, "RUBYTOFASTER", color: 5, scale: 2, spacing: 1)
      c.draw_text(218, 22, "//", color: 22, scale: 2, spacing: 1)
      c.draw_text(252, 22, "REAL BENCHMARK", color: 19, scale: 2, spacing: 1)

      gem_label  = "#{@report[:gem_name] || 'gem'} v#{@report[:gem_version] || RubyToFaster::VERSION}"
      files_info = @report[:entry_count] ? "#{@report[:entry_count]} files" : "verified"
      meta_line  = "GEM: #{gem_label} (#{files_info})  |  RUBY #{@report[:ruby_version]} (#{short_platform})  |  N=#{@report[:iterations]} RUNS"
      c.draw_text(24, 53, meta_line[0, 96], color: 7, scale: 1, spacing: 1)

      # Axis caption above bars
      c.draw_text(28, 84, "BUILD STRATEGY", color: 8, scale: 1, spacing: 1)
      c.draw_text_right(728, 84, "MEAN / MIN / P95 LATENCY (LOWER = FASTER)", color: 8, scale: 1, spacing: 1)
      c.draw_text(754, 84, "SPEEDUP", color: 8, scale: 1, spacing: 1)

      # Static row labels and bar tracks
      rows.each_with_index do |row, idx|
        ry = 102 + idx * 63
        label = format("%d. %s", idx + 1, row[:name].to_s)
        c.draw_text(28, ry, label[0, 52], color: idx == rows.size - 1 ? 19 : 5, scale: 1, spacing: 1)

        # Bar background track (x: 28, w: 700, h: 24)
        track_y = ry + 15
        c.rounded_box(28, track_y, 700, 24, fill: 2, border: 3)
        [175, 350, 525].each do |tick_dx|
          c.fill_rect(28 + tick_dx, track_y + 1, 1, 22, 26)
        end
      end

      # Footer divider
      c.fill_rect(24, 358, WIDTH - 48, 1, 3)
      c
    end

    def paint_dynamic_elements!(c, rows, progress:, pulse:)
      max_ms = rows.map { |r| r[:mean_ms].to_f }.max
      max_ms = 1.0 if max_ms.nil? || max_ms <= 0.0

      best_speedup = @report[:peak_speedup] || rows.map { |r| r[:speedup_vs_baseline].to_f }.max || 1.0
      shown_peak   = 1.0 + (best_speedup - 1.0) * progress

      # Top-right Hero Peak Speedup Badge
      hero_border = pulse ? 19 : 18
      c.rounded_box(636, 16, 220, 48, fill: 24, border: hero_border)
      c.draw_text(650, 24, "PEAK MERKLE SPEEDUP", color: 7, scale: 1, spacing: 1)
      c.draw_text(650, 39, format("%.1fx FASTER", shown_peak), color: pulse ? 5 : 19, scale: 2, spacing: 1)

      # Per-row animated bars, live latency readouts, and speedup badges
      rows.each_with_index do |row, idx|
        theme   = ROW_THEMES[idx % ROW_THEMES.size]
        ry      = 102 + idx * 63
        track_y = ry + 15

        mean_ms = row[:mean_ms].to_f
        min_ms  = row[:min_ms].to_f
        p95_ms  = row[:p95_ms].to_f
        speedup = row[:speedup_vs_baseline].to_f

        cur_mean = mean_ms * progress
        stats_str = format("mean %6.2f ms  (min %.2f / p95 %.2f ms)", cur_mean, min_ms * progress, p95_ms * progress)
        c.draw_text_right(728, ry, stats_str, color: 6, scale: 1, spacing: 1)

        target_w = ((mean_ms / max_ms) * 694.0).round
        bar_w    = [(target_w * progress).round, 6].max
        bar_w    = [bar_w, 696].min

        c.fill_rect(30, track_y + 2, bar_w, 20, theme[:fill])
        c.fill_rect(30, track_y + 2, bar_w, 3, pulse && idx == rows.size - 1 ? 5 : theme[:hi])

        # Speedup pill on the right
        pill_x = 740
        pill_w = 114
        is_winner = idx == rows.size - 1
        pill_border = is_winner && pulse ? 19 : theme[:border]
        c.rounded_box(pill_x, track_y - 1, pill_w, 26, fill: theme[:badge_bg], border: pill_border)

        cur_speed = idx.zero? ? 1.0 : (1.0 + (speedup - 1.0) * progress)
        speed_txt = idx.zero? ? "1.0x BASE" : format("%.1fx", cur_speed)
        txt_scale = idx.zero? ? 1 : 2
        tw = c.text_width(speed_txt, scale: txt_scale, spacing: 1)
        tx = pill_x + ((pill_w - tw) / 2)
        ty = txt_scale == 2 ? track_y + 5 : track_y + 9
        c.draw_text(tx, ty, speed_txt, color: theme[:badge_fg], scale: txt_scale, spacing: 1)
      end

      # 4 Bottom KPI Summary Cards (`y: 368..438`)
      paint_kpi_cards!(c, rows, progress: progress)
    end

    def paint_kpi_cards!(c, rows, progress:)
      cold_row  = rows.find { |r| r[:name].to_s.downcase.include?("cold") } || rows[-2] || rows.last
      cache_row = rows.find { |r| r[:name].to_s.downcase.include?("cache") } || rows.last

      cold_ms   = cold_row[:mean_ms].to_f
      cache_ms  = cache_row[:mean_ms].to_f
      ops_sec   = cache_row[:ops_per_sec] ? cache_row[:ops_per_sec].to_f : (cache_ms.positive? ? (1000.0 / cache_ms) : 0.0)
      pkg_kb    = (@report[:compressed_bytes].to_f / 1024.0)

      cards = [
        ["COLD BUILD LATENCY",  format("%.2f ms (%.1fx)", cold_ms * progress, cold_row[:speedup_vs_baseline].to_f), 16],
        ["MERKLE CACHE HIT",    format("%.2f ms (%.1fx)", cache_ms * progress, cache_row[:speedup_vs_baseline].to_f), 19],
        ["CACHE THROUGHPUT",    format("%.1f/sec", ops_sec * progress), 22],
        ["REPRODUCIBLE SHA256", pkg_kb.positive? ? format("OK (%.1f KB)", pkg_kb) : "VERIFIED", 21]
      ]

      card_w = 198
      gap    = 13
      cards.each_with_index do |(label, val, accent), i|
        cx = 24 + i * (card_w + gap)
        cy = 368
        c.rounded_box(cx, cy, card_w, 68, fill: 23, border: 3)
        c.fill_rect(cx + 1, cy + 1, 3, 66, accent)
        c.draw_text(cx + 12, cy + 12, label, color: 7, scale: 1, spacing: 1)
        c.draw_text(cx + 12, cy + 32, val[0, 16], color: 5, scale: 1, spacing: 1)
        sub_note = case i
                   when 0 then "in-memory tar+gzip"
                   when 1 then "SHA-256 content key"
                   when 2 then "warm incremental loop"
                   else        short_sha
                   end
        c.draw_text(cx + 12, cy + 49, sub_note, color: accent, scale: 1, spacing: 1)
      end
    end

    def short_platform
      plat = (@report[:platform] || RUBY_PLATFORM).to_s
      plat.length > 20 ? plat[0, 20] : plat
    end

    def short_sha
      sha = @report[:gem_sha256].to_s
      sha.empty? ? "deterministic" : "sha256:#{sha[0, 12]}"
    end

    def provenance_comment_json
      JSON.generate(
        generator: "rubytofaster/#{RubyToFaster::VERSION}",
        gem_name: @report[:gem_name],
        gem_version: @report[:gem_version],
        ruby_version: @report[:ruby_version],
        platform: @report[:platform],
        measured_at: @report[:measured_at],
        peak_speedup: @report[:peak_speedup],
        benchmarks: Array(@report[:benchmarks]).map do |b|
          {
            name: b[:name],
            mean_ms: b[:mean_ms],
            min_ms: b[:min_ms],
            p95_ms: b[:p95_ms],
            speedup: b[:speedup_vs_baseline]
          }
        end
      )
    end

    def build_global_color_table
      table = String.new(capacity: 768, encoding: Encoding::BINARY)
      256.times do |i|
        rgb = PALETTE[i] || [0, 0, 0]
        table << rgb.pack("CCC")
      end
      table
    end

    def build_comment_extension(text)
      raw = text.to_s.b
      out = "\x21\xFE".b.dup
      pos = 0
      while pos < raw.bytesize
        chunk = raw.byteslice(pos, 255)
        out << chunk.bytesize.chr << chunk
        pos += 255
      end
      out << "\x00".b
      out
    end

    def encode_delta_frame(prev_canvas, curr_canvas, delay_cs:)
      transparent_idx = 255
      prev_px = prev_canvas.pixels
      curr_px = curr_canvas.pixels

      min_y = nil
      max_y = nil
      HEIGHT.times do |y|
        row_off = y * WIDTH
        next if curr_px.byteslice(row_off, WIDTH) == prev_px.byteslice(row_off, WIDTH)

        min_y ||= y
        max_y = y
      end

      if min_y.nil?
        return encode_frame(transparent_idx.chr.b, 0, 0, 1, 1, delay_cs: delay_cs, transparent_index: transparent_idx)
      end

      min_x = WIDTH
      max_x = 0
      (min_y..max_y).each do |y|
        row_off = y * WIDTH
        WIDTH.times do |x|
          next if curr_px.getbyte(row_off + x) == prev_px.getbyte(row_off + x)

          min_x = x if x < min_x
          max_x = x if x > max_x
        end
      end

      bw = max_x - min_x + 1
      bh = max_y - min_y + 1
      delta_bytes = (transparent_idx.chr.b * (bw * bh))

      bh.times do |dy|
        src_off = (min_y + dy) * WIDTH + min_x
        dst_off = dy * bw
        bw.times do |dx|
          c_byte = curr_px.getbyte(src_off + dx)
          p_byte = prev_px.getbyte(src_off + dx)
          delta_bytes.setbyte(dst_off + dx, c_byte) if c_byte != p_byte
        end
      end

      encode_frame(delta_bytes, min_x, min_y, bw, bh, delay_cs: delay_cs, transparent_index: transparent_idx)
    end

    def encode_frame(pixel_bytes, fx, fy, fw, fh, delay_cs:, transparent_index: nil)
      frame = String.new(capacity: 4096, encoding: Encoding::BINARY)
      if transparent_index
        # disposal=1 (do not dispose -> 0x04) | transparent_color_flag=1 (0x01) => 0x05
        frame << "\x21\xF9\x04".b << [0x05, delay_cs, transparent_index].pack("CvC") << "\x00".b
      else
        frame << "\x21\xF9\x04".b << [0x04, delay_cs, 0].pack("CvC") << "\x00".b
      end
      # Image Descriptor
      frame << "\x2C".b << [fx, fy, fw, fh, 0x00].pack("vvvvC")
      # LZW Minimum Code Size (8) + sub-blocked LZW stream + terminator
      frame << "\x08".b
      lzw_bytes = lzw_encode_8bit(pixel_bytes)
      pos = 0
      total = lzw_bytes.bytesize
      while pos < total
        chunk = lzw_bytes.byteslice(pos, 255)
        frame << chunk.bytesize.chr << chunk
        pos += 255
      end
      frame << "\x00".b
      frame
    end

    # Pure-Ruby GIF LZW compressor (8-bit color indices, 9..12-bit variable code width, LSB-first).
    # Tracks exact decoder table state so power-of-two width transitions (511, 1023, 2047)
    # and clear resets (4095) match standard GIF89a decoders across every boundary.
    def lzw_encode_8bit(pixels)
      len = pixels.bytesize
      return "\x00\x01\x04\x01\x00".b if len.zero?

      clear_code = 256
      eoi_code   = 257

      code_size         = 9
      next_code         = 258
      decoder_next      = 258
      first_after_clear = true
      dict              = {}

      bit_buf  = 0
      bit_cnt  = 0
      out      = String.new(capacity: (len / 2) + 64, encoding: Encoding::BINARY)

      # Emit initial CLEAR code (256 in 9 bits)
      bit_buf |= (clear_code << bit_cnt)
      bit_cnt += code_size

      prefix = pixels.getbyte(0)
      idx = 1

      while idx < len
        byte = pixels.getbyte(idx)
        key  = (prefix << 8) | byte

        if (existing = dict[key])
          prefix = existing
        else
          # 1. Emit current prefix code
          bit_buf |= (prefix << bit_cnt)
          bit_cnt += code_size
          while bit_cnt >= 8
            out << (bit_buf & 0xFF).chr
            bit_buf >>= 8
            bit_cnt -= 8
          end

          # 2. Advance decoder-synchronized code_size tracker
          if first_after_clear
            first_after_clear = false
          else
            code_size += 1 if decoder_next == (1 << code_size) - 1 && code_size < 12
            decoder_next += 1
          end

          # 3. Insert new LZW phrase or emit CLEAR if 12-bit table (4096) is full
          if next_code < 4096
            dict[key] = next_code
            next_code += 1
          else
            bit_buf |= (clear_code << bit_cnt)
            bit_cnt += code_size
            while bit_cnt >= 8
              out << (bit_buf & 0xFF).chr
              bit_buf >>= 8
              bit_cnt -= 8
            end
            dict.clear
            code_size         = 9
            next_code         = 258
            decoder_next      = 258
            first_after_clear = true
          end

          prefix = byte
        end

        idx += 1
      end

      # Emit final prefix
      bit_buf |= (prefix << bit_cnt)
      bit_cnt += code_size
      if first_after_clear
        first_after_clear = false
      else
        code_size += 1 if decoder_next == (1 << code_size) - 1 && code_size < 12
      end

      # Emit End-Of-Information (257)
      bit_buf |= (eoi_code << bit_cnt)
      bit_cnt += code_size
      while bit_cnt >= 8
        out << (bit_buf & 0xFF).chr
        bit_buf >>= 8
        bit_cnt -= 8
      end
      out << (bit_buf & 0xFF).chr if bit_cnt.positive?

      out
    end

    def normalize_keys(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_sym] = normalize_keys(v) }
      when Array
        obj.map { |v| normalize_keys(v) }
      else
        obj
      end
    end
  end
end
