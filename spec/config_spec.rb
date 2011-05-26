require 'spec_helper'
require 'mongo'

describe Genghis do
  include Mongo

  context :configuration do

    it "should handle a url with defaults" do
      set_yaml_file('test' => {'server' => 'mongodb://localhost'})
      Genghis.environment = :test
      host                = Genghis.hosts.first
      host[:host].should == 'localhost'
      host[:port].should == 27017
    end

    it "should be able to handle a single server" do
      set_yaml_file('test' => {
          'server' => "mongodb://mongo:foo@localhost:20717",

      })
      Genghis.environment = :test
      Genghis.hosts.should == [{:host     => 'localhost',
                                :port     => 20717,
                                :username => 'mongo',
                                :password => 'foo'}]

    end

    it "should be able to handle replica sets" do
      set_yaml_file('test' => {'replica_set' => [
          "mongodb://localhost:27017",
          "mongodb://mongo:foo@remotehost:27018",
          "mongodb://mongo:bar@remotehost2"
      ]})
      Genghis.environment= :test
      Genghis.hosts.should == [{:host     => 'localhost',
                                :port     => 27017,
                                :username => nil,
                                :password => nil},

                               {:host     => 'remotehost',
                                :username => 'mongo',
                                :password => 'foo',
                                :port     => 27018},
                               {
                                   :host     => 'remotehost2',
                                   :username => 'mongo',
                                   :password => 'bar',
                                   :port     => 27017}
      ]
    end

    it "should be able to pass in resilience options" do
      set_yaml_file('test' => {'resilience_options' => {'max_retries'           => 503,
                                                        'sleep_between_retries' => 0.5}})
      Genghis.environment= :test
      Genghis.max_retries.should == 503
      Genghis.sleep_between_retries.should == 0.5
    end

    it "should be able to pass in connection options" do
      opts = {:timeout   => 8,
              :pool_size => 29,
              :slave_ok  => true}
      set_yaml_file('test' => {'connection_options' => opts})

      Genghis.environment = :test
      Genghis.connection_options.should == opts
    end

    it "should be able to handle database aliases" do
      set_yaml_file('test' => {'databases' => {
          'good' => 'bad',
          'bad'  => 'ugly'
      }
      })
      Genghis.environment = :test
      Genghis.databases[:good].should == 'bad'
      Genghis.databases[:bad].should == 'ugly'
    end
  end

  context "when it connects" do
    context "single server" do
      before do
        set_yaml_file('test' => {
            'server'    => 'mongodb://foo:bar@localhost:32014',
            'databases' => {'test' => 'test',
                            'db2'  => 'mapped'
            }
        })
        Genghis.environment=:test
        @conn              = mock(Mongo::Connection)
        @db                = mock(Mongo::DB)
        @conn.stub(:db).and_return(@db)

      end

      it 'should connect using new' do
        @conn.should_receive(:add_auth).twice
        @conn.should_receive(:apply_saved_authentication)
        Mongo::Connection.should_receive(:new).with('localhost', 32014, Genghis.connection_options).and_return(@conn)
        Genghis.database(:test).should == @db
      end

      it "should add auth its databases" do
        Mongo::Connection.should_receive(:new).and_return(@conn)
        @conn.should_receive(:add_auth).with('test', 'foo', 'bar')
        @conn.should_receive(:add_auth).with('mapped', 'foo', 'bar')
        @conn.should_receive(:apply_saved_authentication)

        Genghis.database(:test)
      end

      it "should apply the authentication when it is created" do
        Mongo::Connection.should_receive(:new).and_return(@conn)
        @conn.should_receive(:add_auth).twice
        @conn.should_receive(:apply_saved_authentication)
        Genghis.database(:test).should == @db
      end

    end

    context "replica with ReplSetConnection" do
      before do
        set_yaml_file('test' => {
            'replica_set' => [
                'mongodb://foo:bar@localhost',
                'mongodb://foo:bar@remotehost',
                'mongodb://foo:bar@remotehost2:12345'
            ]
        })
        Genghis.environment=:test
        @conn              = mock(Mongo::Connection)
        @db                = mock(Mongo::DB)
        @conn.stub(:db).and_return(@db)
      end


      it "should add auth to its databases" do
        Mongo::ReplSetConnection.should_receive(:new).and_return(@conn)
        @conn.should_receive(:apply_saved_authentication)
        @conn.should_receive(:add_auth).with('test', 'foo', 'bar')
        @conn.should_receive(:add_auth).with('mapped', 'foo', 'bar')
        Genghis.database(:test).should == @db
      end

      context "after auth" do
        before do
          @conn.should_receive(:apply_saved_authentication)
          @conn.should_receive(:add_auth).twice
        end
        it "should connect using ReplSetConnection" do
          Mongo::ReplSetConnection.should_receive(:new).with(['localhost', 27017],
                                                             ['remotehost', 27017],
                                                             ['remotehost2', 12345],
                                                             Genghis.connection_options).and_return(@conn)
          Genghis.database(:test).should == @db
        end
      end


    end

    context "replica set pre ReplSetConnection" do
      before do
        set_yaml_file('test' => {
            'replica_set' => [
                'mongodb://foo:bar@localhost',
                'mongodb://foo:bar@remotehost',
                'mongodb://foo:bar@remotehost2:12345'
            ]
        })
        Genghis.environment=:test
        @conn              = mock(Mongo::Connection)
        @db                = mock(Mongo::DB)

        if defined?(Mongo::ReplSetConnection)
          Mongo.send(:remove_const, "ReplSetConnection".to_sym)
        end

        @conn.stub(:db).and_return(@db)
      end


      it "should add auth to its databases" do
        Mongo::Connection.should_receive(:multi).and_return(@conn)
        @conn.should_receive(:apply_saved_authentication)
        @conn.should_receive(:add_auth).with('test', 'foo', 'bar')
        @conn.should_receive(:add_auth).with('mapped', 'foo', 'bar')
        Genghis.database(:test).should == @db
      end

      context "after auth" do
        before do
          @conn.should_receive(:apply_saved_authentication)
          @conn.should_receive(:add_auth).twice
        end
        it "should connect using multi" do

          Mongo::Connection.should_receive(:multi).with(   [['localhost', 27017],
                                                            ['remotehost', 27017],
                                                            ['remotehost2', 12345]
                                                           ], Genghis.connection_options).and_return(@conn)
          Genghis.database(:test).should == @db
        end
      end


    end
  end
end