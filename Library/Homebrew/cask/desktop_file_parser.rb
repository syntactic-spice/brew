# typed: strict
# frozen_string_literal: true

require "shellwords"

module Cask
  # Reads and edits freedesktop.org desktop entry files, keeping their comments and layout.
  # The spec forbids duplicate groups and duplicate keys within a group, so only the first
  # occurrence of each is read or edited.
  # Ref: https://specifications.freedesktop.org/desktop-entry/latest/
  class DesktopFileParser
    DESKTOP_ENTRY_GROUP = "Desktop Entry"

    # Escape sequences in values of the spec's `string` type.
    VALUE_ESCAPES = T.let({ "s" => " ", "n" => "\n", "t" => "\t", "r" => "\r", "\\" => "\\" }.freeze,
                          T::Hash[String, String])
    private_constant :VALUE_ESCAPES

    # Characters an `Exec` argument must be quoted for.
    EXEC_RESERVED_CHARACTERS = /[\s"'\\<>~|&;$*?#()`]/
    private_constant :EXEC_RESERVED_CHARACTERS

    # Split an `Exec` value into its program and arguments.
    sig { params(exec: String).returns(T::Array[String]) }
    def self.split_exec(exec)
      Shellwords.split(exec)
    end

    # Join a program and its arguments into an `Exec` value.
    # Only arguments with reserved characters are quoted
    sig { params(words: T::Array[String]).returns(String) }
    def self.join_exec(words)
      words.map do |word|
        next word unless word.match?(EXEC_RESERVED_CHARACTERS)

        # Surround with quotes and precede with `\`:
        "\"#{word.gsub(/["`$\\]/) { |character| "\\#{character}" }}\""
      end.join(" ")
    end

    # Replace the program an `Exec` calls with `program`, keeping its arguments and the
    # environment variables it sets, and setting `environment` with `env`, e.g. for
    # `program: "<target>"` and `environment: { "DESKTOPINTEGRATION" => "1" }`:
    #   Input:  Exec=env GDK_BACKEND=x11 UBUNTU_MENUPROXY=0 audacity %F
    #   Output: Exec=env DESKTOPINTEGRATION=1 GDK_BACKEND=x11 UBUNTU_MENUPROXY=0 <target> %F
    # Raises `ArgumentError` if `exec` has unmatched quotes.
    sig { params(exec: String, program: String, environment: T::Hash[String, String]).returns(String) }
    def self.replace_exec_program(exec, program:, environment: {})
      words = split_exec(exec)
      words.shift if words.first == "env"
      variables = words.take_while { |word| word.match?(/\A[A-Za-z_]\w*=/) }
      # Skip the program itself, which is replaced.
      arguments = words.drop(variables.length + 1)
      # `environment` takes precedence over the same variables in `exec`.
      variables.reject! { |variable| environment.key?(variable.split("=", 2).fetch(0)) }
      variables.unshift(*environment.map { |name, value| "#{name}=#{value}" })
      join_exec([*("env" if variables.any?), *variables, program.gsub("%", "%%"), *arguments])
    end

    sig { params(contents: String).void }
    def initialize(contents)
      @lines = T.let(contents.scrub.lines(chomp: true), T::Array[String])
    end

    # Whether the first group is `[Desktop Entry]`, as the spec requires of desktop entries.
    sig { returns(T::Boolean) }
    def desktop_entry?
      @lines.find { |line| line.strip.present? && !line.start_with?("#") }&.strip == "[#{DESKTOP_ENTRY_GROUP}]"
    end

    # The names of the groups, in order.
    sig { returns(T::Array[String]) }
    def groups
      @lines.filter_map { |line| group_name(line) }.uniq
    end

    # The value of `key` in `group`, with escape sequences resolved.
    sig { params(key: String, group: String).returns(T.nilable(String)) }
    def get(key, group: DESKTOP_ENTRY_GROUP)
      index = key_index(key, group)
      return if index.nil?

      # Split at the first `=` only, as values may contain more.
      @lines.fetch(index).split("=", 2).fetch(1).strip.gsub(/\\(.)/) do
        character = Regexp.last_match(1).to_s
        # Keep unknown escapes such as `\;`, used within lists, for the caller.
        VALUE_ESCAPES.fetch(character, "\\#{character}")
      end
    end

    # Set `key` in `group` to `value`, replacing it in place or adding it at the end of `group`.
    sig { params(key: String, value: String, group: String).void }
    def set(key, value, group: DESKTOP_ENTRY_GROUP)
      # Reverse of the escape sequences `get` resolves.
      line = "#{key}=#{value.gsub(/[\\\n\t\r]/, "\\" => "\\\\", "\n" => "\\n", "\t" => "\\t", "\r" => "\\r")}"
      if (index = key_index(key, group))
        @lines[index] = line
        return
      end

      group_index = @lines.index { |existing_line| group_name(existing_line) == group }
      raise ArgumentError, "No [#{group}] group." if group_index.nil?

      # Insert before the next group, or at the end of the file,
      # but above any blank lines separating the groups.
      next_group_offset = @lines.drop(group_index + 1).index { |existing_line| group_name(existing_line) }
      insert_index = next_group_offset ? group_index + 1 + next_group_offset : @lines.length
      insert_index -= 1 while insert_index > group_index + 1 && @lines.fetch(insert_index - 1).strip.empty?
      @lines.insert(insert_index, line)
    end

    sig { params(key: String, group: String).void }
    def delete(key, group: DESKTOP_ENTRY_GROUP)
      index = key_index(key, group)
      @lines.delete_at(index) if index
    end

    sig { returns(String) }
    def to_s
      "#{@lines.join("\n")}\n"
    end

    private

    # The name of the group `line` starts, e.g. `Desktop Entry` for `[Desktop Entry]`.
    sig { params(line: String).returns(T.nilable(String)) }
    def group_name(line)
      line.strip[/\A\[([^\[\]]+)\]\z/, 1]
    end

    # The index of the line setting `key` in `group`.
    sig { params(key: String, group: String).returns(T.nilable(Integer)) }
    def key_index(key, group)
      # Track which group each line is in, as keys repeat across groups.
      current_group = T.let(nil, T.nilable(String))
      @lines.each_with_index do |line, index|
        if (name = group_name(line))
          current_group = name
          next
        end
        next if current_group != group || line.start_with?("#") || line.exclude?("=")

        # Keys are case-sensitive and include any locale, so `Name` doesn't match `Name[de]`.
        return index if line.split("=", 2).fetch(0).strip == key
      end
      nil
    end
  end
end
