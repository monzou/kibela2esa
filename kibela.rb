require 'date'
require 'front_matter_parser'
require 'nokogiri'
require_relative './config'

module Kibela
  PATH_PATTERN = %r[\A.*/kibela-#{$KIBELA_TEAM}-\d+/(?<kind>wikis|blogs|notes)/(?<path>[[:print:]]*/)*(?<id>\d+)-(?<name>[[:print:]]*)\.md\z]
  ATTACHMENT_PATTERN = %r[^(?~http)(\.\./)*attachments/(?<attachment_name>\d+\.(png|JPG|jpg|jpeg|gif|PNG))]
  
  class Note
    attr_accessor :id, :name, :category, :body, :frontmatter, :author, :comments, :response

    def initialize(file)
      raise ArgumentError unless file.is_a?(File)
      puts "Read: #{file.path} ..."
      regexp = PATH_PATTERN.match(file.path)
      binding.pry unless regexp
      puts "Parse: #{file.path} ..."
      markdown = FrontMatterParser::Parser.new(:md).call(file.read)
      puts "Parse Success: #{file.path}"
      @id = regexp[:id]
      @body = markdown.content
      @name = markdown.content[/^#\s*.*?(\n){1}/].delete_prefix("#").delete_suffix("\n").gsub('/', '&#47;').strip
      @frontmatter = markdown.front_matter
      @category = "#{$ESA_MIGRATION_PATH}/#{@frontmatter['folders'][0]&.gsub(/^\w+\s*\/\s*/, '')}".strip.delete_suffix('/')
      @published = DateTime.parse(@frontmatter['published_at'])
      @kind = @frontmatter['coediting'] ? 'flow' : 'stock'
      @author = @frontmatter['author'].delete_prefix('@')
      @comments = @frontmatter['comments'].map { |c| Comment.new(c) }
    end

    def has_links?
      @body.match?(/https:\/\/#{$KIBELA_TEAM}\.kibe\.la\/(wikis|notes|)(\/|%|\w)*\/(\d+)/)
    end

    def wip?
      %r[wip]i.match?(@name)
    end

    def replace_attachment_names(attachment_list)
      parsed_body = Nokogiri::HTML(@body)
      parsed_body.css('img').map do |elem|
        next unless elem.attributes['src']
        match = ATTACHMENT_PATTERN.match(elem.attributes['src'].value)
        # 文中に出現するkibelaの画像URLをesaの画像URLに置換する
        next unless match
        next unless attachment_list[match['attachment_name']]
        @body.gsub!(elem.attributes['src'], attachment_list[match['attachment_name']].esa_path) if match
      end
    end

    def replace_links(notes)
      @body.gsub!(/https:\/\/#{$KIBELA_TEAM}\.kibe\.la\/(wikis|notes|)(\/|%|\w)*\/(\d+)/) do |s|
        id = $3
        kind = $1
        if kind == "wikis"
          id = get_note_id(id)
        end
        note = notes[id]
        if note then
          "[#{note.esa_number}: #{note.name}](/posts/#{note.esa_number})"
        else
          s
        end
      end
    end

    def get_note_id(wiki_id)
      uri = URI.parse("#{$KIBELA_URL}/wikis/#{wiki_id}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri.request_uri)
      req.add_field("Cookie", "_session_id=#{$KIBELA_SESSION_ID}")
      res = http.request(req)
      res["location"][/https:\/\/#{$KIBELA_TEAM}\.kibe\.la\/notes\/(\d+)/, 1] if res && res["location"]
    end

    def esafy(attachment_list)
      replace_attachment_names(attachment_list)
      {
        post: {
          name: @name,
          body_md: esafy_content(@body),
          tags: [],
          category: @category,
          user: esafy_user_name(@author),
          wip: wip?,
          created_at: @published.strftime("%Y-%m-%d %H:%M:%S"),
          message: 'Migrate from Kibela',
        }
      }
    end

    def esafy_user_name(kibela_user)
      $USER_MAPPINGS[kibela_user] || 'esa_bot'
    end

    def esafy_content(content)
      md = content
        .sub(/^#\s*.*?(\n){1}/m, '') # Remove first H1
        .sub(/^(\s|\n)+/m, '') # Remove first spaces
        .gsub(/^(#+)(\w+)/, '\1 \2') # Add space to headings
        .gsub(/```{plantuml}/, '```uml') # Replace PlantUML with UML
        "#{md}\n\n---\n\n> この記事は Kibela からの移行記事です。\n> 作成者: #{@author}\n> 作成日: #{@published.strftime("%Y/%m/%d")}"
    end

    def esa_number
      @response.body['number']
    end
  end

  class Comment
    def initialize(comment)
      @raw = comment
      @content = esafy_content(@raw['content'])
      @user = @raw['author'].delete_prefix('@')
      @published = DateTime.parse(@raw['published_at'])
    end

    def replace_attachment_names(attachment_list)
      parsed_comment = Nokogiri::HTML(@content)
      parsed_comment.css('img').map do |elem|
        match = ATTACHMENT_PATTERN.match(elem.attributes['src'].value)
        if match
          attachment = attachment_list[match['attachment_name']]
          binding.pry unless attachment
          @content.gsub!(elem.attributes['src'], attachment.esa_path)
        end
      end
    end

    def esafy_user_name(kibela_user)
      $USER_MAPPINGS[kibela_user] || 'esa_bot'
    end

    def esafy_content(content)
      content
        .gsub(/^(#+)(\w+)/, '\1 \2') # Add space to headings
        .gsub(/```{plantuml}/, '```uml') # Replace PlantUML with UML
    end

    def esafy(attachment_list)
      replace_attachment_names(attachment_list)
      {
        body_md: $USER_MAPPINGS[@user] ? @content : "#{@content}\n\n(投稿者：#{@user})",
        user: esafy_user_name(@user),
        created_at: @published.strftime("%Y-%m-%d %H:%M:%S")
      }
    end
  end

  class Attachment
    attr_accessor :name, :path, :esa_path

    def initialize(file)
      raise ArgumentError unless file.is_a?(File)

      @name = File.basename(file.path)
      @path = file.path
      @esa_path = 'dummy'
    end
  end
end
