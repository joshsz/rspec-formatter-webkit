#!/usr/bin/env ruby

require 'pp'
require 'erb'
require 'pathname'
require 'base64'

require 'rspec'
require 'rspec/core/formatters/base_text_formatter'
require 'rspec/core/formatters/snippet_extractor'
require 'rspec/core/pending'


class RSpec::Core::Formatters::WebKit < RSpec::Core::Formatters::BaseTextFormatter
	include ERB::Util

	# Version constant
	VERSION = '2.1.5'

	# Look up the datadir falling back to a relative path (mostly for prerelease testing)
	DATADIR = begin
		dir = Gem.datadir('rspec-formatter-webkit') ||
		      Pathname( __FILE__ ).dirname.parent.parent.parent.parent +
		           'data/rspec-formatter-webkit'
		Pathname( dir )
	end

	# The base HREF used in the header to map stuff to the datadir
	BASE_HREF        = "file://#{DATADIR}/"

	# The directory to grab ERb templates out of
	TEMPLATE_DIR     = DATADIR + 'templates'

	# The page part templates
	HEADER_TEMPLATE          = TEMPLATE_DIR + 'header.rhtml'
	PASSED_EXAMPLE_TEMPLATE  = TEMPLATE_DIR + 'passed.rhtml'
	FAILED_EXAMPLE_TEMPLATE  = TEMPLATE_DIR + 'failed.rhtml'
	PENDING_EXAMPLE_TEMPLATE = TEMPLATE_DIR + 'pending.rhtml'
	PENDFIX_EXAMPLE_TEMPLATE = TEMPLATE_DIR + 'pending-fixed.rhtml'
	FOOTER_TEMPLATE          = TEMPLATE_DIR + 'footer.rhtml'

	# Pattern to match for excluding lines from backtraces
	BACKTRACE_EXCLUDE_PATTERN = %r{spec/mate|textmate-command|rspec(-(core|expectations|mocks))?/}

	# Figure out which class pending-example-fixed errors are (2.8 change)
	PENDING_FIXED_EXCEPTION = if defined?( RSpec::Core::Pending::PendingExampleFixedError )
		RSpec::Core::Pending::PendingExampleFixedError
	else
		RSpec::Core::PendingExampleFixedError
	end


	### Create a new formatter
	def initialize( output ) # :notnew:
		super
		@previous_nesting_depth = 0
		@example_number = 0
		@failcounter = 0
		@snippet_extractor = RSpec::Core::Formatters::SnippetExtractor.new
		@example_templates = {
			:passed        => self.load_template(PASSED_EXAMPLE_TEMPLATE),
			:failed        => self.load_template(FAILED_EXAMPLE_TEMPLATE),
			:pending       => self.load_template(PENDING_EXAMPLE_TEMPLATE),
			:pending_fixed => self.load_template(PENDFIX_EXAMPLE_TEMPLATE),
		}

		Thread.current['logger-output'] = []
	end


	######
	public
	######

	# Attributes made readable for ERb
	attr_reader :example_group_number, :example_number, :example_count

	# The counter for failed example IDs
	attr_accessor :failcounter


	### Start the page by rendering the header.
	def start( example_count )
    @timers ||= []
		@output.puts self.render_header( example_count )
		@output.flush
	end


	### Callback called by each example group when it's entered --
	def example_group_started( example_group )
		super
		nesting_depth = example_group.ancestors.length

		# Close the previous example groups if this one isn't a 
		# descendent of the previous one
		if @previous_nesting_depth.nonzero? && @previous_nesting_depth >= nesting_depth
			( @previous_nesting_depth - nesting_depth + 1 ).times do
				@output.puts "  </dl>", "</section>", "  </dd>"
			end
		end

		@output.puts "<!-- nesting: %d, previous: %d -->" %
			[ nesting_depth, @previous_nesting_depth ]
		@previous_nesting_depth = nesting_depth

		if @previous_nesting_depth == 1
			@output.puts %{<section class="example-group">}
		else
			@output.puts %{<dd class="nested-group"><section class="example-group">}
		end
    anchor_name = example_group.description.downcase.gsub(/[^a-z0-9]+/, ' ').gsub(/ /,'_')
    @output.puts %{<a name="#{anchor_name}"/>}

		@output.puts %{  <dl>},
			%{  <dt id="%s">%s</dt>} % [
			 	example_group.name.gsub(/[\W_]+/, '-').downcase,
				h(example_group.description)
			]
		@output.flush
	end
	alias_method :add_example_group, :example_group_started


	### Fetch any log messages added to the thread-local Array
	def log_messages
		return Thread.current[ 'logger-output' ] || []
	end


	### Callback -- called when the examples are finished.
	def start_dump
		@previous_nesting_depth.downto( 1 ) do |i|
			@output.puts "  </dl>",
			             "</section>"
			@output.puts "  </dd>" unless i == 1
		end

		@output.flush
	end


	### Callback -- called when an example is entered
	def example_started( example )
		@example_number += 1
    @timers << Time.now
		Thread.current[ 'logger-output' ] ||= []
		Thread.current[ 'logger-output' ].clear
	end


	### Callback -- called when an example is exited with no failures.
	def example_passed( example )
		status = 'passed'

    time = Time.now - @timers.pop
    elapsed = ENV['NO_RUNTIME'] ? "" : run_time(time)
		@output.puts( @example_templates[:passed].result(binding()) )
		@output.flush
	end


	### Callback -- called when an example is exited with a failure.
	def example_failed( example )
		super

		counter   = self.failcounter += 1
		exception = example.metadata[:execution_result][:exception]
		extra     = self.extra_failure_content( exception )
		template  = if exception.is_a?( PENDING_FIXED_EXCEPTION )
			then @example_templates[:pending_fixed]
			else @example_templates[:failed]
			end

    time = Time.now - @timers.pop
    elapsed = ENV['NO_RUNTIME'] ? "" : run_time(time)
		@output.puts( template.result(binding()) )
		@output.flush
	end


	### Callback -- called when an example is exited via a 'pending'.
	def example_pending( example )
		status = 'pending'

    time = Time.now - @timers.pop
    elapsed = ENV['NO_RUNTIME'] ? "" : run_time(time)
		@output.puts( @example_templates[:pending].result(binding()) )
		@output.flush
	end


	### Format backtrace lines to include a textmate link to the file/line in question.
	def backtrace_line( line )
		return nil unless line = super
		return nil if line =~ BACKTRACE_EXCLUDE_PATTERN
		return h( line.strip ).gsub( /([^:]*\.rb):(\d*)/ ) do
      if $1.nil?
        "#{$1}:#{$2} "
      else
        "<a href=\"txmt://open?url=file://#{File.expand_path($1)}&amp;line=#{$2}\">#{$1}:#{$2}</a> "
      end
		end
	end


	### Return any stuff that should be appended to the current example
	### because it's failed. Returns a snippet of the source around the
	### failure.
	def extra_failure_content( exception )
		return '' unless exception
		backtrace = exception.backtrace.find {|line| line !~ BACKTRACE_EXCLUDE_PATTERN }
		# $stderr.puts "Using backtrace line %p to extract snippet" % [ backtrace ]
		snippet = @snippet_extractor.snippet([ backtrace ])
		return "    <pre class=\"ruby\"><code>#{snippet}</code></pre>"
	end


	### Returns content to be output when a failure occurs during the run; overridden to
	### do nothing, as failures are handled by #example_failed.
	def dump_failures( *unused )
	end


	### Output the content generated at the end of the run.
	def dump_summary( duration, example_count, failure_count, pending_count )
		@output.puts self.render_footer( duration, example_count, failure_count, pending_count )
		@output.flush
	end


	### Render the header template in the context of the receiver.
	def render_header( example_count )
		template = self.load_template( HEADER_TEMPLATE )
		return template.result( binding() )
	end


	### Render the footer template in the context of the receiver.
	def render_footer( duration, example_count, failure_count, pending_count )
		template = self.load_template( FOOTER_TEMPLATE )
		return template.result( binding() )
	end


	### Load the ERB template at +templatepath+ and return it.
	def load_template( templatepath )
		return ERB.new( templatepath.read, nil, '%<>' ).freeze
	end

  # View helpers to inline assets
  def run_time(time)
    o = ['(']
    time = time.to_f
    if time > 60.0
      o << ((time / 60.0) * 100).round / 100.0 # I'd rather use .round(2) but I'm being friendly to ruby 1.8 for now.
      o << ' m'
    elsif time > 1.0
      o << (time * 100).round / 100.0
      o << ' s'
    else
      o << (time * 100000).round / 100.0
      o << ' ms'
    end
    o << ')'
    o.join
  end

  def compress_css(css_string)
    css_string.gsub(/\/\*.*?\*\//m,'').gsub(/^ *$\n/,'')
  end

  def render_data_urls(css_string)
    css_string.gsub(/url\((.*?)\)/) do |match|
      filename  = $1
      mime_type = "image/#{filename.split(/\./).last}"
      path      = File.join(DATADIR, 'css', filename)
      data      = File.read(path)
      base64    = Base64.encode64(data).split(/\n/).join
      "url(data:#{mime_type};base64,#{base64})"
    end
  end

  def render_css( filename )
    compress_css( render_data_urls( File.read(File.join(DATADIR, 'css', filename)) ))
  end

  def render_js( filename )
    o = ["\n//<![CDATA[\n"]
    o << File.read(File.join(DATADIR, 'js', filename))
    o << "\n//]]>"
    o.join
  end
end # class RSpec::Core::Formatter::WebKitFormatter
