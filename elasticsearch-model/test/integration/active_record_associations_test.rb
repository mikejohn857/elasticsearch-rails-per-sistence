require 'test_helper'

# ----- Models definition -------------------------------------------------------------------------

class Category < ActiveRecord::Base
  has_and_belongs_to_many :posts
end

class Author < ActiveRecord::Base
  has_many :authorships

  def full_name
    [first_name, last_name].compact.join(' ')
  end
end

class Authorship < ActiveRecord::Base
  belongs_to :author
  belongs_to :post, touch: true
end

class Comment < ActiveRecord::Base
  belongs_to :post, touch: true
end

class Post < ActiveRecord::Base
  has_and_belongs_to_many :categories, after_add:    [ lambda { |a,c| a.__elasticsearch__.index_document } ],
                                       after_remove: [ lambda { |a,c| a.__elasticsearch__.index_document } ]
  has_many                :authorships
  has_many                :authors, through: :authorships
  has_many                :comments
end

# ----- Search integration via Concern module -----------------------------------------------------

module Searchable
  extend ActiveSupport::Concern

  included do
    include Elasticsearch::Model
    include Elasticsearch::Model::Callbacks

    # Set up the mapping
    #
    mapping do
      indexes :title,      analyzer: 'snowball'
      indexes :created_at, type: 'date'

      indexes :authors do
        indexes :first_name
        indexes :last_name
        indexes :full_name, type: 'multi_field' do
          indexes :full_name
          indexes :raw, analyzer: 'keyword'
        end
      end

      indexes :categories, analyzer: 'keyword'

      indexes :comments, type: 'nested' do
        indexes :text
        indexes :author
      end
    end

    # Customize the JSON serialization for Elasticsearch
    #
    def as_indexed_json(options={})
      {
        title: title,
        text:  text,
        categories: categories.map(&:title),
        authors:    authors.as_json(methods: [:full_name], only: [:full_name, :first_name, :last_name]),
        comments:   comments.as_json(only: [:text, :author])
      }
    end

    # Update document in the index after touch
    #
    after_touch() { __elasticsearch__.index_document }
  end
end

# Include the search integration
#
Post.__send__ :include, Searchable

module Elasticsearch
  module Model
    class ActiveRecordAssociationsIntegrationTest < Elasticsearch::Test::IntegrationTestCase

      context "ActiveRecord associations" do
        setup do

          # ----- Schema definition ---------------------------------------------------------------

          ActiveRecord::Schema.define(version: 1) do
            create_table :categories do |t|
              t.string     :title
              t.timestamps
            end

            create_table :categories_posts, id: false do |t|
              t.references :post, :category
            end

            create_table :authors do |t|
              t.string     :first_name, :last_name
              t.timestamps
            end

            create_table :authorships do |t|
              t.string     :first_name, :last_name
              t.references :post
              t.references :author
              t.timestamps
            end

            create_table :comments do |t|
              t.string     :text
              t.string     :author
              t.references :post
              t.timestamps
            end and add_index(:comments, :post_id)

            create_table :posts do |t|
              t.string     :title
              t.text       :text
              t.boolean    :published
              t.timestamps
            end
          end

          # ----- Reset the index -----------------------------------------------------------------

          Post.delete_all
          Post.__elasticsearch__.create_index! force: true
        end

        should "index and find a document" do
          Post.create! title: 'Test'
          Post.create! title: 'Testing Coding'
          Post.create! title: 'Coding'
          Post.__elasticsearch__.refresh_index!

          response = Post.search('title:test')

          assert_equal 2, response.results.size
          assert_equal 2, response.records.size

          assert_equal 'Test', response.results.first.title
          assert_equal 'Test', response.records.first.title
        end

        should "reindex a document after categories are changed" do
          # Create categories
          category_a = Category.where(title: "One").first_or_create!
          category_b = Category.where(title: "Two").first_or_create!

          # Create post
          post = Post.create! title: "First Post", text: "This is the first post..."

          # Assign categories
          post.categories = [category_a,  category_b]

          Post.__elasticsearch__.refresh_index!

          query = { query: {
                      filtered: {
                        query: {
                          multi_match: {
                            fields: ['title'],
                            query: 'first'
                          }
                        },
                        filter: {
                          terms: {
                            categories: ['One']
                          }
                        }
                      }
                    }
                  }

          response = Post.search query

          assert_equal 1, response.results.size
          assert_equal 1, response.records.size

          # Remove category "One"
          post.categories = [category_b]

          Post.__elasticsearch__.refresh_index!
          response = Post.search query

          assert_equal 0, response.results.size
          assert_equal 0, response.records.size
        end

        should "reindex a document after authors are changed" do
          # Create authors
          author_a = Author.where(first_name: "John", last_name: "Smith").first_or_create!
          author_b = Author.where(first_name: "Mary", last_name: "Smith").first_or_create!
          author_c = Author.where(first_name: "Kobe", last_name: "Griss").first_or_create!

          # Create posts
          post_1 = Post.create! title: "First Post", text: "This is the first post..."
          post_2 = Post.create! title: "Second Post", text: "This is the second post..."
          post_3 = Post.create! title: "Third Post", text: "This is the third post..."

          # Assign authors
          post_1.authors = [author_a,  author_b]
          post_2.authors = [author_a]
          post_3.authors = [author_c]

          Post.__elasticsearch__.refresh_index!

          response = Post.search 'authors.full_name:john'

          assert_equal 2, response.results.size
          assert_equal 2, response.records.size

          post_3.authors << author_a

          Post.__elasticsearch__.refresh_index!

          response = Post.search 'authors.full_name:john'

          assert_equal 3, response.results.size
          assert_equal 3, response.records.size
        end

        should "reindex a document after comments are added" do
          # Create posts
          post_1 = Post.create! title: "First Post", text: "This is the first post..."
          post_2 = Post.create! title: "Second Post", text: "This is the second post..."

          # Add comments
          post_1.comments.create! author: 'John', text: 'Excellent'
          post_1.comments.create! author: 'Abby', text: 'Good'

          post_2.comments.create! author: 'John', text: 'Terrible'

          Post.__elasticsearch__.refresh_index!

          response = Post.search 'comments.author:john AND comments.text:good'
          assert_equal 0, response.results.size

          # Add comment
          post_1.comments.create! author: 'John', text: 'Or rather just good...'

          Post.__elasticsearch__.refresh_index!

          response = Post.search 'comments.author:john AND comments.text:good'
          assert_equal 0, response.results.size

          response = Post.search \
            query: {
              nested: {
                path: 'comments',
                query: {
                  bool: {
                    must: [
                      { match: { 'comments.author' => 'john' } },
                      { match: { 'comments.text'   => 'good' } }
                    ]
                  }
                }
              }
            }

          assert_equal 1, response.results.size
        end

        should "reindex a document after Post#touch" do
          # Create categories
          category_a = Category.where(title: "One").first_or_create!

          # Create post
          post = Post.create! title: "First Post", text: "This is the first post..."

          # Assign category
          post.categories << category_a

          Post.__elasticsearch__.refresh_index!

          assert_equal 1, Post.search('categories:One').size

          # Update category
          category_a.update_attribute :title, "Updated"

          # Trigger touch on posts in category
          category_a.posts.each { |p| p.touch }

          Post.__elasticsearch__.refresh_index!

          assert_equal 0, Post.search('categories:One').size
          assert_equal 1, Post.search('categories:Updated').size
        end
      end

    end
  end
end
