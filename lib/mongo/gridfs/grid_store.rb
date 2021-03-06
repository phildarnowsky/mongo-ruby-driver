# --
# Copyright (C) 2008-2009 10gen Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ++

require 'mongo/types/objectid'
require 'mongo/util/ordered_hash'
require 'mongo/gridfs/chunk'

module GridFS

  # GridStore is an IO-like class that provides input and output for
  # streams of data to MongoDB.
  #
  # @example
  #
  #  include GridFS
  #
  #  #Store the text "Hello, world!" in the grid store.
  #  GridStore.open(database, 'filename', 'w') do |f|
  #    f.puts "Hello, world!"
  #  end
  #
  #  # Output "Hello, world!"
  #  GridStore.open(database, 'filename', 'r') do |f|
  #    puts f.read
  #  end
  #
  #  # Add text to the grid store.
  #  GridStore.open(database, 'filename', 'w+') do |f|
  #    f.puts "But wait, there's more!"
  #  end
  #
  #  # Retrieve everything, outputting  "Hello, world!\nBut wait, there's more!\n"
  #  GridStore.open(database, 'filename', 'r') do |f|
  #    puts f.read
  #  end
  class GridStore

    DEFAULT_ROOT_COLLECTION = 'fs'
    DEFAULT_CONTENT_TYPE = 'text/plain'

    include Enumerable

    attr_accessor :filename

    # Array of strings; may be +nil+
    attr_accessor :aliases

    # Default is DEFAULT_CONTENT_TYPE
    attr_accessor :content_type

    # Size of file in bytes
    attr_reader :length

    attr_accessor :metadata

    attr_reader :files_id

    # Time that the file was first saved.
    attr_reader :upload_date

    attr_reader :chunk_size

    attr_accessor :lineno

    attr_reader :md5

    # Determine whether a given file exists in the GridStore.
    #
    # @param [Mongo::DB] a MongoDB database.
    # @param [String] name the filename.
    # @param [String] root_collection the name of the gridfs root collection.
    #
    # @return [Boolean]
    def self.exist?(db, name, root_collection=DEFAULT_ROOT_COLLECTION)
      db.collection("#{root_collection}.files").find({'filename' => name}).next_document != nil
    end

    # Open a GridFS file for reading, writing, or appending. Note that
    # this method must be used with a block.
    #
    # @param [Mongo::DB] a MongoDB database.
    # @param [String] name the filename.
    # @param [String] mode one of 'r', 'w', or 'w+' for reading, writing, 
    #   and appending, respectively.
    # @param [Hash] options any of the options available on 
    #   GridStore initialization.
    #
    # @see GridStore#initialize.
    # @see The various GridStore class methods, e.g., GridStore.open, GridStore.read etc.
    def self.open(db, name, mode, options={})
      gs = self.new(db, name, mode, options)
      result = nil
      begin
        result = yield gs if block_given?
      ensure
        gs.close
      end
      result
    end

    # Read a file stored in GridFS.
    #
    # @param [Mongo::DB] db a MongoDB database.
    # @param [String] name the name of the file.
    # @param [Integer] length the number of bytes to read.
    # @param [Integer] offset the number of bytes beyond the 
    #   beginning of the file to start reading.
    #
    # @return [String] the file data
    def self.read(db, name, length=nil, offset=nil)
      GridStore.open(db, name, 'r') do |gs|
        gs.seek(offset) if offset
        gs.read(length)
      end
    end

    # List the contents of all GridFS files stored in the given db and
    # root collection.
    #
    # @param [Mongo::DB] db a MongoDB database.
    # @param [String] root_collection the name of the root collection.
    #
    # @return [Array]
    def self.list(db, root_collection=DEFAULT_ROOT_COLLECTION)
      db.collection("#{root_collection}.files").find().map do |f|
        f['filename']
      end
    end

    # Get each line of data from the specified file 
    # as an array of strings.
    #
    # @param [Mongo::DB] db a MongoDB database.
    # @param [String] name the filename.
    # @param [String, Reg] separator
    #
    # @return [Array]
    def self.readlines(db, name, separator=$/)
      GridStore.open(db, name, 'r') do |gs|
        gs.readlines(separator)
      end
    end

    # Remove one for more files from the given db.
    #
    # @param [Mongo::Database] db a MongoDB database.
    # @param [Array<String>] names the filenames to remove
    #
    # @return [True]
    def self.unlink(db, *names)
      names.each do |name|
        gs = GridStore.new(db, name)
        gs.send(:delete_chunks)
        gs.collection.remove('_id' => gs.files_id)
      end
    end
    class << self
      alias_method :delete, :unlink
    end

    # Rename a file in this collection. Note that this method uses
    # Collection#update, which means that you will not be notified 
    #
    # @param [Mongo::DB] a MongoDB database.
    # @param [String] src the name of the source file.
    # @param [String] dest the name of the destination file.
    # @param [String] root_collection the name of the default root collection.
    def self.mv(db, src, dest, root_collection=DEFAULT_ROOT_COLLECTION)
      db.collection("#{root_collection}.files").update({ :filename => src }, { '$set' => { :filename => dest } })
    end

    # Initialize a GridStore instance for reading, writing, or modifying a given file.
    # Note that it's often easier to work with the various GridStore class methods (open, read, etc.).
    #
    # @param [Mongo::DB] db a MongoDB database.
    # @param [String] name a filename.
    # @param [String] mode either 'r', 'w', or 'w+' for reading, writing, or appending, respectively.
    #
    # @option options [String] :root DEFAULT_ROOT_COLLECTION ('r', 'w', 'w+') the name of the root collection to use.
    #
    # @option options [String] :metadata ({}) (w, w+) A hash containing any data you want persisted as
    #   this file's metadata.
    #
    # @option options [Integer] :chunk_size (Chunk::DEFAULT_CHUNK_SIZE) (w) Sets chunk size for files opened for writing.
    #   See also GridStore#chunk_size=.
    #
    # @option options [String] :content_type ('text/plain') Set the content type stored as the 
    #   file's metadata. See also GridStore#content_type=.
    def initialize(db, name, mode='r', options={})
      @db, @filename, @mode = db, name, mode
      @root = options[:root] || DEFAULT_ROOT_COLLECTION

      doc = collection.find({'filename' => @filename}).next_document
      if doc
        @files_id = doc['_id']
        @content_type = doc['contentType']
        @chunk_size = doc['chunkSize']
        @upload_date = doc['uploadDate']
        @aliases = doc['aliases']
        @length = doc['length']
        @metadata = doc['metadata']
        @md5 = doc['md5']
      else
        @files_id = Mongo::ObjectID.new
        @content_type = DEFAULT_CONTENT_TYPE
        @chunk_size = Chunk::DEFAULT_CHUNK_SIZE
        @length = 0
      end

      case mode
      when 'r'
        @curr_chunk = nth_chunk(0)
        @position = 0
      when 'w'
        chunk_collection.create_index([['files_id', Mongo::ASCENDING], ['n', Mongo::ASCENDING]])
        delete_chunks
        @curr_chunk = Chunk.new(self, 'n' => 0)
        @content_type = options[:content_type] if options[:content_type]
        @chunk_size = options[:chunk_size] if options[:chunk_size]
        @metadata = options[:metadata] if options[:metadata]
        @position = 0
      when 'w+'
        chunk_collection.create_index([['files_id', Mongo::ASCENDING], ['n', Mongo::ASCENDING]])
        @curr_chunk = nth_chunk(last_chunk_number) || Chunk.new(self, 'n' => 0) # might be empty
        @curr_chunk.pos = @curr_chunk.data.length if @curr_chunk
        @metadata = options[:metadata] if options[:metadata]
        @position = @length
      else
        raise "error: illegal mode #{mode}"
      end

      @lineno = 0
      @pushback_byte = nil
    end

    # Get the files collection referenced by this GridStore instance.
    #
    # @return [Mongo::Collection]
    def collection
      @db.collection("#{@root}.files")
    end

    # Get the chunk collection referenced by this GridStore.
    #
    # @return [Mongo::Collection]
    def chunk_collection
      @db.collection("#{@root}.chunks")
    end

    # Change the chunk size. This is permitted only when the file is opened for write
    # and no data has yet been written.
    #
    # @param [Integer] size the new chunk size, in bytes.
    #
    # @return [Integer] the new chunk size.
    def chunk_size=(size)
      unless @mode[0] == ?w && @position == 0 && @upload_date == nil
        raise "error: can only change chunk size if open for write and no data written."
      end
      @chunk_size = size
    end

    # ================ reading ================

    def getc
      if @pushback_byte
        byte = @pushback_byte
        @pushback_byte = nil
        @position += 1
        byte
      elsif eof?
        nil
      else
        if @curr_chunk.eof?
          @curr_chunk = nth_chunk(@curr_chunk.chunk_number + 1)
        end
        @position += 1
        @curr_chunk.getc
      end
    end

    def gets(separator=$/)
      str = ''
      byte = self.getc
      return nil if byte == nil # EOF
      while byte != nil
        s = byte.chr
        str << s
        break if s == separator
        byte = self.getc
      end
      @lineno += 1
      str
    end

    def read(len=nil, buf=nil)
      if len
        read_partial(len, buf)
      else
        read_all(buf)
      end
    end

    def readchar
      byte = self.getc
      raise EOFError.new if byte == nil
      byte
    end

    def readline(separator=$/)
      line = gets
      raise EOFError.new if line == nil
      line
    end

    def readlines(separator=$/)
      read.split(separator).collect { |line| "#{line}#{separator}" }
    end

    def each
      line = gets
      while line
        yield line
        line = gets
      end
    end
    alias_method :each_line, :each

    def each_byte
      byte = self.getc
      while byte
        yield byte
        byte = self.getc
      end
    end

    def ungetc(byte)
      @pushback_byte = byte
      @position -= 1
    end

    # ================ writing ================

    def putc(byte)
      if @curr_chunk.pos == @chunk_size
        prev_chunk_number = @curr_chunk.chunk_number
        @curr_chunk.save
        @curr_chunk = Chunk.new(self, 'n' => prev_chunk_number + 1)
      end
      @position += 1
      @curr_chunk.putc(byte)
    end

    def print(*objs)
      objs = [$_] if objs == nil || objs.empty?
      objs.each { |obj|
        str = obj.to_s
        str.each_byte { |byte| self.putc(byte) }
      }
      nil
    end

    def puts(*objs)
      if objs == nil || objs.empty?
        self.putc(10)
      else
        print(*objs.collect{ |obj|
                str = obj.to_s
                str << "\n" unless str =~ /\n$/
                str
              })
      end
      nil
    end

    def <<(obj)
      write(obj.to_s)
    end

    def write(string)
      raise "#@filename not opened for write" unless @mode[0] == ?w
      to_write = string.length
      while (to_write > 0) do
        if @curr_chunk && @curr_chunk.data.position == @chunk_size
          prev_chunk_number = @curr_chunk.chunk_number
          @curr_chunk = GridFS::Chunk.new(self, 'n' => prev_chunk_number + 1)
        end
        chunk_available = @chunk_size - @curr_chunk.data.position
        step_size = (to_write > chunk_available) ? chunk_available : to_write
        @curr_chunk.data.put_array(ByteBuffer.new(string[-to_write,step_size]).to_a)
        to_write -= step_size
        @curr_chunk.save
      end
      string.length - to_write
    end

    # A no-op.
    def flush
    end

    # ================ status ================

    def eof
      raise IOError.new("stream not open for reading") unless @mode[0] == ?r
      @position >= @length
    end
    alias_method :eof?, :eof

    # ================ positioning ================

    def rewind
      if @curr_chunk.chunk_number != 0
        if @mode[0] == ?w
          delete_chunks
          @curr_chunk = Chunk.new(self, 'n' => 0)
        else
          @curr_chunk == nth_chunk(0)
        end
      end
      @curr_chunk.pos = 0
      @lineno = 0
      @position = 0
    end

    def seek(pos, whence=IO::SEEK_SET)
      target_pos = case whence
                   when IO::SEEK_CUR
                     @position + pos
                   when IO::SEEK_END
                     @length + pos
                   when IO::SEEK_SET
                     pos
                   end

      new_chunk_number = (target_pos / @chunk_size).to_i
      if new_chunk_number != @curr_chunk.chunk_number
        @curr_chunk.save if @mode[0] == ?w
        @curr_chunk = nth_chunk(new_chunk_number)
      end
      @position = target_pos
      @curr_chunk.pos = @position % @chunk_size
      0
    end

    def tell
      @position
    end

    #---
    # ================ closing ================
    #+++

    def close
      if @mode[0] == ?w
        if @curr_chunk
          @curr_chunk.truncate
          @curr_chunk.save if @curr_chunk.pos > 0
        end
        files = collection
        if @upload_date
          files.remove('_id' => @files_id)
        else
          @upload_date = Time.now
        end
        files.insert(to_mongo_object)
      end
      @db = nil
    end

    def closed?
      @db == nil
    end

    #---
    # ================ protected ================
    #+++

    protected

    def to_mongo_object
      h = OrderedHash.new
      h['_id'] = @files_id
      h['filename'] = @filename
      h['contentType'] = @content_type
      h['length'] = @curr_chunk ? @curr_chunk.chunk_number * @chunk_size + @curr_chunk.pos : 0
      h['chunkSize'] = @chunk_size
      h['uploadDate'] = @upload_date
      h['aliases'] = @aliases
      h['metadata'] = @metadata
      md5_command = OrderedHash.new
      md5_command['filemd5'] = @files_id
      md5_command['root'] = @root
      h['md5'] = @db.command(md5_command)['md5']
      h
    end

    def read_partial(len, buf=nil)
      buf ||= ''
      byte = self.getc
      while byte != nil && (len == nil || len > 0)
        buf << byte.chr
        len -= 1 if len
        byte = self.getc if (len == nil || len > 0)
      end
      buf
    end

    def read_all(buf=nil)
      buf ||= ''
      while true do
        if (@curr_chunk.pos > 0)
          data = @curr_chunk.data.to_s
          buf += data[@position, data.length]
        else
          buf += @curr_chunk.data.to_s
        end
        break if @curr_chunk.chunk_number == last_chunk_number
        @curr_chunk = nth_chunk(@curr_chunk.chunk_number + 1)
      end
      buf
    end

    def delete_chunks
      chunk_collection.remove({'files_id' => @files_id}) if @files_id
      @curr_chunk = nil
    end

    def nth_chunk(n)
      mongo_chunk = chunk_collection.find({'files_id' => @files_id, 'n' => n}).next_document
      Chunk.new(self, mongo_chunk || {})
    end

    def last_chunk_number
      (@length / @chunk_size).to_i
    end

  end
end
