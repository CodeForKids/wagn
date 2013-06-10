# -*- encoding : utf-8 -*-
module Wagn
  module Set::Type::Toggle
    extend Set

    format :base

    view :core, :type=>'toggle' do |args|
      case card.raw_content.to_i
        when 1; 'yes'
        when 0; 'no'
        else  ; '?'
        end
    end

    view :editor, :type=>'toggle' do |args|
      form.check_box :content
    end
  end
end
