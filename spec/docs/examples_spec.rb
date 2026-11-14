# frozen_string_literal: true

require 'spec_helper'
require 'erb'
require 'json'
require 'logger'
require 'yaml'

# Proves that the examples of the user documents are true.
#
# From every ```ruby block of README.md and UPGRADING.md it takes each line of
# code that is directly followed by a line `# => "..."`. The code of the block
# up to that line is evaluated and the `to_s` of the result must equal the
# string. Lines that are not followed by a comment of that form are context:
# they run, but nothing is compared. A line that cannot be evaluated fails the
# example.
#
# What it does not cover: a `# =>` comment whose value is not a plain double
# quoted String (`# => 200`, `# => [{ ... }]`) and the comments at the end of a
# line of code (`code # => 200`) are illustrations and are not checked. The
# text of an expected String is read as JSON, never evaluated. A `# =>` line
# that is not directly under a line of text, and a fence such as "```ruby title",
# fail the examples instead of being skipped. The number of checked pairs of
# each document is pinned: change PAIRS when you add or remove one on purpose.
#
# The APIs are configured with the ```yaml blocks of the same document whose
# first key is github, billing or shopify: for each name, the last block that
# comes before the ruby block wins. Every request is answered by WebMock with a
# 200 and the JSON body in RESPONSE_BODY.
module DocExamples
  DOCUMENTS = %w[README.md UPGRADING.md].freeze
  API_NAMES = %w[github billing shopify].freeze
  PAIRS = { 'README.md' => 27, 'UPGRADING.md' => 6 }.freeze
  RESPONSE_BODY = { login: 'octocat', name: 'The Octocat', id: 583_231 }.to_json.freeze
  PAIR = /\A\s*# => (".*")\s*\z/

  Block = Struct.new(:document, :title, :first_line, :lines, :yaml, keyword_init: true)

  module_function

  def blocks(document)
    path = File.expand_path("../../#{document}", __dir__)
    found = []
    yaml = {}
    title = document
    fence = nil
    current = nil
    File.foreach(path).with_index(1) do |text, number|
      text = text.chomp
      if fence
        if text.start_with?('```')
          found << current if fence == 'ruby'
          if fence == 'yaml'
            first_key = current.lines.first.to_s[/\A([A-Za-z_]+):/, 1]
            yaml = yaml.merge(first_key => current.lines.join("\n")) if API_NAMES.include?(first_key)
          end
          fence = nil
        else
          current.lines << text
        end
      elsif text.match?(/\A```(ruby|yaml)\S/) || text.match?(/\A```(ruby|yaml)\s+\S/)
        raise "#{document}:#{number}: the fence #{text.inspect} is not exactly ```ruby or ```yaml, so its code would be skipped"
      elsif (match = text.match(/\A```(ruby|yaml)\z/))
        fence = match[1]
        current = Block.new(document: document, title: title, first_line: number + 1, lines: [], yaml: yaml.dup)
      elsif (match = text.match(/\A#+ (.+)/))
        title = match[1]
      end
    end
    found
  end

  # [[index of the code line, expected string], ...]
  def pairs(block)
    block.lines.each_index.filter_map do |index|
      next unless (match = block.lines[index + 1]&.match(PAIR))

      [index, expected_string(block, index + 1, match[1])]
    end
  end

  def expected_string(block, index, text)
    value = JSON.parse(text)
    raise TypeError unless value.is_a?(String)

    value
  rescue JSON::ParserError, TypeError
    raise "#{block.document}:#{block.first_line + index}: #{text} is not a plain double quoted String"
  end

  # The lines "# =>" that are not directly under a line of text.
  def detached(block)
    block.lines.each_index.select do |index|
      block.lines[index].match?(/\A\s*# =>/) && (index.zero? || block.lines[index - 1].strip.empty?)
    end.map { |index| block.first_line + index }
  end

  def apis_of(block)
    block.yaml.values.each_with_object({}) do |text, apis|
      apis.merge!(YAML.safe_load(ERB.new(text).result, aliases: true))
    end
  end
end

RSpec.describe 'the examples in the documents' do
  DocExamples::DOCUMENTS.each do |document|
    describe document do
      all_blocks = DocExamples.blocks(document)
      blocks = all_blocks.select { |block| DocExamples.pairs(block).any? }

      it 'checks exactly the pinned number of examples' do
        total = blocks.sum { |block| DocExamples.pairs(block).size }
        expect(total).to eq(DocExamples::PAIRS.fetch(document)),
                         "#{document} has #{total} checked examples; update PAIRS on purpose if that is right"
      end

      it 'has no "# =>" line that is detached from its code' do
        lines = all_blocks.flat_map { |block| DocExamples.detached(block) }
        expect(lines).to be_empty, "#{document}: lines #{lines.join(', ')} start with # => without a line above"
      end

      blocks.each do |block|
        it "is true: #{block.title} (line #{block.first_line})" do
          WebMock.stub_request(:any, /.*/).to_return(
            status: 200, body: DocExamples::RESPONSE_BODY, headers: { 'Content-Type' => 'application/json' }
          )
          apis = DocExamples.apis_of(block)
          ApiRecipes.configure do |config|
            config.logger = Logger.new(IO::NULL)
            config.apis_configs = apis
          end
          before = Object.constants
          scope = Module.new.module_eval { binding }
          start = 0
          begin
            DocExamples.pairs(block).each do |index, expected|
              code = block.lines[start..index].join("\n")
              line = block.first_line + index
              result = begin
                eval(code, scope, document, block.first_line + start)
              rescue Exception => e # rubocop:disable Lint/RescueException
                raise "#{document}:#{line} could not be evaluated: #{e.class}: #{e.message}"
              end
              expect(result.to_s).to eq(expected), "#{document}:#{line}: the example says #{expected.inspect}"
              start = index + 2
            end
          ensure
            (Object.constants - before).each { |name| Object.send(:remove_const, name) }
          end
        end
      end
    end
  end
end
