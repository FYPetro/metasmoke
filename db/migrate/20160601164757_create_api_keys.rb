# frozen_string_literal: true

class CreateAPIKeys < ActiveRecord::Migration[5.0]
  def change
    create_table :api_keys, &:timestamps
  end
end
