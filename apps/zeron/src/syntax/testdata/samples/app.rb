# frozen_string_literal: true
require "json"
module Demo
  class User < Base
    attr_reader :name
    CONSTANT = 42
    def initialize(name, age = 0, *rest, key:, **opts, &blk)
      @name = name
      @@count ||= 0
      $global = :symbol
    end
    def to_s = "User(#{@name})"
    private
    def helper(x) x.map { |v| v * 2 }.select(&:even?) end
  end
end
puts Demo::User.new("a").to_s if __FILE__ == $0
value = %w[a b c]; regex = /ab+c/i; nothing = nil; yes = true
