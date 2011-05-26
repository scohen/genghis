require 'yaml'
require 'mongo'
require 'uri'

class Genghis
  include Mongo

  def self.hosts
    @@hosts
  end

  def self.hosts=(host_list)
    @@hosts = host_list
  end

  def self.config=(path)
    @@config_file = path
  end

  def self.environment=(environment = :development)
    yaml        = YAML.load_file(config_file)
    @connection = nil
    @@config    = yaml[environment.to_s]
    @@config.each do |k, v|
      if k == 'server'
        self.hosts = parse_mongo_urls([v])
      elsif k == 'replica_set'
        self.hosts = parse_mongo_urls(v)
      elsif k == 'resilience_options'
        v.each_pair do |opt, setting|
          self.send("#{opt}=".to_sym, setting)
        end
      else
        self.class.instance_eval do
          v = HashWithConsistentAccess.new(v) if v.is_a?(::Hash)
          define_method(k.to_sym) { v }
        end
      end
    end
    parse_connection_options unless @@config['connection_options'].nil?
    nil
  end

  def self.on_failure(&block)
    @failure_method = block if block_given?
  end

  def self.failure_callback
    @failure_method
  end

  def self.connection
    @connection ||= safe_create_connection
  end

  def self.database(db_alias)
    connection.db(self.databases[db_alias.to_s])
  end

  def self.reconnect
    @connection = safe_create_connection
  end

  def self.max_retries=(num)
    @@retries = num
  end

  def self.max_retries
    @@retries ||= 5
  end

  def self.sleep_between_retries=(num)
    @@sleep_time = num
  end

  def self.sleep_between_retries
    @@sleep_time || 1
  end

  private

  def self.parse_connection_options
    @@connection_options = symbolize_keys(default_connection_options.merge(@@config['connection_options']))
  end

  def self.parse_mongo_urls(urls)
    urls.collect do |url|
      uri = URI.parse(url)
      {:host     => uri.host,
       :port     => uri.port || 27017,
       :username => uri.user,
       :password => uri.password,
      }
    end
  end

  def self.config_file
    if defined? @@config_file
      @@config_file
    else
      base = defined?(Rails) ? Rails.root : File.dirname(__FILE__)
      File.join(base, 'config', 'mongodb.yml')
    end
  end


  def self.connection_options
    @@connection_options ||= parse_connection_options
  end

  def self.default_connection_options
    { :pool_size   => 5,
     :timeout     => 5,
     :slave_ok    => false
    }
  end

  def self.safe_create_connection
    opts = connection_options
    if self.hosts.size > 1
      servers    = self.hosts.collect { |x| [x[:host], x[:port]] }
      if defined?(Mongo::ReplSetConnection)
        args = servers << opts
        connection = Mongo::ReplSetConnection.new(*args)
      else
        connection = Connection.multi(servers, opts)
      end
    else
      host       = self.hosts.first
      connection = Connection.new(host[:host], host[:port], opts)
    end

    if self.hosts.first[:username]
      auth = self.hosts.first
      self.databases.each_pair do |k, db|
        connection.add_auth(db.to_s, auth[:username], auth[:password])
      end
      connection.apply_saved_authentication
    end

    connection
  end

  def self.parse_host(host)
    a = host.split(':')
    a << 27017 if a.size == 1
    [a.first, a.last.to_i]
  end

  def self.symbolize_keys(hash)
    hash.inject({}) { |memo, (k, v)| memo[k.to_sym] = v; memo }
  end


  module ProxyMethods

    def self.included(mod)
      mod.class_eval do
        extend ClassMethods
      end

    end

    module InstanceMethods
      def safe?
        true
      end
    end

    module ClassMethods
      attr_accessor :protected_class

      def protects(clazz)
        Guardian.add(clazz)
        Guardian.add_protected_class(self, clazz)
        @protected_class= clazz
      end

      def protected_class
        @protected_class
      end

      def protected?(clazz)
        @@protected_classes.include? clazz
      end

      def method_missing(method, * args, & block)
        protect_from_exception do
          Guardian.make_safe(@protected_class.__send__(method, * args, & block))
        end
      end

      def allocate
        @protected_class.allocate
      end

      def safe?
        true
      end

      def protect_from_exception(& block)
        success     = false
        max_retries = Genghis.max_retries
        retries     = 0
        rv          = nil
        while !success
          begin
            rv      = yield
            success = true
          rescue Mongo::ConnectionFailure => ex
            if Genghis.failure_callback
              Genghis.failure_callback.call(ex, Genghis.connection)
            end
            retries += 1
            raise ex if retries > max_retries
            fix_broken_connection
            sleep(Genghis.sleep_between_retries)
          end
        end
        rv
      end

      def fix_broken_connection
        Genghis.reconnect
        if defined?(MongoMapper)
          MongoMapper.connection = Genghis.connection
          MongoMapper.database   = Genghis.databases['mongo_mapper']
        end
      end
    end
  end

  class HashWithConsistentAccess

    def initialize(proxied={})
      @proxied = proxied.inject({}) do |memo, (k, v)|
        memo[k.to_s] = v
        memo
      end
    end

    def each_pair(&block)
      @proxied.each_pair do |k, v|
        yield(k.to_s, v)
      end
    end

    def []=(key, value)
      @proxied[key.to_s] = value
    end

    def [](key)
      @proxied[key.to_s]
    end

    def key?(key)
      @proxied.key?(key.to_s)
    end

    def inspect
      @proxied.inspect
    end
  end


  class Guardian
    alias_method :old_class, :class
    instance_methods.each { |m| undef_method m unless m =~ /^__|^old/ }

    include ProxyMethods

    def self.add_protected_class(subclass, protected_class)
      @@protected_mappings                  ||= {}
      @@protected_mappings[protected_class] = subclass
    end

    def self.protected_mappings
      @@protected_mappings
    end

    def initialize(* args)

      opts = args.last.is_a?(Hash) ? args.last : {}
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

    def self.protecting?(clazz)
      protected_classes.include?(clazz)
    end

    def self.classes_under_protection
      protected_classes
    end

    def self.make_safe(o)

      if o.is_a? Array
        Guardian.protecting?(o.first.class) ? ArrayProxy.new(o) : o
      else
        class_providing_protection = protected_mappings[o.class] || Guardian
        Guardian.protecting?(o.class) ? class_providing_protection.new(o) : o
      end
    end

    def unprotected_object
      @protected
    end


    def method_missing(method, * args, & block)
      return true if method == :safe?
      self.old_class.protect_from_exception do
        Guardian.make_safe(@protected.__send__(method, * args, & block))
      end
    end


    class << self
      alias_method :under_protection?, :protecting?
    end

  end

  class ArrayProxy < Guardian
    protects Array

    def to_ary
      @protected
    end
  end


end
