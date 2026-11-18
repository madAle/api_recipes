# frozen_string_literal: true

require 'open3'
require 'pathname'

module ApiRecipes
  module CLI
    class Upgrade
      # The changes `upgrade` makes by itself. Each is shown as a diff and is
      # made only when the person answers yes, on a terminal. A change
      # touches only files that git has committed as they are now, so that
      # it can be seen and undone, and writes all its files or none.
      class Fix
        # key: what the change is, said once. texts: { file => its new text }.
        # note: what yes and no mean, when the title does not say it: a line
        # of text, then one entry for each answer.
        Change = Data.define(:key, :title, :texts, :note) do
          def initialize(key:, title:, texts:, note: nil) = super
        end

        # Whether someone is there to answer.
        def self.asks?(input) = input.respond_to?(:tty?) && input.tty? ? true : false

        # shown: how the name of a file is shown. ours: { file => text } for
        # the files that this run of the command already changed.
        def initialize(screen, input, shown:, root: '.', ours: {})
          @screen = screen
          @input = input
          @shown = shown
          @root = root
          @ours = ours
        end

        # Shows a change that another part of the command works out and
        # makes: the files it creates, edits and deletes. Returns whether
        # the answer was yes.
        def confirm(title, note, preview)
          @screen.section('🔧', title)
          if note
            @screen.line(note.first)
            note.drop(1).each { |answer| @screen.item(answer) }
          end
          preview[:created].each { |file, text| @screen.created(@shown.call(file), text) }
          preview[:edited].each { |file, (before, after)| @screen.diff(@shown.call(file), before, after) }
          preview[:deleted].each { |file| @screen.deleted(@shown.call(file)) }
          @screen.ask('Make this change?', @input)
        end

        # Shows the change and asks. Returns the files it wrote, or nil when
        # the change was not made.
        def offer(change)
          @screen.section('🔧', change.title)
          reason = blocked(change)
          if reason
            @screen.line("This command does not make the change: #{reason}. The code to paste is below.")
            return nil
          end
          if change.note
            @screen.line(change.note.first)
            change.note.drop(1).each { |answer| @screen.item(answer) }
            @screen.gap
          end
          before = change.texts.keys.to_h { |file| [file, File.read(full(file))] }
          change.texts.each { |file, text| @screen.diff(@shown.call(file), before[file], text) }
          return nil unless @screen.ask('Make this change?', @input)

          write(change, before) ? change.texts.keys : nil
        end

        private

        def full(file) = File.join(@root, file)

        def git(*arguments)
          Open3.capture2e({ 'GIT_OPTIONAL_LOCKS' => '0' }, *Convert::Migration::GIT, '-C', @root, *arguments)
        rescue SystemCallError
          ['', nil]
        end

        # Why the change cannot be made, or nil.
        def blocked(change)
          _, status = git('--version')
          return 'git was not found, and without it a change could not be seen or undone' unless status&.success?

          file = change.texts.keys.find { |one| !(committed?(one) || ours?(one)) || !File.writable?(full(one)) }
          file && "#{@shown.call(file)} is not a file that git has committed as it is now, so what changes could not be brought back"
        end

        # A plain file of the project: not a symbolic link, not below one,
        # not outside the project.
        def plain?(file)
          path = full(file)
          return false if File.symlink?(path) || !File.file?(path)

          File.realpath(path) == File.join(File.realpath(@root), Pathname.new(file).cleanpath.to_s)
        rescue SystemCallError
          false
        end

        # Whether git tracks the file as it does any other, and has it
        # committed as it is now.
        def committed?(file)
          listed, status = git('ls-files', '-v', '--error-unmatch', '--', file)
          return false unless plain?(file) && status&.success? && listed.start_with?('H ')

          changes, clean = git('status', '--porcelain', '--', file)
          clean&.success? && changes.empty? ? true : false
        end

        # Whether the file is as this command left it, after a change made
        # to it when git had it committed.
        def ours?(file) = plain?(file) && @ours.key?(file) && File.read(full(file)) == @ours[file]

        # Writes every file of the change. When one cannot be written, the
        # ones already written are put back.
        def write(change, before)
          written = []
          change.texts.each do |file, text|
            File.write(full(file), text)
            written << file
          end
          @ours.merge!(change.texts)
          true
        rescue SystemCallError => e
          lost = written.reject do |file|
            File.write(full(file), before[file])
            true
          rescue SystemCallError
            false
          end
          @screen.line("The change could not be written (#{e.class.name.split('::').last}): " \
                       "#{lost.empty? ? 'every file was put back as it was' : "these files could not be put back: #{lost.map { |file| @shown.call(file) }.join(', ')}"}")
          false
        end
      end

      # The lines that differ between two texts, with the lines around them.
      module Diff
        # Above this many pairs of lines the middle of the texts is not compared line by line.
        LIMIT = 400_000

        # [[first line of the old text, [[sign, line], ...]], ...] where sign
        # is '-' for a line taken out, '+' for one added and ' ' for one kept.
        def self.hunks(old, new, context: 2)
          steps = steps(old.lines(chomp: true), new.lines(chomp: true))
          changed = steps.each_index.reject { |index| steps[index].first == ' ' }
          ranges = changed.map { |index| [[index - context, 0].max, [index + context, steps.size - 1].min] }
          ranges = ranges.each_with_object([]) do |(from, to), merged|
            merged.last && from <= merged.last[1] + 1 ? merged.last[1] = [merged.last[1], to].max : merged << [from, to]
          end
          ranges.map { |from, to| [steps[from][2], steps[from..to].map { |sign, line, _| [sign, line] }] }
        end

        # [[sign, line, number of the line in the old text], ...]
        def self.steps(old, new)
          head = 0
          head += 1 while head < old.size && head < new.size && old[head] == new[head]
          tail = 0
          tail += 1 while tail < old.size - head && tail < new.size - head && old[-1 - tail] == new[-1 - tail]
          from = old[head...old.size - tail]
          to = new[head...new.size - tail]
          middle = from.size * to.size > LIMIT ? from.map { |line| ['-', line] } + to.map { |line| ['+', line] } : compared(from, to)
          number = 0
          (old.first(head).map { |line| [' ', line] } + middle + old.last(tail).map { |line| [' ', line] }).map do |sign, line|
            number += 1 unless sign == '+'
            [sign, line, sign == '+' ? number + 1 : number]
          end
        end

        # The longest run of lines the two lists share, and what is around it.
        def self.compared(from, to)
          lengths = Array.new(from.size + 1) { Array.new(to.size + 1, 0) }
          (from.size - 1).downto(0) do |i|
            (to.size - 1).downto(0) do |j|
              lengths[i][j] = from[i] == to[j] ? lengths[i + 1][j + 1] + 1 : [lengths[i + 1][j], lengths[i][j + 1]].max
            end
          end
          steps = []
          i = j = 0
          while i < from.size || j < to.size
            if i < from.size && j < to.size && from[i] == to[j]
              steps << [' ', from[i]]
              i += 1
              j += 1
            elsif i < from.size && (j == to.size || lengths[i + 1][j] >= lengths[i][j + 1])
              steps << ['-', from[i]]
              i += 1
            else
              steps << ['+', to[j]]
              j += 1
            end
          end
          steps
        end
      end
    end
  end
end
