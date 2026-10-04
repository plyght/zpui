def compute(a, b = 2, *args, key: 1, &block)
  total = a + b
  args.each_with_index do |item, i|
    total += item * i
  end
  block&.call(total, key)
  lambda { |x| x + total }
end
x = 10
y = x.then { |x| x * 2 }
puts "#{x} #{y}" unless defined?(z)
