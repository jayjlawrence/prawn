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
    # Return a list of form field names that may be populated using fill_form
    def form_fields
      specs = form_field_specs
      return [] unless specs
      specs.keys
    end

    # Populate the form fields
    #  optional options hash to specify:
    #     :size => 12
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

    require 'barby/outputter/pdfwriter_outputter'
    require 'barby/barcode/code_39'

    def fill_form(hash={}, options={})

      options[:size] ||= 12
      specs = form_field_specs
      return unless specs
      specs.each { |ref|
        name=ref[0]
        spec=ref[1]
        if options[:context]
          # ExpressionParser is proprietary to our code
          value = ExpressionParser.parse_exp(options[:context], name.gsub(/(\S),(\S)/, '\1.\2'))
        else
          value = hash[name] || spec[:default_value]
        end

        if value.start_with?('barcode')
          vals=value.split(/ /)
          case vals[1].downcase
            when 'code39'
              barcode=Barby::Code39.new(vals[2])
            else
              STDERR.puts "Unknown barcode symbology #{vals[1].downcase}"
          end
        else
          barcode=nil
        end

        x = [spec[:box][0], spec[:box][2]].min
        y = [spec[:box][1], spec[:box][3]].min
        w = (spec[:box][0]-spec[:box][2]).abs
        h = (spec[:box][1]-spec[:box][3]).abs

        # Draw the text.
        # TODO: Fill the form precisely, according to the PDF spec.  This code
        # currently just draws text at the specified locations on each form.
        # Attributes like font and font size are not respected.
        saved_page_number = page_number
        go_to_page(spec[:page_number])
          float do
            canvas do
              unless barcode
                draw_text value, :at => [x, y], :size => options[:size]
              else
                barcode.annotate_pdf(self, :x => x, :y => y, :height => h)
              end
              if options[:labels]
                (0..options[:label_rows]-1).each { |r|
                  (0..options[:label_columns]-1).each { |c|
                    next if r==0 && c==0 # this is our original
                    unless barcode
                      draw_text value, :at => [x+options[:label_offset_x]*c, y+options[:label_offset_y]*r], :size => options[:size]
                    else
                      barcode.annotate_pdf(self, :x => x+options[:label_offset_x]*c, :y => y+options[:label_offset_y]*r, :height => h)
                    end
                  }
                }
              end
            end
          end
        go_to_page(saved_page_number)

        # Remove form field annotation
        spec[:refs][:acroform_fields].delete(spec[:refs][:field])
        deref(deref(spec[:refs][:page])[:Annots]).delete(spec[:refs][:field])
      }
      nil
    end

    private

    # Return a Hash of information about form fields that may be populated using fill_form
    def form_field_specs
      page_numbers = {}
      state.pages.each_with_index do |page, i|
        page_numbers[page.dictionary] = i+1
      end
      root = deref(state.store.root)
      acro_form = deref(root[:AcroForm])
      return nil unless acro_form
      form_fields = deref(acro_form[:Fields])

      retval = []
      form_fields.map do |field_ref|
        field_dict = deref(field_ref)
        next unless deref(field_dict[:Type]) == :Annot and deref(field_dict[:Subtype]) == :Widget
        next unless deref(field_dict[:FT]) == :Tx
        name = string_to_utf8(deref(field_dict[:T]))
        spec = {}
        spec[:box] = deref(field_dict[:Rect])
        spec[:default_value] = string_to_utf8(deref(field_dict[:V] || field_dict[:DV] || ""))
        page_ref = field_dict[:P]
        unless page_ref
          # The /P (page) entry is optional, so if there's only one page, assume the first page.
          # If there is more than one page, but the annotation doesn't specify
          # which page, skip the annotation.
          # XXX - Is this the correct behaviour?
          if page_numbers.length == 1
            page_ref = page_numbers.keys.first
          else
            next
          end
        end
        spec[:page_number] = page_numbers[page_ref]
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
