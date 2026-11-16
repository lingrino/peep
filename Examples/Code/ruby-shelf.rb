# A bookshelf with simple queries.
class Book
  attr_reader :title, :author, :year

  def initialize(title:, author:, year:)
    @title, @author, @year = title, author, year
  end

  def to_s = "#{title} (#{author}, #{year})"
end

class Shelf
  include Enumerable

  GENRES = %w[fiction poetry history].freeze
  TITLE_PATTERN = %r{\A[\w\s'-]+\z}

  def self.banner(name)
    <<~TEXT
      Shelf: #{name}
      Genres: #{GENRES.join(", ")}
    TEXT
  end

  def initialize = @books = []

  def <<(book)
    @books << book
    self
  end

  def each(&block) = @books.each(&block)

  def by_decade
    group_by { |b| b.year / 10 * 10 }.transform_values(&:count)
  end
end

shelf = Shelf.new
shelf << Book.new(title: "Dune", author: "Herbert", year: 1965)
shelf << Book.new(title: "Neuromancer", author: "Gibson", year: 1984)
puts shelf.sort_by(&:year).map(&:to_s), shelf.by_decade.inspect, :symbol
