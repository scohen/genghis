require 'yaml'
require 'mongo'

class Genghis
  include Mongo

  def self.config=(path)
    puts "Setting config to #{path}"
    @@config_file = path
  end

  def self.environment=(environment = :development)
    yaml = YAML.load_file(config_file)
    @@config = yaml[environment.to_s]
    @@config.each do |k, v|
      self.class.instance_eval do
        define_method(k.to_sym){v}
      end
    end
  end

  def self.connection
    @connection || safe_create_connection
  end

  def self.database(db_alias)
    connection.db(self.databases[db_alias])
  end

  def self.reconnect
    @connection = safe_create_connection
  end

  private

  def self.config_file
    if defined? @@config_file
      @@config_file
    else
      base = defined?(Rails) ? Rails.root : File.dirname(__FILE__)
      File.join(base, 'config', 'mongodb.yml')
    end
  end

  def self.max_retries
    connection_options
    @@retries || 5
  end

  def self.connection_options
    @@connection_options ||= symbolize_keys((@@config['connection_options']) || default_connection_options)
    @@retries ||= @@connection_options.delete(:max_retries)
    @@connection_options
  end

  def self.default_connection_options
    {:max_retries => 5,
     :pool_size => 5,
     :timeout => 5,
     :use_slave => false
    }
  end

  def self.safe_create_connection
    opts = connection_options
    if self.servers.is_a? Hash
      servers = self.servers
      servers = [parse_host(servers['left']), parse_host(servers['right'])]
      connection = Connection.paired(servers, opts)
    else
      host, port = parse_host(self.servers)
      connection = Connection.new(host, port, opts)
    end
    connection
  end

  def self.parse_host(host)
    a = host.split(':')
    a << 27017 if a.size == 1
    a
  end

  def self.symbolize_keys(hash)
    hash.inject({}){|memo, (k, v)| memo[k.to_sym] = v; memo}
  end


  module ProxyMethods

    def self.included(mod)
      mod.class_eval do
        extend ClassMethods
      end
    end

    module ClassMethods
      attr_accessor :protected_class

      def protects(clazz)
        Guardian.add(clazz)
        @protected_class= clazz
      end

      def protected?(clazz)
        @@protected_classes.include? clazz
      end

      def method_missing(method, *args, &block)
        protect_from_exception do
          Guardian.make_safe(@protected_class.__send__(method, *args, &block))
        end
      end

      def allocate
        @protected_class.allocate
      end

      def safe?
        true
      end

      def protect_from_exception(&block)
        success = false
        max_retries = Genghis.max_retries
        retries = 0
        rv = nil
        while !success
          begin
            rv = yield
            success = true
          rescue Mongo::ConnectionFailure => ex
            Rails.logger.fatal('Mongo has died ', ex)
            WebServiceFailed.deliver_mongo_down(ex, Genghis.connection)
            retries += 1
            raise ex if retries > max_retries
            fix_broken_connection
            sleep(1)
          end
        end
        rv
      end

      def fix_broken_connection
        Genghis.reconnect
        MongoMapper.connection = Genghis.connection
        MongoMapper.database = Genghis.databases['mongo_mapper']
      end
    end
  end


  class Guardian
    alias_method :old_class, :class
    instance_methods.each { |m| undef_method m unless m =~ /^__|^old/}

    include ProxyMethods

    def initialize(*args)

      opts = args.extract_options!
      if opts.empty?
        if args.empty?
          what = self.old_class.protected_class.new
        else
          what = args.first
        end
      else
        what = self.old_class.protected_class.new(opts)
      end

      @protected = what
    end

    def self.protected_classes
      @@protected_classes ||= Set.new
    end

    def self.add(clazz)
      protected_classes << clazz
    end

    def self.under_protection?(clazz)
      protected_classes.include?(clazz)
    end

    def self.classes_under_protection
      protected_classes
    end

    def self.make_safe(o)
      if o.is_a? Array
        Guardian.under_protection?(o.first.class) ? ArrayProxy.new(o) : o
      else
        Guardian.under_protection?(o.class) ? Guardian.new(o) : o
      end
    end


    def method_missing(method, *args, &block)
      return true if method == :safe?
      self.old_class.protect_from_exception do
        Guardian.make_safe(@protected.__send__(method, *args, &block))
      end
    end

  end

  class ArrayProxy < Guardian
    protects Array

    def to_ary
      @protected
    end
  end

end