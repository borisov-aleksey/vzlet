require 'strscan'
require 'digest/sha1'
require 'sass/tree/node'
require 'sass/tree/root_node'
require 'sass/tree/rule_node'
require 'sass/tree/comment_node'
require 'sass/tree/prop_node'
require 'sass/tree/directive_node'
require 'sass/tree/variable_node'
require 'sass/tree/mixin_def_node'
require 'sass/tree/mixin_node'
require 'sass/tree/if_node'
require 'sass/tree/while_node'
require 'sass/tree/for_node'
require 'sass/tree/debug_node'
require 'sass/tree/import_node'
require 'sass/environment'
require 'sass/script'
require 'sass/error'
require 'sass/files'
require 'haml/shared'

module Sass
  # A Sass mixin.
  #
  # `name`: `String`
  # : The name of the mixin.
  #
  # `args`: `Array<(String, Script::Node)>`
  # : The arguments for the mixin.
  #   Each element is a tuple containing the name of the argument
  #   and the parse tree for the default value of the argument.
  #
  # `environment`: {Sass::Environment}
  # : The environment in which the mixin was defined.
  #   This is captured so that the mixin can have access
  #   to local variables defined in its scope.
  #
  # `tree`: {Sass::Tree::Node}
  # : The parse tree for the mixin.
  Mixin = Struct.new(:name, :args, :environment, :tree)

  # This class handles the parsing and compilation of the Sass template.
  # Example usage:
  #
  #     template = File.load('stylesheets/sassy.sass')
  #     sass_engine = Sass::Engine.new(template)
  #     output = sass_engine.render
  #     puts output
  class Engine
    include Haml::Util

    # A line of Sass code.
    #
    # `text`: `String`
    # : The text in the line, without any whitespace at the beginning or end.
    #
    # `tabs`: `Fixnum`
    # : The level of indentation of the line.
    #
    # `index`: `Fixnum`
    # : The line number in the original document.
    #
    # `offset`: `Fixnum`
    # : The number of bytes in on the line that the text begins.
    #   This ends up being the number of bytes of leading whitespace.
    #
    # `filename`: `String`
    # : The name of the file in which this line appeared.
    #
    # `children`: `Array<Line>`
    # : The lines nested below this one.
    class Line < Struct.new(:text, :tabs, :index, :offset, :filename, :children)
      def comment?
        text[0] == COMMENT_CHAR && (text[1] == SASS_COMMENT_CHAR || text[1] == CSS_COMMENT_CHAR)
      end
    end

    # The character that begins a CSS property.
    # @private
    PROPERTY_CHAR  = ?:

    # The character that designates that
    # a property should be assigned to a SassScript expression.
    # @private
    SCRIPT_CHAR     = ?=

    # The character that designates the beginning of a comment,
    # either Sass or CSS.
    # @private
    COMMENT_CHAR = ?/

    # The character that follows the general COMMENT_CHAR and designates a Sass comment,
    # which is not output as a CSS comment.
    # @private
    SASS_COMMENT_CHAR = ?/

    # The character that follows the general COMMENT_CHAR and designates a CSS comment,
    # which is embedded in the CSS document.
    # @private
    CSS_COMMENT_CHAR = ?*

    # The character used to denote a compiler directive.
    # @private
    DIRECTIVE_CHAR = ?@

    # Designates a non-parsed rule.
    # @private
    ESCAPE_CHAR    = ?\\

    # Designates block as mixin definition rather than CSS rules to output
    # @private
    MIXIN_DEFINITION_CHAR = ?=

    # Includes named mixin declared using MIXIN_DEFINITION_CHAR
    # @private
    MIXIN_INCLUDE_CHAR    = ?+

    # The regex that matches properties of the form `name: prop`.
    # @private
    PROPERTY_NEW_MATCHER = /^[^\s:"\[]+\s*[=:](\s|$)/

    # The regex that matches and extracts data from
    # properties of the form `name: prop`.
    # @private
    PROPERTY_NEW = /^([^\s=:"]+)(\s*=|:)(?:\s+|$)(.*)/

    # The regex that matches and extracts data from
    # properties of the form `:name prop`.
    # @private
    PROPERTY_OLD = /^:([^\s=:"]+)\s*(=?)(?:\s+|$)(.*)/

    # The default options for Sass::Engine.
    DEFAULT_OPTIONS = {
      :style => :nested,
      :load_paths => ['.'],
      :cache => true,
      :cache_location => './.sass-cache',
    }.freeze

    # @param template [String] The Sass template.
    # @param options [{Symbol => Object}] An options hash;
    #   see {file:SASS_REFERENCE.md#sass_options the Sass options documentation}
    def initialize(template, options={})
      @options = DEFAULT_OPTIONS.merge(options.reject {|k, v| v.nil?})
      @template = template

      # Support both, because the docs said one and the other actually worked
      # for quite a long time.
      @options[:line_comments] ||= @options[:line_numbers]

      # Backwards compatibility
      @options[:property_syntax] ||= @options[:attribute_syntax]
      case @options[:property_syntax]
      when :alternate; @options[:property_syntax] = :new
      when :normal; @options[:property_syntax] = :old
      end
    end

    # Render the template to CSS.
    #
    # @return [String] The CSS
    # @raise [Sass::SyntaxError] if there's an error in the document
    def render
      to_tree.render
    end

    alias_method :to_css, :render

    # Parses the document into its parse tree.
    #
    # @return [Sass::Tree::Node] The root of the parse tree.
    # @raise [Sass::SyntaxError] if there's an error in the document
    def to_tree
      check_encoding(@template) {|msg, line| raise Sass::SyntaxError.new(msg, :line => line)}

      root = Tree::RootNode.new(@template)
      append_children(root, tree(tabulate(@template)).first, true)
      root.options = @options
      root
    rescue SyntaxError => e
      e.modify_backtrace(:filename => @options[:filename], :line => @line)
      e.sass_template = @template
      raise e
    end

    private

    def tabulate(string)
      tab_str = nil
      comment_tab_str = nil
      first = true
      lines = []
      string.gsub(/\r|\n|\r\n|\r\n/, "\n").scan(/^.*?$/).each_with_index do |line, index|
        index += (@options[:line] || 1)
        if line.strip.empty?
          lines.last.text << "\n" if lines.last && lines.last.comment?
          next
        end

        line_tab_str = line[/^\s*/]
        unless line_tab_str.empty?
          if tab_str.nil?
            comment_tab_str ||= line_tab_str
            next if try_comment(line, lines.last, "", comment_tab_str, index)
            comment_tab_str = nil
          end

          tab_str ||= line_tab_str

          raise SyntaxError.new("Indenting at the beginning of the document is illegal.",
            :line => index) if first

          raise SyntaxError.new("Indentation can't use both tabs and spaces.",
            :line => index) if tab_str.include?(?\s) && tab_str.include?(?\t)
        end
        first &&= !tab_str.nil?
        if tab_str.nil?
          lines << Line.new(line.strip, 0, index, 0, @options[:filename], [])
          next
        end

        comment_tab_str ||= line_tab_str
        if try_comment(line, lines.last, tab_str * (lines.last.tabs + 1), comment_tab_str, index)
          next
        else
          comment_tab_str = nil
        end

        line_tabs = line_tab_str.scan(tab_str).size
        if tab_str * line_tabs != line_tab_str
          message = <<END.strip.gsub("\n", ' ')
Inconsistent indentation: #{Haml::Shared.human_indentation line_tab_str, true} used for indentation,
but the rest of the document was indented using #{Haml::Shared.human_indentation tab_str}.
END
          raise SyntaxError.new(message, :line => index)
        end

        lines << Line.new(line.strip, line_tabs, index, tab_str.size, @options[:filename], [])
      end
      lines
    end

    def try_comment(line, last, tab_str, comment_tab_str, index)
      return unless last && last.comment?
      return unless line =~ /^#{tab_str}/
      unless line =~ /^(?:#{comment_tab_str})(.*)$/
        raise SyntaxError.new(<<MSG.strip.gsub("\n", " "), :line => index)
Inconsistent indentation:
previous line was indented by #{Haml::Shared.human_indentation comment_tab_str},
but this line was indented by #{Haml::Shared.human_indentation line[/^\s*/]}.
MSG
      end

      last.text << "\n" << $1
      true
    end

    def tree(arr, i = 0)
      return [], i if arr[i].nil?

      base = arr[i].tabs
      nodes = []
      while (line = arr[i]) && line.tabs >= base
        if line.tabs > base
          raise SyntaxError.new("The line was indented #{line.tabs - base} levels deeper than the previous line.",
            :line => line.index) if line.tabs > base + 1

          nodes.last.children, i = tree(arr, i)
        else
          nodes << line
          i += 1
        end
      end
      return nodes, i
    end

    def build_tree(parent, line, root = false)
      @line = line.index
      node_or_nodes = parse_line(parent, line, root)

      Array(node_or_nodes).each do |node|
        # Node is a symbol if it's non-outputting, like a variable assignment
        next unless node.is_a? Tree::Node

        node.line = line.index
        node.filename = line.filename

        if node.is_a?(Tree::CommentNode)
          node.lines = line.children
        else
          append_children(node, line.children, false)
        end
      end

      node_or_nodes
    end

    def append_children(parent, children, root)
      continued_rule = nil
      children.each do |line|
        child = build_tree(parent, line, root)

        if child.is_a?(Tree::RuleNode) && child.continued?
          raise SyntaxError.new("Rules can't end in commas.",
            :line => child.line) unless child.children.empty?
          if continued_rule
            continued_rule.add_rules child
          else
            continued_rule = child
          end
          next
        end

        if continued_rule
          raise SyntaxError.new("Rules can't end in commas.",
            :line => continued_rule.line) unless child.is_a?(Tree::RuleNode)
          continued_rule.add_rules child
          continued_rule.children = child.children
          continued_rule, child = nil, continued_rule
        end

        check_for_no_children(child)
        validate_and_append_child(parent, child, line, root)
      end

      raise SyntaxError.new("Rules can't end in commas.",
        :line => continued_rule.line) if continued_rule

      parent
    end

    def validate_and_append_child(parent, child, line, root)
      unless root
        case child
        when Tree::MixinDefNode
          raise SyntaxError.new("Mixins may only be defined at the root of a document.",
            :line => line.index)
        when Tree::ImportNode
          raise SyntaxError.new("Import directives may only be used at the root of a document.",
            :line => line.index)
        end
      end

      case child
      when Array
        child.each {|c| validate_and_append_child(parent, c, line, root)}
      when Tree::Node
        parent << child
      end
    end

    def check_for_no_children(node)
      return unless node.is_a?(Tree::RuleNode) && node.children.empty?
      warning = (node.rules.size == 1) ? <<SHORT : <<LONG
WARNING on line #{node.line}#{" of #{node.filename}" if node.filename}:
Selector #{node.rules.first.inspect} doesn't have any properties and will not be rendered.
SHORT

WARNING on line #{node.line}#{" of #{node.filename}" if node.filename}:
Selector
  #{node.rules.join("\n  ")}
doesn't have any properties and will not be rendered.
LONG

      warn(warning.strip)
    end

    def parse_line(parent, line, root)
      case line.text[0]
      when PROPERTY_CHAR
        if line.text[1] == PROPERTY_CHAR ||
            (@options[:property_syntax] == :new &&
             line.text =~ PROPERTY_OLD && $3.empty?)
          # Support CSS3-style pseudo-elements,
          # which begin with ::,
          # as well as pseudo-classes
          # if we're using the new property syntax
          Tree::RuleNode.new(line.text)
        else
          parse_property(line, PROPERTY_OLD)
        end
      when Script::VARIABLE_CHAR
        parse_variable(line)
      when COMMENT_CHAR
        parse_comment(line.text)
      when DIRECTIVE_CHAR
        parse_directive(parent, line, root)
      when ESCAPE_CHAR
        Tree::RuleNode.new(line.text[1..-1])
      when MIXIN_DEFINITION_CHAR
        parse_mixin_definition(line)
      when MIXIN_INCLUDE_CHAR
        if line.text[1].nil? || line.text[1] == ?\s
          Tree::RuleNode.new(line.text)
        else
          parse_mixin_include(line, root)
        end
      else
        if line.text =~ PROPERTY_NEW_MATCHER
          parse_property(line, PROPERTY_NEW)
        else
          Tree::RuleNode.new(line.text)
        end
      end
    end

    def parse_property(line, property_regx)
      name, eq, value = line.text.scan(property_regx)[0]

      raise SyntaxError.new("Invalid property: \"#{line.text}\".",
        :line => @line) if name.nil? || value.nil?

      expr = if (eq.strip[0] == SCRIPT_CHAR)
        parse_script(value, :offset => line.offset + line.text.index(value))
      else
        value
      end
      Tree::PropNode.new(name, expr, property_regx == PROPERTY_OLD ? :old : :new)
    end

    def parse_variable(line)
      name, op, value = line.text.scan(Script::MATCH)[0]
      raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath variable declarations.",
        :line => @line + 1) unless line.children.empty?
      raise SyntaxError.new("Invalid variable: \"#{line.text}\".",
        :line => @line) unless name && value

      Tree::VariableNode.new(name, parse_script(value, :offset => line.offset + line.text.index(value)), op == '||=')
    end

    def parse_comment(line)
      if line[1] == CSS_COMMENT_CHAR || line[1] == SASS_COMMENT_CHAR
        Tree::CommentNode.new(line, line[1] == SASS_COMMENT_CHAR)
      else
        Tree::RuleNode.new(line)
      end
    end

    def parse_directive(parent, line, root)
      directive, whitespace, value = line.text[1..-1].split(/(\s+)/, 2)
      offset = directive.size + whitespace.size + 1 if whitespace

      # If value begins with url( or ",
      # it's a CSS @import rule and we don't want to touch it.
      if directive == "import" && value !~ /^(url\(|")/
        raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath import directives.",
          :line => @line + 1) unless line.children.empty?
        value.split(/,\s*/).map {|f| Tree::ImportNode.new(f)}
      elsif directive == "for"
        parse_for(line, root, value)
      elsif directive == "else"
        parse_else(parent, line, value)
      elsif directive == "while"
        raise SyntaxError.new("Invalid while directive '@while': expected expression.") unless value
        Tree::WhileNode.new(parse_script(value, :offset => offset))
      elsif directive == "if"
        raise SyntaxError.new("Invalid if directive '@if': expected expression.") unless value
        Tree::IfNode.new(parse_script(value, :offset => offset))
      elsif directive == "debug"
        raise SyntaxError.new("Invalid debug directive '@debug': expected expression.") unless value
        raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath debug directives.",
          :line => @line + 1) unless line.children.empty?
        offset = line.offset + line.text.index(value).to_i
        Tree::DebugNode.new(parse_script(value, :offset => offset))
      else
        Tree::DirectiveNode.new(line.text)
      end
    end

    def parse_for(line, root, text)
      var, from_expr, to_name, to_expr = text.scan(/^([^\s]+)\s+from\s+(.+)\s+(to|through)\s+(.+)$/).first

      if var.nil? # scan failed, try to figure out why for error message
        if text !~ /^[^\s]+/
          expected = "variable name"
        elsif text !~ /^[^\s]+\s+from\s+.+/
          expected = "'from <expr>'"
        else
          expected = "'to <expr>' or 'through <expr>'"
        end
        raise SyntaxError.new("Invalid for directive '@for #{text}': expected #{expected}.")
      end
      raise SyntaxError.new("Invalid variable \"#{var}\".") unless var =~ Script::VALIDATE

      parsed_from = parse_script(from_expr, :offset => line.offset + line.text.index(from_expr))
      parsed_to = parse_script(to_expr, :offset => line.offset + line.text.index(to_expr))
      Tree::ForNode.new(var[1..-1], parsed_from, parsed_to, to_name == 'to')
    end

    def parse_else(parent, line, text)
      previous = parent.last
      raise SyntaxError.new("@else must come after @if.") unless previous.is_a?(Tree::IfNode)

      if text
        if text !~ /^if\s+(.+)/
          raise SyntaxError.new("Invalid else directive '@else #{text}': expected 'if <expr>'.")
        end
        expr = parse_script($1, :offset => line.offset + line.text.index($1))
      end

      node = Tree::IfNode.new(expr)
      append_children(node, line.children, false)
      previous.add_else node
      nil
    end

    def parse_mixin_definition(line)
      name, arg_string = line.text.scan(/^=\s*([^(]+)(.*)$/).first
      raise SyntaxError.new("Invalid mixin \"#{line.text[1..-1]}\".") if name.nil?

      offset = line.offset + line.text.size - arg_string.size
      args = Script::Parser.new(arg_string.strip, @line, offset, @options).
        parse_mixin_definition_arglist
      default_arg_found = false
      Tree::MixinDefNode.new(name, args)
    end

    def parse_mixin_include(line, root)
      name, arg_string = line.text.scan(/^\+\s*([^(]+)(.*)$/).first
      raise SyntaxError.new("Invalid mixin include \"#{line.text}\".") if name.nil?

      offset = line.offset + line.text.size - arg_string.size
      args = Script::Parser.new(arg_string.strip, @line, offset, @options).
        parse_mixin_include_arglist
      raise SyntaxError.new("Illegal nesting: Nothing may be nested beneath mixin directives.",
        :line => @line + 1) unless line.children.empty?
      Tree::MixinNode.new(name, args)
    end

    def parse_script(script, options = {})
      line = options[:line] || @line
      offset = options[:offset] || 0
      Script.parse(script, line, offset, @options)
    end
  end
end
