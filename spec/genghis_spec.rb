require 'spec_helper'

describe Genghis do
  before(:each) do

  end

  it "should have a hash with indifferent access" do
    hash = {:foo => 'bar',
            'bar' => 'baz'}
    h = Genghis::HashWithConsistentAccess.new(hash)

    h[:foo].should == 'bar'
    h['foo'].should == 'bar'
    h['bar'].should == 'baz'
    h[:bar].should == 'baz'
  end

  
  it "should be able to read a config file" do
    set_yaml_file({'development' => {
            'databases' => {'foo' => 'foo_db',
                            'bar' => 'bar_db',
                            'baz' => 'baz_db'
            }
    }
    })
    Genghis.environment = :development
    
    Genghis.databases['foo'].should == 'foo_db'
    Genghis.databases[:foo].should == 'foo_db'
  end

end