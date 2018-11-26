# frozen_string_literal: true

require 'activerecord-import'
require 'rails_or'
require 'atomically/update_all_scope'
require 'atomically/patches/none' if not ActiveRecord::Base.respond_to?(:none)
require 'atomically/patches/from' if Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new('4.0.0')

class Atomically::QueryService
  def initialize(klass, relation: nil, model: nil, &block)
    @klass = klass
    @relation = relation || @klass
    @model = model
  end

  def create_or_plus(columns, data, update_columns)
    @klass.import(columns, data, on_duplicate_key_update: on_duplicate_key_plus_sql(update_columns))
  end

  def pay_all(hash, update_columns, primary_key: :id) # { id => pay_count }
    return 0 if hash.blank?

    update_columns = update_columns.map(&method(:quote_column))

    query = hash.inject(@klass.none) do |relation, (id, pay_count)|
      condition = @relation.where(primary_key => id)
      update_columns.each{|s| condition = condition.where("#{s} >= ?", pay_count) }
      next relation.or(condition)
    end

    raw_when_sql = hash.map{|id, pay_count| "WHEN #{sanitize(id)} THEN #{sanitize(-pay_count)}" }.join("\n")
    update_sqls = update_columns.map.with_index do |column, idx|
      value = idx == 0 ? "(@change := \nCASE #{quote_column(primary_key)}\n#{raw_when_sql}\nEND)" : '@change'
      next "#{column} = #{column} + #{value}"
    end

    return query.where("(#{@klass.from(query).select('COUNT(*)').to_sql}) = ?", hash.size)
                .update_all(update_sqls.join(', '))
  end

  def update(attrs, from: :not_set)
    update_and_return_number_of_updated_rows(attrs, from: from) == 1
  end

  private

  def on_duplicate_key_plus_sql( columns)
    columns.lazy.map(&method(:quote_column)).map{|s| "#{s} = #{s} + VALUES(#{s})" }.force.join(', ')
  end

  def quote_column(column)
    @klass.connection.quote_column_name(column)
  end

  def sanitize(value)
    @klass.connection.quote(value)
  end

  def update_and_return_number_of_updated_rows(attrs, from: :not_set)
    model = @model
    return open_update_all_scope do
      update(updated_at: Time.now)
      attrs.each do |column, value|
        old_value = (from == :not_set ? model[column] : from)
        where(column => old_value).update(column => value) if old_value != value
      end
    end
  end

  def open_update_all_scope(&block)
    return 0 if @model == nil
    scope = UpdateAllScope.new(model: @model)
    scope.instance_exec(&block)
    return scope.do_query!
  end
end
