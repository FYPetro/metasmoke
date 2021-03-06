# frozen_string_literal: true

class SiteSetting < ApplicationRecord
  validates :name, uniqueness: true

  def self.[](key)
    inst = find_by name: key
    case inst&.value_type
    when 'boolean'
      inst&.value&.to_i == 1
    when 'number'
      inst&.value&.to_i
    else
      inst&.value
    end
  end

  def self.[]=(key, val)
    inst = find_by name: key
    db_val = case inst&.value_type
             when 'boolean'
               val == 'true' ? 1 : 0
             when 'number'
               val.to_s
             else
               val
             end
    inst&.update(value: db_val)
  end
end
