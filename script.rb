require 'fileutils'
require 'pry'
require 'esa'
require 'logger'
require_relative './config'
require_relative './kibela'

class Migrater
  attr_reader :notes, :attachment_list

  def initialize
    @logger = Logger.new(STDOUT)
    @file_logger = Logger.new("log_#{Time.now.to_i}.log")
    @client = Esa::Client.new(access_token: $ESA_ACCESS_TOKEN, current_team: $ESA_TEAM)
  end

  def prepare
    @notes = Dir.glob("#{$KIBELA_DIR}/kibela-#{$KIBELA_TEAM}-*/**/*.md").map do |path|
      File.open(path) do |f|
        Kibela::Note.new(f)
      end
    end.map do |note|
      [ note.id, note ]
    end.to_h

    @attachments = Dir.glob("#{$KIBELA_DIR}/kibela-#{$KIBELA_TEAM}-*/attachments/*").map do |path|
      File.open(path) do |f|
        Kibela::Attachment.new(f)
      end
    end

    @attachment_list = {}
    @attachments.each do |a|
      @attachment_list[a.name] = a
    end

    self
  end

  def migrate(dry_run: true)
    prepare
    upload_attachments unless dry_run
    create_notes(dry_run)
    replace_relative_links unless dry_run
    create_notes_links unless dry_run
  end

  def create_notes(dry_run)
    @notes.each_value do |note|
      request = note.esafy(@attachment_list)
      @logger.info request
      @file_logger.info request

      unless dry_run
        response = @client.create_post(request)
        @file_logger.info response
        note.response = response
        sleep 0.5
      end

      note.comments.each do |comment|
        request = comment.esafy(@attachment_list)
        @logger.info request
        @file_logger.info request

        unless dry_run
          response = @client.create_comment(note.esa_number, request)
          @file_logger.info response
          sleep 0.5
        end
      end
    end
  end

  def create_notes_links
    File.open($POST_MAPPINGS_FILE, mode = "w") do |f|
      @notes.each_value do |note|
        f.write("\"#{note.name}\"\t\"#{$KIBELA_URL}/notes/#{note.id}\"\t\"#{$ESA_URL}/posts/#{note.esa_number}\"\n")
      end
    end
  end

  def replace_relative_links
    @notes.each_value do |note|
      if note.has_links?
        note.replace_links(@notes)
        request = note.esafy(@attachment_list)
        @logger.info request
        @file_logger.info request
        response = @client.update_post(note.esa_number, request)
        @file_logger.info response
        note.response = response
        sleep 0.5
      end
    end
  end

  def upload_attachments
    @attachments.each do |attachment|
      @logger.info attachment.path
      @file_logger.info attachment.path
      response = @client.upload_attachment(attachment.path)
      @logger.info response
      @file_logger.info response
      next if response.body['error']
      attachment.esa_path = response.body['attachment']['url']
      sleep 0.5
    end
  end
end

migrater = Migrater.new

binding.pry
