# encoding: utf-8
# author: Dominik Richter
# author: Christoph Hartmann
# author: John Kerry

require 'rspec/core'
require 'rspec/core/formatters/json_formatter'

# Vanilla RSpec JSON formatter with a slight extension to show example IDs.
# TODO: Remove these lines when RSpec includes the ID natively
class InspecRspecVanilla < RSpec::Core::Formatters::JsonFormatter
  RSpec::Core::Formatters.register self

  private

  # We are cheating and overriding a private method in RSpec's core JsonFormatter.
  # This is to avoid having to repeat this id functionality in both dump_summary
  # and dump_profile (both of which call format_example).
  # See https://github.com/rspec/rspec-core/blob/master/lib/rspec/core/formatters/json_formatter.rb
  #
  # rspec's example id here corresponds to an inspec test's control name -
  # either explicitly specified or auto-generated by rspec itself.
  def format_example(example)
    res = super(example)
    res[:id] = example.metadata[:id]
    res
  end
end

# Minimal JSON formatter for inspec. Only contains limited information about
# examples without any extras.
class InspecRspecMiniJson < RSpec::Core::Formatters::JsonFormatter
  # Don't re-register all the call-backs over and over - we automatically
  # inherit all callbacks registered by the parent class.
  RSpec::Core::Formatters.register self, :dump_summary, :stop

  # Called after stop has been called and the run is complete.
  def dump_summary(summary)
    @output_hash[:version] = Inspec::VERSION
    @output_hash[:statistics] = {
      duration: summary.duration,
    }
  end

  # Called at the end of a complete RSpec run.
  def stop(notification)
    # This might be a bit confusing. The results are not actually organized
    # by control. It is organized by test. So if a control has 3 tests, the
    # output will have 3 control entries, each one with the same control id
    # and different test results. An rspec example maps to an inspec test.
    @output_hash[:controls] = notification.examples.map do |example|
      format_example(example).tap do |hash|
        e = example.exception
        next unless e
        hash[:message] = e.message

        next if e.is_a? RSpec::Expectations::ExpectationNotMetError
        hash[:exception] = e.class.name
        hash[:backtrace] = e.backtrace
      end
    end
  end

  private

  def format_example(example)
    if !example.metadata[:description_args].empty? && example.metadata[:skip]
      # For skipped profiles, rspec returns in full_description the skip_message as well. We don't want
      # to mix the two, so we pick the full_description from the example.metadata[:example_group] hash.
      code_description = example.metadata[:example_group][:description]
    else
      code_description = example.metadata[:full_description]
    end

    res = {
      id: example.metadata[:id],
      profile_id: example.metadata[:profile_id],
      status: example.execution_result.status.to_s,
      code_desc: code_description,
    }

    unless (pid = example.metadata[:profile_id]).nil?
      res[:profile_id] = pid
    end

    if res[:status] == 'pending'
      res[:status] = 'skipped'
      res[:skip_message] = example.metadata[:description]
      res[:resource] = example.metadata[:described_class].to_s
    end

    res
  end
end

class InspecRspecJson < InspecRspecMiniJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :stop, :dump_summary
  attr_writer :backend

  def initialize(*args)
    super(*args)
    @profiles = []
    @profiles_info = nil
    @backend = nil
  end

  # Called by the runner during example collection.
  def add_profile(profile)
    @profiles.push(profile)
  end

  def stop(notification)
    super(notification)

    @output_hash[:other_checks] = examples_without_controls
    @output_hash[:profiles] = profiles_info

    examples_with_controls.each do |example|
      control = example2control(example)
      move_example_into_control(example, control)
    end
  end

  private

  def all_unique_controls
    Array(@all_controls).uniq
  end

  def profile_summary
    failed = 0
    skipped = 0
    passed = 0
    critical = 0
    major = 0
    minor = 0

    all_unique_controls.each do |control|
      next if control[:id].start_with? '(generated from '
      next unless control[:results]
      if control[:results].any? { |r| r[:status] == 'failed' }
        failed += 1
        if control[:impact] >= 0.7
          critical += 1
        elsif control[:impact] >= 0.4
          major += 1
        else
          minor += 1
        end
      elsif control[:results].any? { |r| r[:status] == 'skipped' }
        skipped += 1
      else
        passed += 1
      end
    end

    total = failed + passed + skipped

    { 'total' => total,
      'failed' => {
        'total' => failed,
        'critical' => critical,
        'major' => major,
        'minor' => minor,
      },
      'skipped' => skipped,
      'passed' => passed }
  end

  def tests_summary
    total = 0
    failed = 0
    skipped = 0
    passed = 0

    all_unique_controls.each do |control|
      next unless control[:results]
      control[:results].each do |result|
        if result[:status] == 'failed'
          failed += 1
        elsif result[:status] == 'skipped'
          skipped += 1
        else
          passed += 1
        end
      end
    end

    { 'total' => total, 'failed' => failed, 'skipped' => skipped, 'passed' => passed }
  end

  def examples
    @output_hash[:controls]
  end

  def examples_without_controls
    examples.find_all { |example| example2control(example).nil? }
  end

  def examples_with_controls
    (examples - examples_without_controls)
  end

  def profiles_info
    @profiles_info ||= @profiles.map(&:info!).map(&:dup)
  end

  def example2control(example)
    profile = profile_from_example(example)
    return nil unless profile && profile[:controls]
    profile[:controls].find { |x| x[:id] == example[:id] }
  end

  def profile_from_example(example)
    profiles_info.find { |p| profile_contains_example?(p, example) }
  end

  def profile_contains_example?(profile, example)
    profile_name = profile[:name]
    example_profile_id = example[:profile_id]

    # if either the profile name is nil or the profile in the given example
    # is nil, assume the profile doesn't contain the example and default
    # to creating a new profile. Otherwise, for profiles that have no
    # metadata, this may incorrectly match a profile that does not contain
    # this example, leading to Ruby exceptions.
    return false if profile_name.nil? || example_profile_id.nil?

    profile_name == example_profile_id
  end

  def move_example_into_control(example, control)
    control[:results] ||= []
    example.delete(:id)
    example.delete(:profile_id)
    control[:results].push(example)
  end

  def format_example(example)
    super(example).tap do |res|
      res[:run_time]   = example.execution_result.run_time
      res[:start_time] = example.execution_result.started_at.to_s
    end
  end
end

class InspecRspecCli < InspecRspecJson # rubocop:disable Metrics/ClassLength
  RSpec::Core::Formatters.register self, :close

  case RUBY_PLATFORM
  when /windows|mswin|msys|mingw|cygwin/

    # Most currently available Windows terminals have poor support
    # for ANSI extended colors
    COLORS = {
      'critical' => "\033[0;1;31m",
      'major'    => "\033[0;1;31m",
      'minor'    => "\033[0;36m",
      'failed'   => "\033[0;1;31m",
      'passed'   => "\033[0;1;32m",
      'skipped'  => "\033[0;37m",
      'reset'    => "\033[0m",
    }.freeze

    # Most currently available Windows terminals have poor support
    # for UTF-8 characters so use these boring indicators
    INDICATORS = {
      'critical' => '  [CRIT]  ',
      'major'    => '  [MAJR]  ',
      'minor'    => '  [MINR]  ',
      'failed'   => '  [FAIL]  ',
      'skipped'  => '  [SKIP]  ',
      'passed'   => '  [PASS]  ',
      'unknown'  => '  [UNKN]  ',
      'empty'    => '     ',
      'small'    => '   ',
    }.freeze
  else
    # Extended colors for everyone else
    COLORS = {
      'critical' => "\033[38;5;9m",
      'major'    => "\033[38;5;208m",
      'minor'    => "\033[0;36m",
      'failed'   => "\033[38;5;9m",
      'passed'   => "\033[38;5;41m",
      'skipped'  => "\033[38;5;247m",
      'reset'    => "\033[0m",
    }.freeze

    # Groovy UTF-8 characters for everyone else...
    # ...even though they probably only work on Mac
    INDICATORS = {
      'critical' => '  ×  ',
      'major'    => '  ∅  ',
      'minor'    => '  ⊚  ',
      'failed'   => '  ×  ',
      'skipped'  => '  ↺  ',
      'passed'   => '  ✔  ',
      'unknown'  => '  ?  ',
      'empty'    => '     ',
      'small'    => '   ',
    }.freeze
  end

  MULTI_TEST_CONTROL_SUMMARY_MAX_LEN = 60

  def initialize(*args)
    @current_control = nil
    @all_controls = []
    @profile_printed = false
    super(*args)
  end

  #
  # This method is called through the RSpec Formatter interface for every
  # example found in the test suite.
  #
  # Within #format_example we are getting and example and:
  #    * if this is an example, within a control, within a profile then we want
  #      to display the profile header, display the control, and then display
  #      the example.
  #    * if this is another example, within the same control, within the same
  #      profile we want to display the example.
  #    * if this is an example that does not map to a control (anonymous) then
  #      we want to store it for later to displayed at the end of a profile.
  #
  def format_example(example)
    example_data = super(example)
    control = create_or_find_control(example_data)

    # If we are switching to a new control then we want to print the control
    # we were previously collecting examples unless the last control is
    # anonymous (no control). Anonymous controls and their examples are handled
    # later on the profile change.

    if switching_to_new_control?(control)
      print_last_control_with_examples unless last_control_is_anonymous?
    end

    store_last_control(control)

    # Each profile may have zero or more anonymous examples. These are examples
    # that defined in a profile but outside of a control. They may be defined
    # at the start, in-between, or end of list of examples. To display them
    # at the very end of a profile, which means we have to wait for the profile
    # to change to know we are done with a profile.

    if switching_to_new_profile?(control.profile)
      output.puts ''
      print_anonymous_examples_associated_with_last_profile
      clear_anonymous_examples_associated_with_last_profile
    end

    print_profile(control.profile)
    store_last_profile(control.profile)

    # The anonymous controls should be added to a hash that we will display
    # when we are done examining all the examples within this profile.

    if control.anonymous?
      add_anonymous_example_within_this_profile(control.as_hash)
    end

    @all_controls.push(control.as_hash)
    example_data
  end

  #
  # This is the last method is invoked through the formatter interface.
  # Because the profile
  # we may have some remaining anonymous examples so we want to display them
  # as well as a summary of the profile and test stats.
  #
  def close(_notification)
    # when the profile has no controls or examples it will not have been printed.
    # then we want to ensure we print all the profiles
    print_last_control_with_examples unless last_control_is_anonymous?
    output.puts ''
    print_anonymous_examples_associated_with_last_profile
    print_profiles_without_examples
    print_profile_summary
    print_tests_summary
  end

  private

  #
  # With the example we can find the profile associated with it and if there
  # is already a control defined. If there is one then we will use that data
  # to build our control object. If there isn't we simply create a new hash of
  # controld data that will be populated from the examples that are found.
  #
  # @return [Control] A new control or one found associated with the example.
  #
  def create_or_find_control(example)
    profile = profile_from_example(example)

    control_data = {}

    if profile && profile[:controls]
      control_data = profile[:controls].find { |ctrl| ctrl[:id] == example[:id] }
    end

    control = Control.new(control_data, profile)
    control.add_example(example)

    control
  end

  #
  # If there is already a control we have have seen before and it is different
  # than the new control then we are indeed switching controls.
  #
  def switching_to_new_control?(control)
    @last_control && @last_control != control
  end

  def store_last_control(control)
    @last_control = control
  end

  def print_last_control_with_examples
    if @last_control
      print_control(@last_control)
      @last_control.examples.each { |example| print_result(example) }
    end
  end

  def last_control_is_anonymous?
    @last_control && @last_control.anonymous?
  end

  #
  # If there is a profile we have seen before and it is different than the
  # new profile then we are indeed switching profiles.
  #
  def switching_to_new_profile?(new_profile)
    @last_profile && @last_profile != new_profile
  end

  #
  # Print all the anonymous examples that have been found for this profile
  #
  def print_anonymous_examples_associated_with_last_profile
    Array(anonymous_examples_within_this_profile).uniq.each do |control|
      print_anonymous_control(control)
    end
    output.puts '' unless Array(anonymous_examples_within_this_profile).empty?
  end

  #
  # As we process examples we need an accumulator that will allow us to store
  # all the examples that do not have a named control associated with them.
  #
  def anonymous_examples_within_this_profile
    @anonymous_examples_within_this_profile ||= []
  end

  #
  # Remove all controls from the anonymous examples that are tracked.
  #
  def clear_anonymous_examples_associated_with_last_profile
    @anonymous_examples_within_this_profile = []
  end

  #
  # Append a new control to the anonymous examples
  #
  def add_anonymous_example_within_this_profile(control)
    anonymous_examples_within_this_profile.push(control)
  end

  def store_last_profile(new_profile)
    @last_profile = new_profile
  end

  #
  # Print the profile
  #
  #   * For anonymous profiles, where are generated for examples and controls
  #     defined outside of a profile, simply display the target information
  #   * For profiles without a title use the name (or 'unknown'), version,
  #     and target information.
  #   * For all other profiles display the title with name (or 'unknown'),
  #     version, and target information.
  #
  def print_profile(profile)
    return if profile.nil? || profile[:already_printed]
    output.puts ''

    if profile[:name].nil?
      print_target
      profile[:already_printed] = true
      return
    end

    if profile[:title].nil?
      output.puts "Profile: #{profile[:name] || 'unknown'}"
    else
      output.puts "Profile: #{profile[:title]} (#{profile[:name] || 'unknown'})"
    end

    output.puts 'Version: ' + (profile[:version] || '(not specified)')
    print_target
    profile[:already_printed] = true
  end

  def print_profiles_without_examples
    profiles_info.reject { |p| p[:already_printed] }.each do |profile|
      print_profile(profile)
      print_line(
        color: '', indicator: INDICATORS['empty'], id: '', profile: '',
        summary: 'No tests executed.'
      )
      output.puts ''
    end
  end

  #
  # This target information displays which system that came under test
  #
  def print_target
    return if @backend.nil?
    connection = @backend.backend
    return unless connection.respond_to?(:uri)
    output.puts('Target:  ' + connection.uri + "\n\n")
  end

  #
  # We want to print the details about the control
  #
  def print_control(control)
    print_line(
      color:      control.summary_indicator,
      indicator:  INDICATORS[control.summary_indicator] || INDICATORS['unknown'],
      summary:    format_lines(control.summary, INDICATORS['empty']),
      id:         "#{control.id}: ",
      profile:    control.profile_id,
    )
  end

  def print_result(result)
    test_status = result[:status_type]
    indicator = INDICATORS[result[:status]]
    indicator = INDICATORS['empty'] if indicator.nil?
    if result[:message]
      msg = result[:code_desc] + "\n" + result[:message]
    else
      msg = result[:skip_message] || result[:code_desc]
    end
    print_line(
      color:      test_status,
      indicator:  INDICATORS['small'] + indicator,
      summary:    format_lines(msg, INDICATORS['empty']),
      id: nil, profile: nil
    )
  end

  def print_anonymous_control(control)
    control_result = control[:results]
    title = control_result[0][:code_desc].split[0..1].join(' ')
    puts '  ' + title
    # iterate over all describe blocks in anonoymous control block
    control_result.each do |test|
      control_id = ''
      # display exceptions
      unless test[:exception].nil?
        test_result = test[:message]
      else
        # determine title
        test_result = test[:skip_message] || test[:code_desc].split[2..-1].join(' ')
        # show error message
        test_result += "\n" + test[:message] unless test[:message].nil?
      end
      status_indicator = test[:status_type]
      print_line(
        color:      status_indicator,
        indicator:  INDICATORS['small'] + INDICATORS[status_indicator] || INDICATORS['unknown'],
        summary:    format_lines(test_result, INDICATORS['empty']),
        id:         control_id,
        profile:    control[:profile_id],
      )
    end
  end

  def print_profile_summary
    summary = profile_summary
    return unless summary['total'] > 0

    s = format('Profile Summary: %s, %s, %s',
               format_with_color('passed', "#{summary['passed']} successful"),
               format_with_color('failed', "#{summary['failed']['total']} failures"),
               format_with_color('skipped', "#{summary['skipped']} skipped"),
              )
    output.puts(s) if summary['total'] > 0
  end

  def print_tests_summary
    summary = tests_summary

    s = format('Test Summary: %s, %s, %s',
               format_with_color('passed', "#{summary['passed']} successful"),
               format_with_color('failed', "#{summary['failed']} failures"),
               format_with_color('skipped', "#{summary['skipped']} skipped"),
              )

    output.puts(s)
  end

  # Formats the line (called from print_line)
  def format_line(fields)
    format = '%indicator%id%summary'
    format.gsub(/%\w+/) do |x|
      term = x[1..-1]
      fields.key?(term.to_sym) ? fields[term.to_sym].to_s : x
    end
  end

  # Prints line; used to print results
  def print_line(fields)
    output.puts(format_with_color(fields[:color], format_line(fields)))
  end

  # Helps formatting summary lines (called from within print_line arguments)
  def format_lines(lines, indentation)
    lines.gsub(/\n/, "\n" + indentation)
  end

  def format_with_color(color_name, text)
    return text unless RSpec.configuration.color
    return text unless COLORS.key?(color_name)

    "#{COLORS[color_name]}#{text}#{COLORS['reset']}"
  end

  #
  # This class wraps a control hash object to provide a useful inteface for
  # maintaining the associated profile, ids, results, title, etc.
  #
  class Control # rubocop:disable Metrics/ClassLength
    include Comparable

    STATUS_TYPES = {
      'unknown'  => -3,
      'passed'   => -2,
      'skipped'  => -1,
      'minor'    => 1,
      'major'    => 2,
      'failed'   => 2.5,
      'critical' => 3,
    }.freeze

    def initialize(control, profile)
      @control = control
      @profile = profile
      summary_calculation_is_needed
    end

    attr_reader :control, :profile

    alias as_hash control

    def id
      control[:id]
    end

    def anonymous?
      control[:id].to_s.start_with? '(generated from '
    end

    def profile_id
      control[:profile_id]
    end

    def examples
      control[:results]
    end

    def summary_indicator
      calculate_summary! if summary_calculation_needed?
      STATUS_TYPES.key(@summary_status)
    end

    def add_example(example)
      control[:id] = example[:id]
      control[:profile_id] = example[:profile_id]

      example[:status_type] = status_type(example)
      example.delete(:id)
      example.delete(:profile_id)

      control[:results] ||= []
      control[:results].push(example)
      summary_calculation_is_needed
    end

    # Determine title for control given current_control.
    # Called from current_control_summary.
    def title
      title = control[:title]
      if title
        title
      elsif examples.length == 1
        # If it's an anonymous control, just go with the only description
        # available for the underlying test.
        examples[0][:code_desc].to_s
      elsif examples.empty?
        # Empty control block - if it's anonymous, there's nothing we can do.
        # Is this case even possible?
        'Empty anonymous control'
      else
        # Multiple tests - but no title. Do our best and generate some form of
        # identifier or label or name.
        title = (examples.map { |example| example[:code_desc] }).join('; ')
        max_len = MULTI_TEST_CONTROL_SUMMARY_MAX_LEN
        title = title[0..(max_len-1)] + '...' if title.length > max_len
        title
      end
    end

    # Return summary of the control which is usually a title with fails and skips
    def summary
      calculate_summary! if summary_calculation_needed?
      suffix =
        if examples.length == 1
          # Single test - be nice and just print the exception message if the test
          # failed. No need to say "1 failed".
          examples[0][:message].to_s
        else
          [
            !fails.empty? ? "#{fails.uniq.length} failed" : nil,
            !skips.empty? ? "#{skips.uniq.length} skipped" : nil,
          ].compact.join(' ')
        end

      suffix == '' ? title : title + ' (' + suffix + ')'
    end

    # We are interested in comparing controls against other controls. It is
    # important to compare their id values and the id values of their profiles.
    # In the event that a control has the same id in a different profile we
    # do not want them to be considered the same.
    #
    # Controls are never ordered so we don't care about the remaining
    # implementation of the spaceship operator.
    #
    def <=>(other)
      if id == other.id && profile_id == other.profile_id
        0
      else
        -1
      end
    end

    private

    attr_reader :summary_calculation_needed, :skips, :fails, :passes

    alias summary_calculation_needed? summary_calculation_needed

    def summary_calculation_is_needed
      @summary_calculation_needed = true
    end

    def summary_has_been_calculated
      @summary_calculation_needed = false
    end

    def calculate_summary!
      @summary_status = STATUS_TYPES['unknown']
      @skips = []
      @fails = []
      @passes = []
      examples.each { |example| update_summary(example) }
      summary_has_been_calculated
    end

    def update_summary(example)
      example_status = STATUS_TYPES[example[:status_type]]
      @summary_status = example_status if example_status > @summary_status
      fails.push(example) if example_status > 0
      passes.push(example) if example_status == STATUS_TYPES['passed']
      skips.push(example) if example_status == STATUS_TYPES['skipped']
    end

    # Determines 'status_type' (critical, major, minor) of control given
    # status (failed/passed/skipped) and impact value (0.0 - 1.0).
    # Called from format_example, sets the 'status_type' for each 'example'
    def status_type(example)
      status = example[:status]
      return status if status != 'failed' || control[:impact].nil?
      if control[:impact] >= 0.7
        'critical'
      elsif control[:impact] >= 0.4
        'major'
      else
        'minor'
      end
    end
  end
end

class InspecRspecJUnit < InspecRspecJson
  RSpec::Core::Formatters.register self, :close

  #
  # This is the last method is invoked through the formatter interface.
  # Converts the junit formatter constructed output_hash into REXML generated
  # XML and writes it to output.
  #
  def close(_notification)
    require 'rexml/document'
    xml_output = REXML::Document.new
    xml_output.add(REXML::XMLDecl.new)

    testsuites = REXML::Element.new('testsuites')
    xml_output.add(testsuites)

    @output_hash[:profiles].each do |profile|
      testsuites.add(build_profile_xml(profile))
    end

    formatter = REXML::Formatters::Pretty.new
    formatter.compact = true
    output.puts formatter.write(xml_output.xml_decl, '')
    output.puts formatter.write(xml_output.root, '')
  end

  private

  def build_profile_xml(profile)
    profile_xml = REXML::Element.new('testsuite')
    profile_xml.add_attribute('name', profile[:name])
    profile_xml.add_attribute('tests', count_profile_tests(profile))
    profile_xml.add_attribute('failed', count_profile_failed_tests(profile))

    profile[:controls].each do |control|
      next if control[:results].nil?

      control[:results].each do |result|
        profile_xml.add(build_result_xml(control, result))
      end
    end

    profile_xml
  end

  def build_result_xml(control, result)
    result_xml = REXML::Element.new('testcase')
    result_xml.add_attribute('name', result[:code_desc])
    result_xml.add_attribute('class', control[:title].nil? ? 'Anonymous' : control[:id])
    result_xml.add_attribute('time', result[:run_time])

    if result[:status] == 'failed'
      failure_element = REXML::Element.new('failure')
      failure_element.add_attribute('message', result[:message])
      result_xml.add(failure_element)
    elsif result[:status] == 'skipped'
      result_xml.add_element('skipped')
    end

    result_xml
  end

  def count_profile_tests(profile)
    profile[:controls].reduce(0) { |acc, elem|
      acc + (elem[:results].nil? ? 0 : elem[:results].count)
    }
  end

  def count_profile_failed_tests(profile)
    profile[:controls].reduce(0) { |acc, elem|
      if elem[:results].nil?
        acc
      else
        acc + elem[:results].reduce(0) { |fail_test_total, test_case|
          test_case[:status] == 'failed' ? fail_test_total + 1 : fail_test_total
        }
      end
    }
  end
end
