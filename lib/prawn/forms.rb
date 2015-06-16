# encoding: utf-8
#
# forms.rb : Provides methods for filling PDF forms
#
# Copyright 2011 Infonium Inc. All Rights Reserved.
#
# This is free software. Please see the LICENSE and COPYING files for details.
#

module Prawn

  # The Prawn::Forms module is used to allow introspecting and filling PDF
  # forms with user-supplied data.  PDF forms can be created using external
  # tools like OpenOffice.org or Adobe Acrobat.
  #
  # Example:
  #
  #   Prawn::Document.generate("out.pdf", :template => "data/pdfs/form_with_annotations.pdf") do |pdf|
  #     foo = pdf.form_fields # => ['name', 'quest']
  #     pdf.fill_form "name" => "Sir Launcelot", "quest" => "To find the Grail"
  #   end
  #
  module Forms
    TRACE=false
    # Return a list of form field names that may be populated using fill_form
    def form_fields
      specs = form_field_specs
      return [] unless specs
      specs.keys
    end

    # Populate the form fields
    #  form fields are used to populate the field box content
    #     - expression parser (enabled by context below)
    #     - inline formats (see prawn text/inline.rb docs) like <b>, <i> and <u> are permitted
    #  optional options hash to specify:
    #     :font => Helvetica
    #     :font_size => 12
    #     :overflow => :expand | :shrink_to_fit | false
    #     :overflow_min_font_size => 8
    #     :context => is a context for ExpressionParser (proprietary)
    #                 n.b. because "." means a field delimiter in Acrobat I have decided to use "," in place of "."
    #                      this means $account_data.mrn must be written $account_data,mrn
    #                      if your authoring tool passes '.'s through as a field name value then you can keep with dot syntax
    #     :labels => true is a quick 'n dirty label maker, put your template @ lower left corner
    #         :label_rows, :label_cols
    #         :label_offset_x, :label_offset_y is how many points to go over/up for each col/row
    #  special values
    #   "barcode (symbology) (value)"
    #     - generates a barcode using Barby
    #   option :barcode_xdim (is the scale factor, 1 is no change 2 is twice as big)
    #   option :show_bounds => true draws a box around all field boxes

    require 'barby/outputter/pdfwriter_outputter'
    require 'barby/barcode/code_39'

    def fill_form(hash={}, options={})

      options[:font]                   ||= "Helvetica"
      options[:font_size]              ||= 12
      options[:barcode_xdim]           ||= 1
      options[:label_rows]             ||= 1
      options[:label_columns]          ||= 1
      options[:label_offset_x]         ||= 0
      options[:label_offset_y]         ||= 0
      options[:overflow]               ||= :expand
      options[:overflow_min_font_size] ||= 8
      options[:pages]                  ||= 1

      font_size options[:size] ? options[:size] : 10

      saved_page_number = page_number
      specs = form_field_specs
      return unless specs
      specs.each { |ref|
      (1..options[:pages]).each { |page|
        name=ref[0].encoding.to_s == 'ASCII-8BIT' ? ref[0].force_encoding('ISO-8859-1') : ref[0]
        spec=ref[1]
        if options[:context]
          options[:context][:vars]["_fill_form_page"]=page if options[:context][:vars]
          # ExpressionParser is proprietary to our code
          value = ExpressionParser.parse_exp(options[:context], name.gsub(/(\S),/, '\1.').sub(/\|\d+$/, ''))
          FlowMachineLogger.info("#{name} = #{value}") if TRACE
          if value =~ /^label\s+(.*)/
            value=$1
            is_label=true
          else
            is_label=false
          end
          options[:context][:vars].delete('_fill_form_page') if options[:context][:vars]
        else
          value = hash[name] || spec[:default_value]
        end

        if value.start_with?('barcode')
          vals=value.split(/ /)
          if vals[2] != nil && vals[2] != ''
            case vals[1].downcase
            when 'code39'
              barcode=Barby::Code39.new(vals[2])
              spec[:type] = :barcode
            else
              STDERR.puts "Unknown barcode symbology #{vals[1].downcase}"
            end
          end
        end

        x = [spec[:box][0], spec[:box][2]].min
        y = [spec[:box][1], spec[:box][3]].max
        w = (spec[:box][0]-spec[:box][2]).abs
        h = (spec[:box][1]-spec[:box][3]).abs

        # Draw the text.
        # TODO: Fill the form precisely, according to the PDF spec.  This code
        # currently just draws text at the specified locations on each form.
        # Attributes like font and font size are not respected.
        go_to_page(page)
        #go_to_page(spec[:page_number])

        canvas do

          (0..options[:label_rows]-1).each { |r|
            (0..options[:label_columns]-1).each { |c|

              # Do not include height to make bounding box stretchy
              bounding_box([x+options[:label_offset_x]*c, y+options[:label_offset_y]*r], :width => w) do

                stroke_bounds if options[:show_bounds]

                case spec[:type]
                  when :barcode
                    angle=0
                    case value
                      when /^barcode-l/
                        angle=90
                      when /^barcode-r/
                        angle=270
                      end
                    rotate(angle, :origin => [0,-h]) do
                      barcode.annotate_pdf(self, :x => 0, :y => -h, :height => h, :xdim => options[:barcode_xdim])
                    end
                  when :checkbox
                    fill_color '000000'
                    fill_rectangle [0, 0], w, h if spec[:checked]
                  when :text
                    font (spec[:font] || options[:font]), :style => spec[:font_style]
                    font_size (spec[:font_size] || options[:font_size])
                    text value.encode('UTF-8'), :align => (spec[:align] || :left), :kerning => true, :inline_format => true, :overflow => options[:overflow], :min_font_size => options[:overflow_min_font_size]
                  else

                end
              end
              break unless is_label
            }
            break unless is_label
          }

        end

      }

        # Remove form field annotation
        #if spec[:type] == :text

        # TODO - Deletion of acroform_fields does not work when using multiple copies of a page ...
#          spec[:refs][:acroform_fields].delete(spec[:refs][:field])
#          deref(deref(spec[:refs][:page])[:Annots]).delete(spec[:refs][:field])
        #end

      }
      go_to_page(saved_page_number)
      nil

    end

    private

    # Return a Hash of information about form fields that may be populated using fill_form
    # see pdf_reference_1-7.pdf section 8.6.1
    #  form field spec
    #    :Type == :Annot, :Subtype == :Widget
    #    :FT == Field Type
    #           :Tx - text field
    #           :Btn - button like checkboxes (see Ff for type bits)
    #    :T ==  Name
    #    :AP == (reference)
    #    :DA == default appearance, "/Cour 18 Tf 0 g"
    #    :DS == default style, ie "font: Courier,monospace 18.0pt; text-align:center; color:#000000 " (rich formatting enabled)
    #    :DV == default value content
    #    :F  == ?, ex: 4
    #    :Ff == 33558528
    #    :MK == {:R=>90} for rotation
    #    :P  == page reference
    #    :Q  == ?, ex: 1
    #    :RV == rendered value in xhtml
    #    :Rect == bounding box relative to canvas
    #    :TU == Tooltip text
    #    :V  == value
    #    :AS == Appearance Stream
    #       :On | :Off for checkboxes

    def form_field_specs

      page_numbers = {}
      state.pages.each_with_index do |page, i|
        page_numbers[page.dictionary.object_id] = i+1
      end

      root = deref(state.store.root)
      acro_form = deref(root[:AcroForm])
      return nil unless acro_form
      form_fields = deref(acro_form[:Fields])

      retval = []
      form_fields.map do |field_ref|
        field_dict = deref(field_ref)
        deref(field_dict[:AP])
        # Supported :Type
        next unless field_dict[:Type] == :Annot and field_dict[:Subtype] == :Widget
        # Supported :FT
        next unless field_dict[:FT] == :Tx || field_dict[:FT] == :Btn

        name = string_to_utf8(field_dict[:T])
        spec = {}
        spec[:type]=:text if field_dict[:FT] == :Tx
        # TODO - more accurate type determination based on :Ff value
        spec[:type]=:checkbox if field_dict[:FT] == :Btn && 1
        spec[:box] = field_dict[:Rect]

        # Field type specific
        case spec[:type]
          when :checkbox
            spec[:checked] = field_dict[:AS] == :On ? true : false
          when :text
            spec[:default_value] = field_dict[:V] || field_dict[:DV] || ""
            # Formatting
            #    :DS == font info, ie "font: Courier,monospace 18.0pt; text-align:center; color:#000000 "
            spec[:format_info] = field_dict[:DS].respond_to?(:data) ? field_dict[:DS].data.to_s : field_dict[:DS].to_s
            if spec[:format_info] =~ /font: ((italic |bold )*)\s*('([^']+)'|(\S[^, ]+))/
              spec[:font]=$4
              case $1
                when 'italic '
                  spec[:font_style] = :italic
                when 'bold '
                  spec[:font_style] = :bold
                when 'italic bold '
                  spec[:font_style] = :bold_italic
                else
                  spec[:font_style] = :normal
              end
            end
            spec[:font_size]=$1.to_f if spec[:format_info] =~ /font: .* ([\d\.]+)pt;/
            spec[:align]=$1.to_sym if spec[:format_info] =~ /text-align:(\w+)/
          else
            raise "unhandled spec type #{spec[:type]}"
        end

        page_ref = field_dict[:P]
        unless page_ref
          # The /P (page) entry is optional, so if there's only one page, assume the first page.
          # If there is more than one page, but the annotation doesn't specify
          # which page, skip the annotation.
          # XXX - Is this the correct behaviour?
          if page_numbers.length == 1
            page_ref = state.pages.first.dictionary
          else
            STDERR.puts "Missing page reference for acroform field #{name}"
            next
          end
        end
        spec[:page_number] = page_numbers[page_ref.object_id]
        spec[:refs] = {
          :page => page_ref,
          :field => field_ref,
          :acroform_fields => form_fields,
        }

        retval << [name, spec]

      end
      retval
    end

    def string_to_utf8(str)
      str = str.dup
      str.force_encoding("ASCII-8BIT") if str.respond_to?(:force_encoding)
      if str =~ /\A\xFE\xFF/n
        utf16_to_utf8(str)
      else
        str
      end
    end
  end
end
